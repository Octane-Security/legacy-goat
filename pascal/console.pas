{$MODE DELPHI}
{ Branch Operations Console.

  A headless Free Pascal HTTP service (fphttpserver, threaded) on :8080 that is BOTH
    (a) a browser-facing app serving plain HTML <form>/<table> pages, and
    (b) the future target of a Delphi GUI client POSTing the SAME endpoints over HTTP
        as application/x-www-form-urlencoded.
  One request handler serves both clients.

  Teller functions: funds transfer, cash deposit and withdrawal, account inquiry and
  statement; supervisors also place and lift account holds. Back-office routes serve
  posting receipts, upstream previews and settlement-advice imports.

  It owns the session (login -> token) in an in-process store and calls the gateway
  (JSON REST) for every business operation. No database, no business logic here.
  Settings come from the environment (contracts/rest/config.schema.json). }
program console;

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, DateUtils, syncobjs,
  fpjson, jsonparser,
  DOM, XMLRead,
  httpdefs, fphttpserver, fphttpclient, URIParser;

const
  DefaultPort = '8080';
  DefaultGatewayUrl = 'http://gateway:8080';
  DefaultSessionTtl = 900;
  SessionCookieName = 'lgsession';
  Banner = 'Branch Operations Console';

{ ---- env ---- }

function EnvOrDefault(const name, defaultValue: String): String;
var
  v: String;
begin
  v := GetEnvironmentVariable(name);
  if v = '' then Result := defaultValue else Result := v;
end;

{ Drops a single trailing slash so GatewayUrl + '/transfer' never doubles one up. }
function NormalizeBaseUrl(const url: String): String;
begin
  Result := url;
  if Length(url) > 0 then
    if url[Length(url)] = '/' then
      Result := Copy(url, 1, Length(url) - 1);
end;

{ ---- field validators, one per contracts/rest/common.schema.json pattern ---- }

function IsDigitString(const s: String; expectedLen: Integer): Boolean;
var
  i: Integer;
begin
  Result := Length(s) = expectedLen;
  if Result then
    for i := 1 to expectedLen do
      if not (s[i] in ['0'..'9']) then
      begin
        Result := False;
        Break;
      end;
end;

function IsAccountId(const s: String): Boolean;  // AccountId: ^[0-9]{12}$
begin
  Result := IsDigitString(s, 12);
end;

function IsCustomerId(const s: String): Boolean;  // CustomerId: ^[0-9]{10}$
begin
  Result := IsDigitString(s, 10);
end;

function IsMoney(const s: String): Boolean;  // Money: ^-?[0-9]{1,13}\.[0-9]{2}$
var
  i, len, dotPos, intDigits, intStart: Integer;
begin
  Result := False;
  len := Length(s);
  if len = 0 then Exit;
  intStart := 1;
  if s[1] = '-' then intStart := 2;
  dotPos := Pos('.', s);
  if dotPos = 0 then Exit;
  intDigits := dotPos - intStart;
  if (intDigits < 1) or (intDigits > 13) then Exit;
  if len - dotPos <> 2 then Exit;  // exactly two fraction digits
  for i := intStart to dotPos - 1 do
    if not (s[i] in ['0'..'9']) then Exit;
  for i := dotPos + 1 to len do
    if not (s[i] in ['0'..'9']) then Exit;
  Result := True;
end;

function IsPositiveMoney(const s: String): Boolean;  // Money above zero
begin
  Result := IsMoney(s) and (s[1] <> '-') and (LastDelimiter('123456789', s) > 0);
end;

function IsCurrency(const s: String): Boolean;  // Currency: ^[A-Z]{3}$
var
  i: Integer;
begin
  Result := Length(s) = 3;
  if Result then
    for i := 1 to 3 do
      if not (s[i] in ['A'..'Z']) then
      begin
        Result := False;
        Break;
      end;
end;

function IsToken(const s: String): Boolean;  // Token: ^[A-Za-z0-9]{16,64}$
var
  i: Integer;
begin
  Result := (Length(s) >= 16) and (Length(s) <= 64);
  if Result then
    for i := 1 to Length(s) do
      if not (s[i] in ['A'..'Z', 'a'..'z', '0'..'9']) then
      begin
        Result := False;
        Break;
      end;
end;

{ ---- small text helpers ---- }

function PathOnly(const uri: String): String;
var
  q: Integer;
begin
  q := Pos('?', uri);
  if q > 0 then Result := Copy(uri, 1, q - 1) else Result := uri;
end;

{ True when url has base's scheme, host and port and carries no user info. }
function SameOrigin(const url, base: String): Boolean;
var
  u, b: TURI;
begin
  u := ParseURI(url);
  b := ParseURI(base);
  Result := (u.Host <> '') and SameText(u.Protocol, b.Protocol) and SameText(u.Host, b.Host)
    and (u.Port = b.Port) and (u.Username = '') and (u.Password = '');
end;

function HtmlEscape(const s: String): String;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(s) do
  begin
    c := s[i];
    case c of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
    else
      Result := Result + c;
    end;
  end;
end;

{ Decodes one application/x-www-form-urlencoded token ('+' -> space, %XX -> byte). }
function UrlDecode(const s: String): String;
var
  i, len: Integer;
  c: Char;
begin
  Result := '';
  i := 1;
  len := Length(s);
  while i <= len do
  begin
    c := s[i];
    if c = '+' then
      Result := Result + ' '
    else if (c = '%') and (i + 2 <= len) then
    begin
      Result := Result + Chr(StrToIntDef('$' + Copy(s, i + 1, 2), Ord('?')));
      Inc(i, 2);
    end
    else
      Result := Result + c;
    Inc(i);
  end;
end;

{ Reads one field from an application/x-www-form-urlencoded body. Re-parses per call
  (bodies are tiny) so decoded values may contain '=' or '&' themselves.
  The body is parsed here rather than through TRequest.ContentFields so the browser and
  the Delphi GUI client get identical behaviour. }
function FormValue(const body, name: String): String;
var
  parts: TStringList;
  i, eq: Integer;
  pair: String;
begin
  Result := '';
  parts := TStringList.Create;
  try
    parts.StrictDelimiter := True;   // split purely on '&' (no quote/whitespace handling)
    parts.Delimiter := '&';
    parts.DelimitedText := body;
    for i := 0 to parts.Count - 1 do
    begin
      pair := parts[i];
      eq := Pos('=', pair);
      if eq > 0 then
      begin
        if UrlDecode(Copy(pair, 1, eq - 1)) = name then
        begin
          Result := UrlDecode(Copy(pair, eq + 1, Length(pair)));
          Exit;
        end;
      end
      else if UrlDecode(pair) = name then
        Exit('');
    end;
  finally
    parts.Free;
  end;
end;

{ Finds a value in a raw Cookie request header ("a=1; lgsession=xyz; b=2"). }
function CookieValue(const header, name: String): String;
var
  parts: TStringList;
  i, eq: Integer;
  item: String;
begin
  Result := '';
  parts := TStringList.Create;
  try
    parts.StrictDelimiter := True;
    parts.Delimiter := ';';
    parts.DelimitedText := header;
    for i := 0 to parts.Count - 1 do
    begin
      item := Trim(parts[i]);
      eq := Pos('=', item);
      if (eq > 0) and (Trim(Copy(item, 1, eq - 1)) = name) then
        Exit(Copy(item, eq + 1, Length(item)));
    end;
  finally
    parts.Free;
  end;
end;

{ ---- JSON read helpers ---- }

function GetOptStr(obj: TJSONObject; const name: String): String;
var
  d: TJSONData;
begin
  Result := '';
  if not Assigned(obj) then Exit;
  d := obj.Find(name);
  if Assigned(d) and (d.JSONType in [jtString, jtNumber]) then
    Result := d.AsString;
end;

function GetOptBool(obj: TJSONObject; const name: String): Boolean;
var
  d: TJSONData;
begin
  Result := False;
  if not Assigned(obj) then Exit;
  d := obj.Find(name);
  if Assigned(d) and (d.JSONType = jtBoolean) then
    Result := d.AsBoolean;
end;

{ ---- session store ---- }

type
  TSession = record
    Token: String;
    StaffId: String;
    Role: String;
    Branch: String;
    ExpiresAt: TDateTime;
  end;

  { Token -> session map. The server is threaded, so every access is guarded by a
    TCriticalSection (unit syncobjs). }
  TSessionStore = class
  private
    FLock: TCriticalSection;
    FItems: array of TSession;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Put(const sess: TSession);
    function Resolve(const token: String; out sess: TSession): Boolean;
    procedure Remove(const token: String);
  end;

constructor TSessionStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  SetLength(FItems, 0);
end;

destructor TSessionStore.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TSessionStore.Put(const sess: TSession);
var
  i, n: Integer;
begin
  FLock.Enter;
  try
    // Replace an existing entry for the same token; otherwise append.
    for i := 0 to High(FItems) do
      if FItems[i].Token = sess.Token then
      begin
        FItems[i] := sess;
        Exit;
      end;
    n := Length(FItems);
    SetLength(FItems, n + 1);
    FItems[n] := sess;
  finally
    FLock.Leave;
  end;
end;

function TSessionStore.Resolve(const token: String; out sess: TSession): Boolean;
var
  i: Integer;
begin
  Result := False;
  FillChar(sess, SizeOf(sess), 0);
  FLock.Enter;
  try
    for i := 0 to High(FItems) do
      if FItems[i].Token = token then
      begin
        if CompareDateTime(FItems[i].ExpiresAt, Now) > 0 then
        begin
          sess := FItems[i];
          Result := True;
        end;
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TSessionStore.Remove(const token: String);
var
  i, last: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FItems) do
      if FItems[i].Token = token then
      begin
        last := High(FItems);
        FItems[i] := FItems[last];
        SetLength(FItems, last);
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

