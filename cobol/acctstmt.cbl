       IDENTIFICATION DIVISION.
       PROGRAM-ID. ACCTSTMT.
      *> Account statement. Reads STATEMENT-REQUEST (text) from stdin, checks the account against
      *> the VSAM master, and returns its ten most recent ledger lines from the SQL ledger, newest
      *> first, each with the balance once it had posted. Writes STATEMENT-REPLY.
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT ACCT-FILE ASSIGN TO WS-ACCT-PATH
               ORGANIZATION INDEXED ACCESS DYNAMIC
               RECORD KEY AM-ACCOUNT-ID
               FILE STATUS WS-ACCT-ST.
       DATA DIVISION.
       FILE SECTION.
       FD  ACCT-FILE.
           COPY "account-master.cpy".
       WORKING-STORAGE SECTION.
           EXEC SQL BEGIN DECLARE SECTION END-EXEC.
           01 DATASRC              PIC X(64).
           01 DBUSR                PIC X(64).
           01 HV-ACCOUNT-ID        PIC X(12).
      *> Fetch targets are oversized: GixSQL writes the value plus a terminator.
           01 HV-POSTING-ID        PIC X(24).
           01 HV-TRANSFER-ID       PIC X(24).
           01 HV-DIRECTION         PIC X(04).
           01 HV-AMOUNT            PIC S9(13)V99 COMP-3.
           01 HV-POSTED-AT         PIC X(24).
           01 HV-DESC              PIC X(44).
           EXEC SQL END DECLARE SECTION END-EXEC.
           EXEC SQL INCLUDE SQLCA END-EXEC.
           COPY "core-ops.cpy".
           01 WS-ACCT-PATH         PIC X(80).
           01 WS-ACCT-ST           PIC X(02).
           01 WS-N                 PIC 9(02) VALUE 0.
           01 WS-EOF               PIC X(01) VALUE "N".
           01 WS-RUN               PIC S9(15)V99.
           01 WS-EDIT              PIC -(12)9.99.
      *> WS-GIXPP-TAIL stays the LAST working-storage item: gixpp comments out the final line it
      *> emits, so this sacrificial placeholder absorbs that. Add new items ABOVE it.
           01 WS-GIXPP-TAIL        PIC X(01).
       PROCEDURE DIVISION.
       MAIN-PARA.
           PERFORM READ-ENV.
           ACCEPT STATEMENT-REQUEST.
           MOVE SPACES TO STATEMENT-REPLY.
           MOVE ZERO TO SR-LINE-COUNT.
           MOVE SQ-ACCOUNT-ID TO SR-ACCOUNT-ID.
           MOVE "REJECTED" TO SR-RESULT.
           EVALUATE TRUE
              WHEN SQ-ACTOR-ROLE NOT = "TELLER"
                   AND SQ-ACTOR-ROLE NOT = "SUPERVISOR"
                 MOVE "ROLE NOT PERMITTED" TO SR-REASON
              WHEN SQ-ACCOUNT-ID IS NOT NUMERIC
                 MOVE "ACCOUNT NOT FOUND" TO SR-REASON
              WHEN OTHER
                 PERFORM READ-ACCOUNT
           END-EVALUATE.
           IF SR-RESULT = "OK"
              PERFORM LIST-LINES
           END-IF.
           DISPLAY STATEMENT-REPLY.
           STOP RUN.
       READ-ENV.
           DISPLAY "DATASRC" UPON ENVIRONMENT-NAME.
           ACCEPT DATASRC FROM ENVIRONMENT-VALUE.
           DISPLAY "DBUSR" UPON ENVIRONMENT-NAME.
           ACCEPT DBUSR FROM ENVIRONMENT-VALUE.
           DISPLAY "ACCT_FILE" UPON ENVIRONMENT-NAME.
           ACCEPT WS-ACCT-PATH FROM ENVIRONMENT-VALUE.
       READ-ACCOUNT.
           OPEN INPUT ACCT-FILE.
           IF WS-ACCT-ST NOT = "00"
              MOVE "ACCOUNT FILE UNAVAILABLE" TO SR-REASON
           ELSE
              MOVE SQ-ACCOUNT-ID TO AM-ACCOUNT-ID
              READ ACCT-FILE KEY IS AM-ACCOUNT-ID
                 INVALID KEY
                    MOVE "ACCOUNT NOT FOUND" TO SR-REASON
                 NOT INVALID KEY
                    PERFORM CHECK-BRANCH
              END-READ
              CLOSE ACCT-FILE
           END-IF.
       CHECK-BRANCH.
           IF AM-BRANCH NOT = SQ-ACTOR-BRANCH
              MOVE "OUT OF BRANCH SCOPE" TO SR-REASON
           ELSE
              MOVE "OK" TO SR-RESULT
              MOVE AM-CURRENCY TO SR-CURRENCY
              MOVE AM-BALANCE TO WS-RUN
              MOVE AM-BALANCE TO WS-EDIT
              MOVE WS-EDIT TO SR-BALANCE
           END-IF.
       LIST-LINES.
           EXEC SQL CONNECT TO :DATASRC USER :DBUSR END-EXEC.
           IF SQLCODE NOT = 0
              PERFORM LIST-FAILED
           ELSE
              PERFORM OPEN-LINES
              EXEC SQL DISCONNECT ALL END-EXEC
           END-IF.
       OPEN-LINES.
           MOVE SQ-ACCOUNT-ID TO HV-ACCOUNT-ID.
           EXEC SQL
              DECLARE STMTCUR CURSOR FOR
                 SELECT posting_id, transfer_id, direction, amount,
                        posted_at, COALESCE(description, ' ')
                   FROM ledger
                  WHERE account_id = RTRIM(:HV-ACCOUNT-ID)
                  ORDER BY line_no DESC
                  LIMIT 10
           END-EXEC.
           EXEC SQL OPEN STMTCUR END-EXEC.
           IF SQLCODE NOT = 0
              PERFORM LIST-FAILED
           ELSE
              PERFORM FETCH-LINE UNTIL WS-EOF = "Y"
              EXEC SQL CLOSE STMTCUR END-EXEC
           END-IF.
       FETCH-LINE.
           EXEC SQL
              FETCH STMTCUR INTO :HV-POSTING-ID, :HV-TRANSFER-ID,
                 :HV-DIRECTION, :HV-AMOUNT, :HV-POSTED-AT, :HV-DESC
           END-EXEC.
           EVALUATE TRUE
              WHEN SQLCODE = 100 OR WS-N = 10
                 MOVE "Y" TO WS-EOF
              WHEN SQLCODE NOT = 0
                 MOVE "Y" TO WS-EOF
                 PERFORM LIST-FAILED
              WHEN OTHER
                 ADD 1 TO WS-N
                 PERFORM ADD-LINE
           END-EVALUATE.
       ADD-LINE.
      *> Lines come newest first, so WS-RUN walks the balance back past each one.
           MOVE HV-POSTING-ID TO SR-POSTING-ID(WS-N).
           MOVE HV-TRANSFER-ID TO SR-TRANSFER-ID(WS-N).
           MOVE HV-DIRECTION TO SR-DIRECTION(WS-N).
           MOVE HV-AMOUNT TO WS-EDIT.
           MOVE WS-EDIT TO SR-AMOUNT(WS-N).
           MOVE HV-POSTED-AT TO SR-POSTED-AT(WS-N).
           MOVE HV-DESC TO SR-DESCRIPTION(WS-N).
           MOVE WS-RUN TO WS-EDIT.
           MOVE WS-EDIT TO SR-BALANCE-AFTER(WS-N).
           IF HV-DIRECTION(1:1) = "C"
              SUBTRACT HV-AMOUNT FROM WS-RUN
           ELSE
              ADD HV-AMOUNT TO WS-RUN
           END-IF.
           MOVE WS-N TO SR-LINE-COUNT.
       LIST-FAILED.
           MOVE "REJECTED" TO SR-RESULT.
           MOVE "DBERR" TO SR-REASON.
           MOVE ZERO TO SR-LINE-COUNT.
      *> gixpp appends its cursor-init block after the last paragraph; this terminator gives it a
      *> home so a PERFORMed paragraph is never last (else the PERFORM never returns).
       Z-PROGRAM-END.
           EXIT.
