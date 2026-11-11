/* postrpt.sas -- posting/settlement report connector.
   Reads one REPORT-REQUEST record (48 chars) from stdin, resolves it into macro vars, reads the
   matching LEDGER rows from PostgreSQL via PROC SQL EXPLICIT pass-through, and writes one
   REPORT-ROW record (92 chars) per posting to stdout. Layouts: ../contracts/records/
   sas-report-io.md. Ledger columns: ../contracts/copybook/ledger-posting.cpy. Money form:
   ../contracts/data-model.md. Settings: ../contracts/rest/config.schema.json. */

filename reqrec "/dev/stdin";
filename rptrec "/dev/stdout";

%let sql_host     = %sysget(SQL_HOST);
%let sql_dbname   = %sysget(SQL_DBNAME);
%let sql_user     = %sysget(SQL_USER);
%let sql_password = %sysget(SQL_PASSWORD);
%let as_of_dates  = %sysget(AS_OF_DATES);

/* Resolve REPORT-REQUEST into macro vars: transfer_id 1-20, report_type 21-28, as_of 29-48. */
data _null_;
  infile reqrec length=reclen;
  input
    transfer_id $char20. @1
    report_type $char8.  @21
    as_of       $char20. @29;
  call symputx('transfer_id', strip(transfer_id));
  call symputx('report_type', strip(report_type));
  call symputx('as_of',       strip(as_of));
run;

%macro postrpt;
  /* Request fields must match their contract patterns. */
  %if %sysfunc(prxmatch(/^[A-Z0-9]{1,20}$/, &transfer_id)) = 0 %then %do;
    %put ERROR: postrpt: transfer_id "&transfer_id" fails contract pattern ^[A-Z0-9]{1,20}$.;
    %abort cancel;
  %end;
  %if &report_type ne POSTING and &report_type ne SETTLE %then %do;
    %put ERROR: postrpt: report_type "&report_type" is not POSTING or SETTLE.;
    %abort cancel;
  %end;
  %if %sysfunc(prxmatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, &as_of)) = 0 %then %do;
    %put ERROR: postrpt: as_of "&as_of" is not a contract timestamp.;
    %abort cancel;
  %end;

  proc sql;
    connect to postgres (server="&sql_host" port=5432 database="&sql_dbname"
                          user="&sql_user" password="&sql_password");

    create table work.report_rows as
    select * from connection to postgres (
      /* report_type has no LEDGER column to filter on; both report types read the same rows. */
      select posting_id, transfer_id, account_id, direction, amount, currency, posted_at
      from ledger
      where transfer_id = '&transfer_id.'
        and posted_at <= '&as_of.'
      order by posted_at, posting_id
    );

    disconnect from postgres;
  quit;
%mend postrpt;

%postrpt;

/* Optional post-report archive step (report_archive). */
%let report_archive = %sysget(REPORT_ARCHIVE);
%let export_label   = %sysget(EXPORT_LABEL);

%macro do_export;
  %if %upcase(&report_archive) = ON and %length(&export_label) > 0 %then %do;
    %sysexec echo archiving posting report to "&export_label";
  %end;
%mend do_export;
%do_export;

/* Emit REPORT-ROW: posting_id 20 / transfer_id 20 / account_id 12 / direction 1 / amount 16
   (money, right-justified 2dp) / currency 3 / posted_at 20 = 92 chars. */
data _null_;
  set work.report_rows;
  file rptrec;
  length out_line $92;
  out_line = put(posting_id, $char20.)
          || put(transfer_id, $char20.)
          || put(account_id, $char12.)
          || put(direction, $char1.)
          || put(amount, 16.2)
          || put(currency, $char3.)
          || put(posted_at, $char20.);
  put out_line;
run;