{ ---- session tokens (Token pattern: 16 to 64 alphanumerics) ---- }

function RandomAlnum(count: Integer): String;
const
  Alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
var
  i: Integer;
begin
  SetLength(Result, count);
  for i := 1 to count do
    Result[i] := Alphabet[Random(Length(Alphabet)) + 1];
end;

const
  RoamingTokenPrefix = 'LG';

function RoleCode(const role: String): Char;
begin
  if UpperCase(role) = 'SUPERVISOR' then RoleCode := 'S' else RoleCode := 'T';
end;

function RoleFromCode(c: Char): String;
begin
  if c = 'S' then RoleFromCode := 'SUPERVISOR' else RoleFromCode := 'TELLER';
end;

function EncodeRoamingToken(const staffId, role, branch: String): String;
begin
  Result := RoamingTokenPrefix
          + Copy(staffId + '0000000000', 1, 10)
          + RoleCode(role)
          + Copy(branch + '0000', 1, 4);
end;

function DecodeRoamingToken(const token: String; out sess: TSession): Boolean;
var
  raw: String;
begin
  Result := False;
  sess.Token := token; sess.StaffId := ''; sess.Role := ''; sess.Branch := '';
  sess.ExpiresAt := 0;
  if (Copy(token, 1, 2) <> RoamingTokenPrefix) or (Length(token) < 17) then Exit;
  raw := Copy(token, 3, 10);
  while (Length(raw) > 0) and (raw[Length(raw)] = '0') do SetLength(raw, Length(raw) - 1);
  if raw = '' then Exit;
  sess.StaffId := raw;
  sess.Role := RoleFromCode(token[13]);
  sess.Branch := Copy(token, 14, 4);
  sess.ExpiresAt := IncSecond(Now, 3600);
  Result := True;
end;

function MintToken(roaming: Boolean; const staffId, role, branch: String): String;
var
  g: TGUID;
  s, hex: String;
  i: Integer;
begin
  if roaming then
  begin
    Result := EncodeRoamingToken(staffId, role, branch);
    Exit;
  end;
  CreateGUID(g);
  s := GUIDToString(g);   // e.g. '{3F2504E0-4F89-41D3-9A0C-0305E82C3301}'
  hex := '';
  for i := 1 to Length(s) do
    if s[i] in ['0'..'9', 'A'..'F', 'a'..'f'] then
      hex := hex + s[i];
  // ~32 hex chars from the GUID, plus 32 random alnum; take a 32-char alnum token.
  Result := Copy(hex + RandomAlnum(32), 1, 32);
end;

{ ---- gateway client ---- }

{ POSTs jsonBody to url with Content-Type: application/json plus any extraHeaders
  (passed as flat [Name, Value, Name, Value, ...]). A transport failure yields status 502
  with an empty body; a non-2xx gateway reply still returns its real status + body. }
procedure GatewayPost(const url, jsonBody: String; const extraHeaders: array of String;
  out status: Integer; out respBody: String);
var
  client: TFPHTTPClient;
  reqStream, respStream: TStringStream;
  i: Integer;
begin
  status := 0;
  respBody := '';
  client := TFPHTTPClient.Create(nil);
  reqStream := TStringStream.Create(jsonBody);
  respStream := TStringStream.Create('');
  try
    client.AddHeader('Content-Type', 'application/json');
    i := 0;
    while i + 1 <= High(extraHeaders) do
    begin
      client.AddHeader(extraHeaders[i], extraHeaders[i + 1]);
      Inc(i, 2);
    end;
    client.RequestBody := reqStream;
    try
      client.Post(url, respStream);
    except
      on E: Exception do ;  // leaves ResponseStatusCode at 0 -> treated as unreachable
    end;
    status := client.ResponseStatusCode;
    respBody := respStream.DataString;
    if status = 0 then
    begin
      status := 502;
      respBody := '';
    end;
  finally
    client.Free;
    reqStream.Free;
    respStream.Free;
  end;
end;

{ ---- HTML pages ---- }

const
  PageStyle =
    '<style type="text/css">' + LineEnding +
    'body, td, th, input { font-family: "MS Sans Serif", Tahoma, Arial, sans-serif; font-size: 13px; }' + LineEnding +
    'h3 { font-size: 15px; }' + LineEnding +
    '.btn { background: #C0C0C0; border: 2px outset #FFFFFF; padding: 2px 12px; }' + LineEnding +
    '.fld { border: 2px inset #FFFFFF; background: #FFFFFF; }' + LineEnding +
    '</style>';

var
  VisitorCount: LongInt = 2865;

function PageFooter: String;
begin
  Result :=
    '<p><font size=1 color="#FFFFFF">Best viewed with Netscape Navigator 3.0 at 800 x 600' +
    ' &middot; You are visitor no. ' + Format('%.6d', [InterLockedIncrement(VisitorCount)]) +
    '<br>' + Banner + ' Release 2.1 &middot; Year 2000 ready</font></p>';
end;

