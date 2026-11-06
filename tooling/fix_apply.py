#!/usr/bin/env python3
"""Apply the per-instance FIXES to a tree, producing the clean `fixed` source.

Each fix removes a planted instance's exploitable construct and keeps the other branch of its
setting (the manifest `fix:` note), so a scanner run on the fixed tree should find nothing. Fixes
are exact-text replacements against main's app source; a missing or repeated anchor is a hard error,
so drift is caught rather than skipped.

Covers all 16 instances. LG-SECR-001 (hardcoded salt) is fixed minimally by env-sourcing the salt
(removing the source literal so a CWE-760 scan is clean); the deployment provides PW_SALT.

SAS (LG-CMDI-001, LG-SQLI-002): the runtime is legacy-goat-runtimes/runtimes/sas/shim.py, which
mirrors the mounted sas/postrpt.sas by two marker strings: `%upcase(&as_of_dates) ne ON` and
`to &export_label;`. The fixes below remove both, so the fixed source is inert in the shim too.
Keep the markers and the shim in step.

usage: fix_apply.py <tree_dir>
"""
import sys
import os

FIXES = [
    # ---- pascal/console.pas ----
    ("pascal/console.pas",  # LG-AUTH-001: always mint a store token
     """  if roaming then
  begin
    Result := EncodeRoamingToken(staffId, role, branch);
    Exit;
  end;
  CreateGUID(g);""",
     """  CreateGUID(g);"""),

    ("pascal/console.pas",  # LG-AUTH-001: only store-issued tokens resolve
     """  if FStore.Resolve(token, sess) then Exit(True);
  if FSessionRoaming then
    Result := DecodeRoamingToken(token, sess)
  else
    Result := False;""",
     """  if FStore.Resolve(token, sess) then Exit(True);
  Result := False;"""),

    ("pascal/console.pas",  # LG-LOG-001: never log the credential
     """  if FSignonTrace then
    WriteLn(StdErr, '[audit] sign-on attempt staff=' + staffId + ' password=' + password)
  else
    WriteLn(StdErr, '[audit] sign-on attempt staff=' + staffId);""",
     """  WriteLn(StdErr, '[audit] sign-on attempt staff=' + staffId);"""),

    ("pascal/console.pas",  # LG-PATH-001: always reduce to a basename
     """  if FReceiptSubfolders then
    fullPath := IncludeTrailingPathDelimiter(FReceiptDir) + name
  else
    fullPath := IncludeTrailingPathDelimiter(FReceiptDir) + ExtractFileName(name);""",
     """  fullPath := IncludeTrailingPathDelimiter(FReceiptDir) + ExtractFileName(name);"""),

    ("pascal/console.pas",  # LG-SSRF-001: gateway origin check is unconditional
     """  if not FPartnerPreview then
  begin
    if not SameOrigin(url, FGatewayUrl) then
    begin
      AResponse.Code := 403;
      AResponse.Content := 'upstream not allowed';
      Exit;
    end;
  end;""",
     """  if not SameOrigin(url, FGatewayUrl) then
  begin
    AResponse.Code := 403;
    AResponse.Content := 'upstream not allowed';
    Exit;
  end;"""),

    ("pascal/console.pas",  # LG-XXE-001: reject inline DTDs unconditionally
     """  if not FCorrespondentAdvices then
  begin
    if Pos('<!DOCTYPE', UpperCase(body)) > 0 then
    begin
      AResponse.Code := 400;
      AResponse.Content := 'inline DTD not allowed';
      Exit;
    end;
  end;""",
     """  if Pos('<!DOCTYPE', UpperCase(body)) > 0 then
  begin
    AResponse.Code := 400;
    AResponse.Content := 'inline DTD not allowed';
    Exit;
  end;"""),

    ("pascal/console.pas",  # LG-XXE-001: the parser refuses a document type in any encoding
     """    parser.Options.DisallowDoctype := not FCorrespondentAdvices;""",
     """    parser.Options.DisallowDoctype := True;"""),

    ("pascal/console.pas",  # LG-XSS-001: always escape the notice
     """  AResponse.Content := LoginPage(notice, FRichNotices);""",
     """  AResponse.Content := LoginPage(notice, False);"""),

    # ---- cobol/staffauth.cbl ----
    ("cobol/staffauth.cbl",  # LG-SQLI-001: always the bound lookup
     """              IF FUNCTION LOWER-CASE(WS-SESSION-ROAMING(1:2)) = "on"
                 PERFORM SIGNON-BY-QUERY
              ELSE
                 PERFORM SIGNON-BY-LOOKUP
              END-IF""",
     """              PERFORM SIGNON-BY-LOOKUP"""),

    # ---- cobol/postxfer.cbl ----
    ("cobol/postxfer.cbl",  # LG-BIZ-001: reject non-positive amounts
     """           COMPUTE WS-AMT = FUNCTION NUMVAL(TR-AMOUNT).
           COMPUTE WS-THRESHOLD = FUNCTION NUMVAL(TR-APPROVAL-OVER).""",
     """           COMPUTE WS-AMT = FUNCTION NUMVAL(TR-AMOUNT).
           IF WS-AMT <= 0
              MOVE "N" TO WS-OK
              MOVE "AMOUNT MUST BE POSITIVE" TO TP-REASON
           END-IF.
           COMPUTE WS-THRESHOLD = FUNCTION NUMVAL(TR-APPROVAL-OVER)."""),

    ("cobol/postxfer.cbl",  # LG-AC-001: branch scope always applied
     """              WHEN WS-HOME-BRANCH-ONLY(1:3) NOT = "off"
                   AND AM-BRANCH NOT = TR-ACTOR-BRANCH""",
     """              WHEN AM-BRANCH NOT = TR-ACTOR-BRANCH"""),

    ("cobol/postxfer.cbl",  # LG-DLII-001: numeric guard unconditional
     """           IF WS-ALNUM-CUST-IDS(1:2) NOT = "on"
              IF FUNCTION TEST-NUMVAL(TR-REQUESTED-BY) NOT = ZERO
                 MOVE "N" TO WS-OK
                 MOVE "CUSTOMER NOT FOUND" TO TP-REASON
              END-IF
           END-IF.""",
     """           IF FUNCTION TEST-NUMVAL(TR-REQUESTED-BY) NOT = ZERO
              MOVE "N" TO WS-OK
              MOVE "CUSTOMER NOT FOUND" TO TP-REASON
           END-IF."""),

    ("cobol/postxfer.cbl",  # LG-MEM-001: clamp the tier index unconditionally
     """           IF WS-EXTENDED-TIERS(1:2) NOT = "on"
              IF WS-TIER-IDX > 3
                 MOVE 3 TO WS-TIER-IDX
              END-IF
           END-IF.""",
     """           IF WS-TIER-IDX > 3
              MOVE 3 TO WS-TIER-IDX
           END-IF."""),

    # ---- fortran/riskfee.f90 ----
    ("fortran/riskfee.f90",  # LG-NUM-001: 64-bit rounding
     """    fee_cents = nint(amount * rate * 100.0d0)""",
     """    fee_cents = nint(amount * rate * 100.0d0, kind=8)"""),

    # ---- abap/zcl_gl_post.clas.abap ----
    ("abap/zcl_gl_post.clas.abap",  # LG-INJ-001: always escape the reference
     """    IF lv_preformatted = 'on'.
      lv_ref_out = lv_reference.
    ELSE.
      lv_ref_out = escape_json_value( lv_reference ).
    ENDIF.""",
     """    lv_ref_out = escape_json_value( lv_reference )."""),

    # ---- sas/postrpt.sas (source fix; the shim mirrors it) ----
    ("sas/postrpt.sas",  # LG-SQLI-002: as_of validation unconditional
     """  %if %upcase(&as_of_dates) ne ON %then %do;
    %if %sysfunc(prxmatch(/^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$/, &as_of)) = 0 %then %do;
      %put ERROR: postrpt: as_of "&as_of" is not a contract timestamp.;
      %abort cancel;
    %end;
  %end;""",
     """  %if %sysfunc(prxmatch(/^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$/, &as_of)) = 0 %then %do;
    %put ERROR: postrpt: as_of "&as_of" is not a contract timestamp.;
    %abort cancel;
  %end;"""),

    ("sas/postrpt.sas",  # LG-CMDI-001: quote the label so metacharacters are inert (feature kept)
     """    %sysexec echo archiving posting report to &export_label;""",
     """    %sysexec echo archiving posting report to "&export_label";"""),

    # ---- cobol/signon.cpy + staffauth.cbl (LG-SECR-001) ----
    ("cobol/signon.cpy",  # remove the hardcoded salt literal (provisioned at runtime)
     """       01  PW-SALT              PIC X(16) VALUE "SALT".""",
     """       01  PW-SALT              PIC X(16)."""),

    ("cobol/staffauth.cbl",  # source the salt from the environment instead of a literal
     """           DISPLAY "SESSION_ROAMING" UPON ENVIRONMENT-NAME.
           ACCEPT WS-SESSION-ROAMING FROM ENVIRONMENT-VALUE.""",
     """           DISPLAY "SESSION_ROAMING" UPON ENVIRONMENT-NAME.
           ACCEPT WS-SESSION-ROAMING FROM ENVIRONMENT-VALUE.
           DISPLAY "PW_SALT" UPON ENVIRONMENT-NAME.
           ACCEPT PW-SALT FROM ENVIRONMENT-VALUE."""),
]


def main():
    if len(sys.argv) != 2:
        print("usage: fix_apply.py <tree_dir>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    applied = 0
    for rel, old, new in FIXES:
        path = os.path.join(root, rel)
        with open(path, "r", errors="surrogateescape") as f:
            text = f.read()
        if old not in text:
            print(f"fix_apply: ANCHOR NOT FOUND in {rel}:\n---\n{old[:120]}\n---", file=sys.stderr)
            return 1
        if text.count(old) != 1:
            print(f"fix_apply: anchor not unique ({text.count(old)}x) in {rel}", file=sys.stderr)
            return 1
        with open(path, "w", errors="surrogateescape") as f:
            f.write(text.replace(old, new))
        applied += 1
    print(f"fix_apply: applied {applied} fixes under {root} (all 16 instances)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