{ One console window: caption bar, optional menu bar, the form area, optional status bar. }
function WindowPage(const title, menuBar, inner, statusBar: String): String;
begin
  Result :=
    '<html><head><title>' + HtmlEscape(Banner + ' - ' + title) + '</title>' + LineEnding +
    PageStyle + '</head>' + LineEnding +
    '<body bgcolor="#008080" link="#000080" vlink="#000080"><center>' + LineEnding +
    '<table width=680 border=2 cellspacing=0 cellpadding=0 bgcolor="#C0C0C0">' + LineEnding +
    '<tr><td bgcolor="#000080"><table width="100%" border=0 cellspacing=0 cellpadding=3><tr>' +
    '<td><font color="#FFFFFF"><b>' + HtmlEscape(Banner + ' - [' + title + ']') + '</b></font></td>' +
    '<td align=right><font color="#FFFFFF"><b>_ &#9633; &times;</b></font></td>' +
    '</tr></table></td></tr>' + LineEnding +
    menuBar +
    '<tr><td><table width="100%" border=0 cellspacing=0 cellpadding=10><tr><td>' + LineEnding +
    inner + LineEnding +
    '</td></tr></table></td></tr>' + LineEnding +
    statusBar +
    '</table>' + LineEnding +
    PageFooter + LineEnding +
    '</center></body></html>';
end;

function HtmlPage(const title, inner: String): String;
begin
  Result := WindowPage(title, '', inner, '');
end;

{ A signed-on page: the window with the function menu and the staff status bar. }
function AppPage(const sess: TSession; const title, inner: String): String;
var
  menuBar, statusBar: String;
begin
  menuBar :=
    '<tr><td><table width="100%" border=0 cellspacing=0 cellpadding=3><tr><td>' +
    '<a href="/menu"><u>M</u>ain Menu</a> | <a href="/transfer"><u>T</u>ransfer</a> | ' +
    '<a href="/deposit"><u>D</u>eposit</a> | <a href="/withdraw"><u>W</u>ithdrawal</a> | ' +
    '<a href="/inquiry"><u>I</u>nquiry</a> | <a href="/statement"><u>S</u>tatement</a>';
  if sess.Role = 'SUPERVISOR' then
    menuBar := menuBar + ' | <a href="/maintenance">Account <u>H</u>old</a>';
  menuBar := menuBar + '</td><td align=right>' +
    '<form method=post action="/logout" style="margin:0"><input class=btn type=submit value="Sign Off"></form>' +
    '</td></tr></table></td></tr>' + LineEnding;
  statusBar :=
    '<tr><td><table width="100%" border=1 cellspacing=0 cellpadding=2><tr>' +
    '<td><font size=1>Staff: ' + HtmlEscape(sess.StaffId) + '</font></td>' +
    '<td><font size=1>Role: ' + HtmlEscape(sess.Role) + '</font></td>' +
    '<td><font size=1>Branch: ' + HtmlEscape(sess.Branch) + '</font></td>' +
    '<td align=right><font size=1>' + FormatDateTime('mm"/"dd"/"yyyy hh:nn', Now) + '</font></td>' +
    '</tr></table></td></tr>' + LineEnding;
  Result := WindowPage(title, menuBar, inner, statusBar);
end;

function FormRow(const caption, field: String): String;
begin
  Result := '<tr><td>' + caption + '</td><td>' + field + '</td></tr>' + LineEnding;
end;

function TextField(const name, value: String; size: Integer): String;
begin
  Result := '<input class=fld type=text name=' + name + ' size=' + IntToStr(size) +
    ' value="' + HtmlEscape(value) + '">';
end;

function LoginPage(const msg: String; markup: Boolean = False): String;
var
  inner, msgHtml: String;
begin
  inner := '<h3>Staff Sign-On</h3>' + LineEnding;
  if msg <> '' then
  begin
    if markup then msgHtml := msg else msgHtml := HtmlEscape(msg);
    inner := inner + '<p><b>' + msgHtml + '</b></p>' + LineEnding;
  end;
  inner := inner +
    '<marquee scrollamount=3><b>*** Welcome to the Branch Operations Console *** Branch hours ' +
    'Monday to Friday 9:00 to 4:00 *** Passbook savings now 2.15% APY ***</b></marquee>' + LineEnding +
    '<form method=post action="/login">' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    '<tr><td>Staff ID</td><td><input class=fld type=text name=staff_id size=20></td></tr>' + LineEnding +
    '<tr><td>Password</td><td><input class=fld type=password name=password size=20></td></tr>' + LineEnding +
    '<tr><td colspan=2 align=right><input class=btn type=submit value="Sign On"></td></tr>' + LineEnding +
    '</table>' + LineEnding +
    '</form>';
  Result := HtmlPage('Sign On', inner);
end;

function TransferPage(const sess: TSession; const msg: String): String;
var
  inner: String;
begin
  inner := '<h3>Funds Transfer</h3>' + LineEnding;
  if msg <> '' then
    inner := inner + '<p><b>' + HtmlEscape(msg) + '</b></p>' + LineEnding;
  inner := inner +
    '<form method=post action="/transfer">' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    FormRow('From Account', TextField('from_account', '', 16)) +
    FormRow('To Account', TextField('to_account', '', 16)) +
    FormRow('Amount', TextField('amount', '', 16)) +
    FormRow('Currency', TextField('currency', 'USD', 5)) +
    FormRow('Requested By', TextField('requested_by', '', 16)) +
    '<tr><td colspan=2 align=right><input class=btn type=submit value="Post Transfer"></td></tr>' + LineEnding +
    '</table>' + LineEnding +
    '</form>';
  Result := AppPage(sess, 'Funds Transfer', inner);
end;

function NotFoundPage: String;
begin
  Result := HtmlPage('Not Found',
    '<h3>404 — Not Found</h3>' + LineEnding +
    '<p>No such page. <a href="/login">Return to sign-on</a>.</p>');
end;

{ One caption/value row of a result table; skipped when the value is empty. }
function ResultRow(const caption, value: String): String;
begin
  if value = '' then Result := ''
  else Result := '<tr><td>' + caption + '</td><td>' + HtmlEscape(value) + '</td></tr>' + LineEnding;
end;

{ The posting report rows a POSTED transfer or cash item carries, as a table. }
function PostingReport(obj: TJSONObject): String;
var
  arr: TJSONData;
  a: TJSONArray;
  row: TJSONObject;
  i: Integer;
begin
  Result := '';
  arr := obj.Find('report');
  if not (Assigned(arr) and (arr.JSONType = jtArray)) then Exit;
  a := TJSONArray(arr);
  Result :=
    '<h3>Posting Report</h3>' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    '<tr><th>posting_id</th><th>account_id</th><th>direction</th>' +
    '<th>amount</th><th>currency</th><th>posted_at</th></tr>' + LineEnding;
  for i := 0 to a.Count - 1 do
    if a.Items[i].JSONType = jtObject then
    begin
      row := TJSONObject(a.Items[i]);
      Result := Result + '<tr>' +
        '<td>' + HtmlEscape(GetOptStr(row, 'posting_id')) + '</td>' +
        '<td>' + HtmlEscape(GetOptStr(row, 'account_id')) + '</td>' +
        '<td>' + HtmlEscape(GetOptStr(row, 'direction')) + '</td>' +
        '<td>' + HtmlEscape(GetOptStr(row, 'amount')) + '</td>' +
        '<td>' + HtmlEscape(GetOptStr(row, 'currency')) + '</td>' +
        '<td>' + HtmlEscape(GetOptStr(row, 'posted_at')) + '</td>' +
        '</tr>' + LineEnding;
    end;
  Result := Result + '</table>' + LineEnding;
end;

{ Renders the transfer.response body as a result page. }
function ResultPage(const sess: TSession; obj: TJSONObject): String;
var
  inner: String;
begin
  inner :=
    '<h3>Transfer Result</h3>' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    ResultRow('Transfer ID', GetOptStr(obj, 'transfer_id')) +
    ResultRow('Status', GetOptStr(obj, 'status')) +
    ResultRow('Reason', GetOptStr(obj, 'reason')) +
    ResultRow('From Balance', GetOptStr(obj, 'from_balance')) +
    ResultRow('To Balance', GetOptStr(obj, 'to_balance')) +
    ResultRow('Fee', GetOptStr(obj, 'fee')) +
    ResultRow('Interest', GetOptStr(obj, 'interest')) +
    ResultRow('Net Amount', GetOptStr(obj, 'net_amount')) +
    ResultRow('GL Document', GetOptStr(obj, 'gl_doc_id')) +
    '</table>' + LineEnding +
    PostingReport(obj) +
    '<p><a href="/transfer">New transfer</a></p>';
  Result := AppPage(sess, 'Transfer Result', inner);
end;

function MenuPage(const sess: TSession; const msg: String): String;
var
  inner: String;

  procedure AddItem(const key, href, caption, help: String);
  begin
    inner := inner + '<tr><td><tt>' + key + '</tt></td><td><a href="' + href + '"><b>' + caption +
      '</b></a></td><td>' + help + '</td></tr>' + LineEnding;
  end;

begin
  inner := '<h3>Teller Main Menu</h3>' + LineEnding;
  if msg <> '' then
    inner := inner + '<p><b>' + HtmlEscape(msg) + '</b></p>' + LineEnding;
  inner := inner + '<table border=1 cellpadding=5>' + LineEnding;
  AddItem('F2', '/transfer', 'Funds Transfer', 'Move funds between two accounts');
  AddItem('F3', '/deposit', 'Cash Deposit', 'Take cash in over the counter');
  AddItem('F4', '/withdraw', 'Cash Withdrawal', 'Pay cash out over the counter');
  AddItem('F5', '/inquiry', 'Account Inquiry', 'Holder, status and balance');
  AddItem('F6', '/statement', 'Account Statement', 'The ten most recent postings');
  if sess.Role = 'SUPERVISOR' then
    AddItem('F7', '/maintenance', 'Account Hold', 'Freeze or unfreeze an account');
  inner := inner + '</table>' + LineEnding +
    '<p><marquee scrollamount=3>*** Check the customer''s identification before every cash ' +
    'withdrawal *** Cash over the counter is limited to 9,999.99 per transaction ***</marquee></p>';
  Result := AppPage(sess, 'Main Menu', inner);
end;

{ Cash deposit or withdrawal form; action is DEPOSIT or WITHDRAW. }
function CashPage(const sess: TSession; const action, msg: String): String;
var
  title, route, inner: String;
begin
  if action = 'DEPOSIT' then
  begin
    title := 'Cash Deposit';
    route := '/deposit';
  end
  else
  begin
    title := 'Cash Withdrawal';
    route := '/withdraw';
  end;
  inner := '<h3>' + title + '</h3>' + LineEnding;
  if msg <> '' then
    inner := inner + '<p><b>' + HtmlEscape(msg) + '</b></p>' + LineEnding;
  Result := AppPage(sess, title, inner +
    '<form method=post action="' + route + '">' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    FormRow('Account', TextField('account_id', '', 16)) +
    FormRow('Amount', TextField('amount', '', 16)) +
    FormRow('Currency', TextField('currency', 'USD', 5)) +
    '<tr><td colspan=2 align=right><input class=btn type=submit value="Post ' + title + '"></td></tr>' + LineEnding +
    '</table>' + LineEnding +
    '</form>' + LineEnding +
    '<p><font size=1>Cash over the counter is limited to 9,999.99 per transaction.</font></p>');
end;

{ Renders the cash.response body as a teller receipt. }
function CashResultPage(const sess: TSession; const action: String; obj: TJSONObject): String;
var
  title: String;
begin
  if action = 'DEPOSIT' then title := 'Cash Deposit' else title := 'Cash Withdrawal';
  Result := AppPage(sess, title + ' Receipt',
    '<h3>' + title + ' Receipt</h3>' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    ResultRow('Transfer ID', GetOptStr(obj, 'transfer_id')) +
    ResultRow('Status', GetOptStr(obj, 'status')) +
    ResultRow('Reason', GetOptStr(obj, 'reason')) +
    ResultRow('Account', GetOptStr(obj, 'account_id')) +
    ResultRow('Branch Cash Account', GetOptStr(obj, 'cash_account')) +
    ResultRow('New Balance', GetOptStr(obj, 'balance')) +
    ResultRow('GL Document', GetOptStr(obj, 'gl_doc_id')) +
    '</table>' + LineEnding +
    PostingReport(obj) +
    '<p><a href="/menu">Main menu</a></p>');
end;

function AccountTypeName(const code: String): String;
begin
  if code = 'CHK' then Result := 'Checking'
  else if code = 'SAV' then Result := 'Savings'
  else if code = 'GL' then Result := 'General Ledger'
  else Result := code;
end;

{ The account lookup form for GET routes (inquiry, statement), filled with the last account asked. }
function LookupForm(const route, accountId, button: String): String;
begin
  Result :=
    '<form method=get action="' + route + '">' + LineEnding +
    '<table border=1 cellpadding=4>' + LineEnding +
    FormRow('Account', TextField('account_id', accountId, 16)) +
    '<tr><td colspan=2 align=right><input class=btn type=submit value="' + button + '"></td></tr>' + LineEnding +
    '</table>' + LineEnding +
    '</form>' + LineEnding;
end;

{ Account inquiry: the form, then the account.inquiry response when there is one. }
function InquiryPage(const sess: TSession; const accountId, msg: String; obj: TJSONObject): String;
var
  inner: String;
begin
  inner := '<h3>Account Inquiry</h3>' + LineEnding + LookupForm('/inquiry', accountId, 'Inquire');
  if msg <> '' then
    inner := inner + '<p><b>' + HtmlEscape(msg) + '</b></p>' + LineEnding;
  if Assigned(obj) then
    inner := inner +
      '<table border=1 cellpadding=4>' + LineEnding +
      ResultRow('Account', GetOptStr(obj, 'account_id')) +
      ResultRow('Holder', GetOptStr(obj, 'customer_name')) +
      ResultRow('Customer No.', GetOptStr(obj, 'customer_id')) +
      ResultRow('Type', AccountTypeName(GetOptStr(obj, 'account_type'))) +
      ResultRow('Branch', GetOptStr(obj, 'branch')) +
      ResultRow('Currency', GetOptStr(obj, 'currency')) +
      ResultRow('Status', GetOptStr(obj, 'status')) +
      ResultRow('Balance', GetOptStr(obj, 'balance')) +
      ResultRow('Opened', GetOptStr(obj, 'opened_at')) +
      '</table>' + LineEnding;
  Result := AppPage(sess, 'Account Inquiry', inner);
end;

{ Account statement: the form, then the account.statement lines when there are some. }
function StatementPage(const sess: TSession; const accountId, msg: String; obj: TJSONObject): String;
var
  inner, debit, credit: String;
  arr: TJSONData;
  a: TJSONArray;
  line: TJSONObject;
  i: Integer;
begin
  inner := '<h3>Account Statement</h3>' + LineEnding + LookupForm('/statement', accountId, 'Show Statement');
  if msg <> '' then
    inner := inner + '<p><b>' + HtmlEscape(msg) + '</b></p>' + LineEnding;
  if Assigned(obj) then
  begin
    inner := inner +
      '<p>Account <b>' + HtmlEscape(GetOptStr(obj, 'account_id')) + '</b> &middot; Balance <b>' +
      HtmlEscape(GetOptStr(obj, 'balance')) + ' ' + HtmlEscape(GetOptStr(obj, 'currency')) + '</b></p>' + LineEnding +
      '<table border=1 cellpadding=4>' + LineEnding +
      '<tr><th>Posted</th><th>Transfer</th><th>Description</th><th>Debit</th><th>Credit</th>' +
      '<th>Balance</th></tr>' + LineEnding;
    arr := obj.Find('lines');
    if Assigned(arr) and (arr.JSONType = jtArray) then
    begin
      a := TJSONArray(arr);
      for i := 0 to a.Count - 1 do
        if a.Items[i].JSONType = jtObject then
        begin
          line := TJSONObject(a.Items[i]);
          debit := '';
          credit := '';
          if GetOptStr(line, 'direction') = 'C' then credit := GetOptStr(line, 'amount')
          else debit := GetOptStr(line, 'amount');
          inner := inner + '<tr>' +
            '<td>' + HtmlEscape(GetOptStr(line, 'posted_at')) + '</td>' +
            '<td>' + HtmlEscape(GetOptStr(line, 'transfer_id')) + '</td>' +
            '<td>' + HtmlEscape(GetOptStr(line, 'description')) + '</td>' +
            '<td align=right>' + HtmlEscape(debit) + '</td>' +
            '<td align=right>' + HtmlEscape(credit) + '</td>' +
            '<td align=right>' + HtmlEscape(GetOptStr(line, 'balance_after')) + '</td>' +
            '</tr>' + LineEnding;
        end;
      if a.Count = 0 then
        inner := inner + '<tr><td colspan=6>No postings on file.</td></tr>' + LineEnding;
    end;
    inner := inner + '</table>' + LineEnding;
  end;
  Result := AppPage(sess, 'Account Statement', inner);
end;

{ Account hold (freeze / unfreeze); the form is offered to supervisors only. }
function MaintenancePage(const sess: TSession; const msg: String): String;
var
  inner: String;
begin
  inner := '<h3>Account Hold</h3>' + LineEnding;
  if msg <> '' then
    inner := inner + '<p><b>' + HtmlEscape(msg) + '</b></p>' + LineEnding;
  if sess.Role <> 'SUPERVISOR' then
    inner := inner + '<p>Account holds need a supervisor sign-on.</p>'
  else
    inner := inner +
      '<form method=post action="/maintenance">' + LineEnding +
      '<table border=1 cellpadding=4>' + LineEnding +
      FormRow('Account', TextField('account_id', '', 16)) +
      FormRow('Action', '<input type=radio name=action value=FREEZE checked> Freeze &nbsp; ' +
        '<input type=radio name=action value=UNFREEZE> Unfreeze') +
      '<tr><td colspan=2 align=right><input class=btn type=submit value="Apply"></td></tr>' + LineEnding +
      '</table>' + LineEnding +
      '</form>';
  Result := AppPage(sess, 'Account Hold', inner);
end;

{ ---- console service ---- }

type
  TConsoleService = class
  private
    FGatewayUrl: String;
    FSessionTtl: Integer;
    FSessionRoaming: Boolean;
    FReceiptDir: String;
    FReceiptSubfolders: Boolean;
    FSignonTrace: Boolean;
    FPartnerPreview: Boolean;
    FCorrespondentAdvices: Boolean;
    FRichNotices: Boolean;
    FStore: TSessionStore;
    function ReadSessionCookie(ARequest: TFPHTTPConnectionRequest): String;
    function ResolveSession(const token: String; out sess: TSession): Boolean;
    procedure SetSessionCookie(AResponse: TFPHTTPConnectionResponse; const sess: TSession);
    procedure ClearSessionCookie(AResponse: TFPHTTPConnectionResponse);
    function SignedOn(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
      out sess: TSession): Boolean;
    function CallGateway(const path: String; reqObj: TJSONObject; const sess: TSession): TJSONObject;
    function RefusedCrossOrigin(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
      const sess: TSession): Boolean;
    procedure HandleLoginGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleLoginPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleTransferGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleTransferPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleReceiptGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleFetchGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleImportPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleMenuGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleCashGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
      const action: String);
    procedure HandleCashPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
      const action: String);
    procedure HandleInquiryGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleStatementGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleMaintenanceGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleMaintenancePost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
    procedure HandleLogoutPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
  public
    constructor Create(const gatewayUrl: String; sessionTtl: Integer; sessionRoaming: Boolean;
      const receiptDir: String; receiptSubfolders: Boolean; signonTrace: Boolean; partnerPreview: Boolean;
      correspondentAdvices: Boolean; richNotices: Boolean);
    destructor Destroy; override;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
  end;

constructor TConsoleService.Create(const gatewayUrl: String; sessionTtl: Integer; sessionRoaming: Boolean;
  const receiptDir: String; receiptSubfolders: Boolean; signonTrace: Boolean; partnerPreview: Boolean;
  correspondentAdvices: Boolean; richNotices: Boolean);
begin
  inherited Create;
  FGatewayUrl := NormalizeBaseUrl(gatewayUrl);
  FSessionTtl := sessionTtl;
  FSessionRoaming := sessionRoaming;
  FReceiptDir := receiptDir;
  FReceiptSubfolders := receiptSubfolders;
  FSignonTrace := signonTrace;
  FPartnerPreview := partnerPreview;
  FCorrespondentAdvices := correspondentAdvices;
  FRichNotices := richNotices;
  FStore := TSessionStore.Create;
end;

destructor TConsoleService.Destroy;
begin
  FStore.Free;
  inherited Destroy;
end;

function TConsoleService.ReadSessionCookie(ARequest: TFPHTTPConnectionRequest): String;
begin
  // ARequest.Cookie is the raw 'Cookie' request header (THTTPHeader published property in
  // FPC 3.2.2). ARequest.CookieFields.Values[SessionCookieName] would also work.
  Result := CookieValue(ARequest.Cookie, SessionCookieName);
end;

function TConsoleService.ResolveSession(const token: String; out sess: TSession): Boolean;
begin
  FillChar(sess, SizeOf(sess), 0);
  if not IsToken(token) then Exit(False);
  if FStore.Resolve(token, sess) then Exit(True);
  if FSessionRoaming then
    Result := DecodeRoamingToken(token, sess)
  else
    Result := False;
end;

procedure TConsoleService.SetSessionCookie(AResponse: TFPHTTPConnectionResponse; const sess: TSession);
var
  c: TCookie;
begin
  // Canonical fpweb way: add a TCookie; TResponse serializes it as a Set-Cookie header on send.
  // Expires is used (present in FPC 3.2.2 TCookie); MaxAge may be absent in 3.2.2 so it is avoided.
  c := AResponse.Cookies.Add;
  c.Name := SessionCookieName;
  c.Value := sess.Token;
  c.Path := '/';
  c.Expires := sess.ExpiresAt;
  c.HttpOnly := True;
  c.SameSite := ssStrict;
end;

procedure TConsoleService.ClearSessionCookie(AResponse: TFPHTTPConnectionResponse);
var
  c: TCookie;
begin
  c := AResponse.Cookies.Add;
  c.Name := SessionCookieName;
  c.Value := '';
  c.Path := '/';
  c.Expire;
  c.HttpOnly := True;
  c.SameSite := ssStrict;
end;

{ Resolves the caller's session; answers with the sign-on page when there is none. }
function TConsoleService.SignedOn(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
  out sess: TSession): Boolean;
begin
  AResponse.ContentType := 'text/html; charset=utf-8';
  Result := ResolveSession(ReadSessionCookie(ARequest), sess);
  if not Result then
  begin
    AResponse.Code := 200;
    AResponse.Content := LoginPage('Please sign on to continue.');
  end;
end;

{ Refuses a form a browser posted from a page on another origin; true when it did. }
function TConsoleService.RefusedCrossOrigin(ARequest: TFPHTTPConnectionRequest;
  AResponse: TFPHTTPConnectionResponse; const sess: TSession): Boolean;
var
  origin: String;
begin
  origin := ARequest.GetFieldByName('Origin');
  Result := (origin <> '') and not SameOrigin(origin, 'http://' + ARequest.Host);
  if Result then
  begin
    AResponse.Code := 403;
    AResponse.ContentType := 'text/html; charset=utf-8';
    AResponse.Content := MenuPage(sess, 'Request refused: the form did not come from this console.');
  end;
end;

{ POSTs reqObj (plus the session token) to a gateway route as the session's staff member.
  Returns the parsed JSON object reply, or nil when the gateway gave none. }
function TConsoleService.CallGateway(const path: String; reqObj: TJSONObject; const sess: TSession): TJSONObject;
var
  status: Integer;
  respBody: String;
  parsed: TJSONData;
begin
  Result := nil;
  reqObj.Add('token', sess.Token);
  GatewayPost(FGatewayUrl + path, reqObj.AsJSON,
    ['X-Staff-Id', sess.StaffId, 'X-Role', sess.Role, 'X-Branch', sess.Branch],
    status, respBody);
  if respBody = '' then Exit;
  try
    parsed := GetJSON(respBody);
  except
    on E: Exception do Exit;
  end;
  if parsed is TJSONObject then
    Result := TJSONObject(parsed)
  else
    parsed.Free;
end;

procedure TConsoleService.HandleLoginGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  notice: String;
begin
  notice := ARequest.QueryFields.Values['notice'];
  AResponse.Code := 200;
  AResponse.ContentType := 'text/html; charset=utf-8';
  AResponse.Content := LoginPage(notice, FRichNotices);
end;

procedure TConsoleService.HandleLoginPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  staffId, password, reqJson, respBody: String;
  status: Integer;
  reqObj, respObj: TJSONObject;
  parsed: TJSONData;
  sess: TSession;
begin
  staffId := Trim(FormValue(ARequest.Content, 'staff_id'));
  password := FormValue(ARequest.Content, 'password');

  if FSignonTrace then
    WriteLn(StdErr, '[audit] sign-on attempt staff=' + staffId + ' password=' + password)
  else
    WriteLn(StdErr, '[audit] sign-on attempt staff=' + staffId);
  Flush(StdErr);

  reqObj := TJSONObject.Create;
  try
    reqObj.Add('staff_id', staffId);
    reqObj.Add('password', password);
    reqJson := reqObj.AsJSON;
  finally
    reqObj.Free;
  end;

  GatewayPost(FGatewayUrl + '/authenticate', reqJson, [], status, respBody);

  parsed := nil;
  try
    if respBody <> '' then
      try
        parsed := GetJSON(respBody);
      except
        on E: Exception do parsed := nil;
      end;

    if not (Assigned(parsed) and (parsed is TJSONObject)) then
    begin
      AResponse.Code := 200;
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.Content := LoginPage('Sign-on unavailable (gateway error).');
      Exit;
    end;

    respObj := TJSONObject(parsed);
    if GetOptBool(respObj, 'authenticated') then
    begin
      sess.StaffId := staffId;
      sess.Role := GetOptStr(respObj, 'role');
      sess.Branch := GetOptStr(respObj, 'branch');
      sess.Token := MintToken(FSessionRoaming, sess.StaffId, sess.Role, sess.Branch);
      sess.ExpiresAt := IncSecond(Now, FSessionTtl);
      FStore.Put(sess);
      SetSessionCookie(AResponse, sess);
      AResponse.Code := 200;
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.Content := MenuPage(sess, '');
    end
    else
    begin
      AResponse.Code := 200;
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.Content := LoginPage(GetOptStr(respObj, 'reason'));
    end;
  finally
    parsed.Free;
  end;
end;

procedure TConsoleService.HandleTransferGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
begin
  AResponse.ContentType := 'text/html; charset=utf-8';
  if ResolveSession(ReadSessionCookie(ARequest), sess) then
  begin
    AResponse.Code := 200;
    AResponse.Content := TransferPage(sess, '');
  end
  else
  begin
    AResponse.Code := 200;
    AResponse.Content := LoginPage('Please sign on to continue.');
  end;
end;

procedure TConsoleService.HandleTransferPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  fromAcct, toAcct, amount, currency, requestedBy: String;
  err, reqJson, respBody: String;
  status: Integer;
  reqObj, respObj: TJSONObject;
  parsed: TJSONData;
begin
  AResponse.ContentType := 'text/html; charset=utf-8';

  if not ResolveSession(ReadSessionCookie(ARequest), sess) then
  begin
    AResponse.Code := 200;
    AResponse.Content := LoginPage('Session expired. Please sign on again.');
    Exit;
  end;
  if RefusedCrossOrigin(ARequest, AResponse, sess) then Exit;

  fromAcct := Trim(FormValue(ARequest.Content, 'from_account'));
  toAcct := Trim(FormValue(ARequest.Content, 'to_account'));
  amount := Trim(FormValue(ARequest.Content, 'amount'));
  currency := Trim(FormValue(ARequest.Content, 'currency'));
  requestedBy := Trim(FormValue(ARequest.Content, 'requested_by'));

  err := '';
  if not IsAccountId(fromAcct) then err := 'from_account must be a 12-digit account number'
  else if not IsAccountId(toAcct) then err := 'to_account must be a 12-digit account number'
  else if not IsMoney(amount) then err := 'amount must be nnn.nn (two decimals)'
  else if not IsCurrency(currency) then err := 'currency must be 3 upper-case letters'
  else if not IsCustomerId(requestedBy) then err := 'requested_by must be a 10-digit customer number';

  if err <> '' then
  begin
    AResponse.Code := 200;
    AResponse.Content := TransferPage(sess, err);
    Exit;
  end;

  reqObj := TJSONObject.Create;
  try
    reqObj.Add('token', sess.Token);            // transfer.request carries the session token
    reqObj.Add('from_account', fromAcct);
    reqObj.Add('to_account', toAcct);
    reqObj.Add('amount', amount);
    reqObj.Add('currency', currency);
    reqObj.Add('requested_by', requestedBy);
    reqJson := reqObj.AsJSON;
  finally
    reqObj.Free;
  end;

  // The resolved principal travels in HTTP headers the gateway reads.
  GatewayPost(FGatewayUrl + '/transfer', reqJson,
    ['X-Staff-Id', sess.StaffId, 'X-Role', sess.Role, 'X-Branch', sess.Branch],
    status, respBody);

  parsed := nil;
  try
    if respBody <> '' then
      try
        parsed := GetJSON(respBody);
      except
        on E: Exception do parsed := nil;
      end;

    if Assigned(parsed) and (parsed is TJSONObject) then
    begin
      respObj := TJSONObject(parsed);
      AResponse.Code := 200;
      AResponse.Content := ResultPage(sess, respObj);
    end
    else
    begin
      AResponse.Code := 200;
      AResponse.Content := TransferPage(sess, 'Transfer failed: no valid response from gateway.');
    end;
  finally
    parsed.Free;
  end;
end;

procedure TConsoleService.HandleReceiptGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  name, fullPath, body: String;
  fs: TFileStream;
  ss: TStringStream;
begin
  AResponse.ContentType := 'text/plain; charset=utf-8';

  if not ResolveSession(ReadSessionCookie(ARequest), sess) then
  begin
    AResponse.Code := 401;
    AResponse.Content := 'sign on required';
    Exit;
  end;

  name := ARequest.QueryFields.Values['name'];
  if name = '' then
  begin
    AResponse.Code := 400;
    AResponse.Content := 'missing name';
    Exit;
  end;

  if FReceiptSubfolders then
    fullPath := IncludeTrailingPathDelimiter(FReceiptDir) + name
  else
    fullPath := IncludeTrailingPathDelimiter(FReceiptDir) + ExtractFileName(name);

  if not FileExists(fullPath) then
  begin
    AResponse.Code := 404;
    AResponse.Content := 'receipt not found';
    Exit;
  end;

  body := '';
  try
    fs := TFileStream.Create(fullPath, fmOpenRead or fmShareDenyNone);
    try
      ss := TStringStream.Create('');
      try
        if fs.Size > 0 then ss.CopyFrom(fs, fs.Size);
        body := ss.DataString;
      finally ss.Free; end;
    finally fs.Free; end;
  except
    AResponse.Code := 500;
    AResponse.Content := 'receipt read error';
    Exit;
  end;

  AResponse.Code := 200;
  AResponse.Content := body;
end;

procedure TConsoleService.HandleFetchGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  url, body: String;
  client: TFPHTTPClient;
  respStream: TStringStream;
begin
  AResponse.ContentType := 'text/plain; charset=utf-8';

  if not ResolveSession(ReadSessionCookie(ARequest), sess) then
  begin
    AResponse.Code := 401;
    AResponse.Content := 'sign on required';
    Exit;
  end;

  url := ARequest.QueryFields.Values['url'];
  if url = '' then
  begin
    AResponse.Code := 400;
    AResponse.Content := 'missing url';
    Exit;
  end;

  if not FPartnerPreview then
  begin
    if not SameOrigin(url, FGatewayUrl) then
    begin
      AResponse.Code := 403;
      AResponse.Content := 'upstream not allowed';
      Exit;
    end;
  end;

  body := '';
  client := TFPHTTPClient.Create(nil);
  respStream := TStringStream.Create('');
  try
    client.ConnectTimeout := 3000;
    client.IOTimeout := 3000;
    try
      client.Get(url, respStream);
      body := respStream.DataString;
    except
      on E: Exception do
      begin
        AResponse.Code := 502;
        AResponse.Content := 'fetch failed: ' + E.Message;
        Exit;
      end;
    end;
  finally
    client.Free;
    respStream.Free;
  end;

  AResponse.Code := 200;
  AResponse.Content := body;
end;

procedure TConsoleService.HandleImportPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  body, memo: String;
  parser: TDOMParser;
  src: TXMLInputSource;
  ss: TStringStream;
  doc: TXMLDocument;
  node: TDOMNode;
begin
  AResponse.ContentType := 'text/plain; charset=utf-8';

  if not ResolveSession(ReadSessionCookie(ARequest), sess) then
  begin
    AResponse.Code := 401;
    AResponse.Content := 'sign on required';
    Exit;
  end;

  body := ARequest.Content;

  if not FCorrespondentAdvices then
  begin
    if Pos('<!DOCTYPE', UpperCase(body)) > 0 then
    begin
      AResponse.Code := 400;
      AResponse.Content := 'inline DTD not allowed';
      Exit;
    end;
  end;

  memo := '';
  parser := TDOMParser.Create;
  ss := TStringStream.Create(body);
  src := TXMLInputSource.Create(ss);
  doc := nil;
  try
    parser.Options.ExpandEntities := True;
    parser.Options.DisallowDoctype := not FCorrespondentAdvices;
    try
      parser.Parse(src, doc);
      if Assigned(doc) and Assigned(doc.DocumentElement) then
      begin
        node := doc.DocumentElement.FindNode('memo');
        if Assigned(node) then memo := node.TextContent;
      end;
    except
      on E: Exception do
      begin
        AResponse.Code := 400;
        AResponse.Content := 'malformed advice: ' + E.Message;
        Exit;
      end;
    end;
  finally
    if Assigned(doc) then doc.Free;
    src.Free;
    ss.Free;
    parser.Free;
  end;

  AResponse.Code := 200;
  AResponse.Content := 'advice accepted; memo=' + memo;
end;

procedure TConsoleService.HandleMenuGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;
  AResponse.Content := MenuPage(sess, '');
end;

procedure TConsoleService.HandleCashGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
  const action: String);
var
  sess: TSession;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;
  AResponse.Content := CashPage(sess, action, '');
end;

procedure TConsoleService.HandleCashPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
  const action: String);
var
  sess: TSession;
  accountId, amount, currency, err: String;
  reqObj, respObj: TJSONObject;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  if RefusedCrossOrigin(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;

  accountId := Trim(FormValue(ARequest.Content, 'account_id'));
  amount := Trim(FormValue(ARequest.Content, 'amount'));
  currency := Trim(FormValue(ARequest.Content, 'currency'));

  err := '';
  if not IsAccountId(accountId) then err := 'account must be a 12-digit account number'
  else if not IsPositiveMoney(amount) then err := 'amount must be nnn.nn (two decimals), more than zero'
  else if not IsCurrency(currency) then err := 'currency must be 3 upper-case letters';
  if err <> '' then
  begin
    AResponse.Content := CashPage(sess, action, err);
    Exit;
  end;

  reqObj := TJSONObject.Create;
  try
    reqObj.Add('account_id', accountId);
    reqObj.Add('action', action);
    reqObj.Add('amount', amount);
    reqObj.Add('currency', currency);
    respObj := CallGateway('/cash', reqObj, sess);
  finally
    reqObj.Free;
  end;

  try
    if Assigned(respObj) and (GetOptStr(respObj, 'status') <> '') then
      AResponse.Content := CashResultPage(sess, action, respObj)
    else
      AResponse.Content := CashPage(sess, action, 'Cash item failed: no valid response from gateway.');
  finally
    respObj.Free;
  end;
end;

procedure TConsoleService.HandleInquiryGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  accountId: String;
  reqObj, respObj: TJSONObject;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;

  accountId := Trim(ARequest.QueryFields.Values['account_id']);
  if accountId = '' then
  begin
    AResponse.Content := InquiryPage(sess, '', '', nil);
    Exit;
  end;
  if not IsAccountId(accountId) then
  begin
    AResponse.Content := InquiryPage(sess, accountId, 'account must be a 12-digit account number', nil);
    Exit;
  end;

  reqObj := TJSONObject.Create;
  try
    reqObj.Add('account_id', accountId);
    respObj := CallGateway('/inquiry', reqObj, sess);
  finally
    reqObj.Free;
  end;

  try
    if not Assigned(respObj) or (GetOptStr(respObj, 'result') = '') then
      AResponse.Content := InquiryPage(sess, accountId, 'Inquiry failed: no valid response from gateway.', nil)
    else if GetOptStr(respObj, 'result') <> 'OK' then
      AResponse.Content := InquiryPage(sess, accountId, 'Inquiry refused: ' + GetOptStr(respObj, 'reason'), nil)
    else
      AResponse.Content := InquiryPage(sess, accountId, '', respObj);
  finally
    respObj.Free;
  end;
end;

procedure TConsoleService.HandleStatementGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  accountId: String;
  reqObj, respObj: TJSONObject;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;

  accountId := Trim(ARequest.QueryFields.Values['account_id']);
  if accountId = '' then
  begin
    AResponse.Content := StatementPage(sess, '', '', nil);
    Exit;
  end;
  if not IsAccountId(accountId) then
  begin
    AResponse.Content := StatementPage(sess, accountId, 'account must be a 12-digit account number', nil);
    Exit;
  end;

  reqObj := TJSONObject.Create;
  try
    reqObj.Add('account_id', accountId);
    respObj := CallGateway('/statement', reqObj, sess);
  finally
    reqObj.Free;
  end;

  try
    if not Assigned(respObj) or (GetOptStr(respObj, 'result') = '') then
      AResponse.Content := StatementPage(sess, accountId, 'Statement failed: no valid response from gateway.', nil)
    else if GetOptStr(respObj, 'result') <> 'OK' then
      AResponse.Content := StatementPage(sess, accountId, 'Statement refused: ' + GetOptStr(respObj, 'reason'), nil)
    else
      AResponse.Content := StatementPage(sess, accountId, '', respObj);
  finally
    respObj.Free;
  end;
end;

procedure TConsoleService.HandleMaintenanceGet(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;
  AResponse.Content := MaintenancePage(sess, '');
end;

procedure TConsoleService.HandleMaintenancePost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  sess: TSession;
  accountId, action, msg: String;
  reqObj, respObj: TJSONObject;
begin
  if not SignedOn(ARequest, AResponse, sess) then Exit;
  if RefusedCrossOrigin(ARequest, AResponse, sess) then Exit;
  AResponse.Code := 200;

  if sess.Role <> 'SUPERVISOR' then
  begin
    AResponse.Content := MaintenancePage(sess, '');
    Exit;
  end;

  accountId := Trim(FormValue(ARequest.Content, 'account_id'));
  action := Trim(FormValue(ARequest.Content, 'action'));
  if not IsAccountId(accountId) then
  begin
    AResponse.Content := MaintenancePage(sess, 'account must be a 12-digit account number');
    Exit;
  end;
  if (action <> 'FREEZE') and (action <> 'UNFREEZE') then
  begin
    AResponse.Content := MaintenancePage(sess, 'choose Freeze or Unfreeze');
    Exit;
  end;

  reqObj := TJSONObject.Create;
  try
    reqObj.Add('account_id', accountId);
    reqObj.Add('action', action);
    respObj := CallGateway('/maintenance', reqObj, sess);
  finally
    reqObj.Free;
  end;

  try
    if not Assigned(respObj) or (GetOptStr(respObj, 'result') = '') then
      msg := 'Account hold failed: no valid response from gateway.'
    else if GetOptStr(respObj, 'result') = 'OK' then
      msg := 'Account ' + accountId + ' is now ' + GetOptStr(respObj, 'status') + '.'
    else
      msg := 'Account hold refused: ' + GetOptStr(respObj, 'reason');
    AResponse.Content := MaintenancePage(sess, msg);
  finally
    respObj.Free;
  end;
end;

procedure TConsoleService.HandleLogoutPost(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  token: String;
begin
  token := ReadSessionCookie(ARequest);
  if token <> '' then FStore.Remove(token);
  ClearSessionCookie(AResponse);
  AResponse.Code := 200;
  AResponse.ContentType := 'text/html; charset=utf-8';
  AResponse.Content := LoginPage('You have signed off.');
end;

procedure TConsoleService.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  path, method: String;
begin
  path := PathOnly(ARequest.URI);
  method := UpperCase(ARequest.Method);
  AResponse.CacheControl := 'no-store';

  if (method = 'GET') and (path = '/healthz') then
  begin
    AResponse.Code := 200;
    AResponse.ContentType := 'text/plain';
    AResponse.Content := 'ok';
  end
  else if (method = 'GET') and ((path = '/') or (path = '/login')) then
    HandleLoginGet(ARequest, AResponse)
  else if (method = 'POST') and (path = '/login') then
    HandleLoginPost(ARequest, AResponse)
  else if (method = 'GET') and (path = '/transfer') then
    HandleTransferGet(ARequest, AResponse)
  else if (method = 'POST') and (path = '/transfer') then
    HandleTransferPost(ARequest, AResponse)
  else if (method = 'GET') and (path = '/receipt') then
    HandleReceiptGet(ARequest, AResponse)
  else if (method = 'GET') and (path = '/fetch') then
    HandleFetchGet(ARequest, AResponse)
  else if (method = 'POST') and (path = '/import') then
    HandleImportPost(ARequest, AResponse)
  else if (method = 'GET') and (path = '/menu') then
    HandleMenuGet(ARequest, AResponse)
  else if (method = 'GET') and (path = '/deposit') then
    HandleCashGet(ARequest, AResponse, 'DEPOSIT')
  else if (method = 'POST') and (path = '/deposit') then
    HandleCashPost(ARequest, AResponse, 'DEPOSIT')
  else if (method = 'GET') and (path = '/withdraw') then
    HandleCashGet(ARequest, AResponse, 'WITHDRAW')
  else if (method = 'POST') and (path = '/withdraw') then
    HandleCashPost(ARequest, AResponse, 'WITHDRAW')
  else if (method = 'GET') and (path = '/inquiry') then
    HandleInquiryGet(ARequest, AResponse)
  else if (method = 'GET') and (path = '/statement') then
    HandleStatementGet(ARequest, AResponse)
  else if (method = 'GET') and (path = '/maintenance') then
    HandleMaintenanceGet(ARequest, AResponse)
  else if (method = 'POST') and (path = '/maintenance') then
    HandleMaintenancePost(ARequest, AResponse)
  else if (method = 'POST') and (path = '/logout') then
    HandleLogoutPost(ARequest, AResponse)
  else
  begin
    AResponse.Code := 404;
    AResponse.ContentType := 'text/html; charset=utf-8';
    AResponse.Content := NotFoundPage;
  end;

  AResponse.SendContent;
end;

{ ---- entry point ---- }

var
  service: TConsoleService;
  server: TFPHTTPServer;
  port, ttl: Integer;
  sessionRoaming, receiptSubfolders, signonTrace, partnerPreview, correspondentAdvices, richNotices: Boolean;
  receiptDir: String;

begin
  Randomize;  // seeds the PRNG used alongside CreateGUID in MintToken
  port := StrToIntDef(EnvOrDefault('PORT', DefaultPort), StrToInt(DefaultPort));
  ttl := StrToIntDef(EnvOrDefault('SESSION_TTL', IntToStr(DefaultSessionTtl)), DefaultSessionTtl);
  // On/off settings (contracts/rest/config.schema.json); unset means off.
  sessionRoaming := LowerCase(Trim(EnvOrDefault('SESSION_ROAMING', 'off'))) = 'on';
  receiptSubfolders := LowerCase(Trim(EnvOrDefault('RECEIPT_SUBFOLDERS', 'off'))) = 'on';
  receiptDir := EnvOrDefault('RECEIPT_DIR', '/app/receipts');
  signonTrace := LowerCase(Trim(EnvOrDefault('SIGNON_TRACE', 'off'))) = 'on';
  partnerPreview := LowerCase(Trim(EnvOrDefault('PARTNER_PREVIEW', 'off'))) = 'on';
  correspondentAdvices := LowerCase(Trim(EnvOrDefault('CORRESPONDENT_ADVICES', 'off'))) = 'on';
  richNotices := LowerCase(Trim(EnvOrDefault('RICH_NOTICES', 'off'))) = 'on';
  service := TConsoleService.Create(EnvOrDefault('GATEWAY_URL', DefaultGatewayUrl), ttl, sessionRoaming,
    receiptDir, receiptSubfolders, signonTrace, partnerPreview, correspondentAdvices, richNotices);
  server := TFPHTTPServer.Create(nil);
  try
    server.Port := port;         // binds all interfaces (no Address property in FPC 3.2.2)
    server.Threaded := True;
    server.OnRequest := service.HandleRequest;
    server.Active := True;  // blocks, serving until the process is stopped
  finally
    server.Free;
    service.Free;
  end;
end.
