       IDENTIFICATION DIVISION.
       PROGRAM-ID. CASHPOST.
      *> Teller cash. Reads CASH-REQUEST (text) from stdin and posts a cash deposit or withdrawal
      *> as a double entry between the account and its branch cash account (99000000 + branch):
      *> two ledger lines and a transfers row in one SQL transaction, committed once the VSAM
      *> balance is rewritten. Writes CASH-REPLY.
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
           01 HV-POSTING-ID        PIC X(20).
           01 HV-TRANSFER-ID       PIC X(20).
           01 HV-ACCOUNT-ID        PIC X(12).
           01 HV-DIRECTION         PIC X(01).
           01 HV-AMOUNT            PIC S9(13)V99 COMP-3.
           01 HV-CURRENCY          PIC X(03).
           01 HV-POSTED-AT         PIC X(20).
           01 HV-DESC              PIC X(40).
           01 HV-FROM-ACCT         PIC X(12).
           01 HV-TO-ACCT           PIC X(12).
           01 HV-STATUS            PIC X(10).
           01 HV-INITIATOR         PIC X(10).
           EXEC SQL END DECLARE SECTION END-EXEC.
           EXEC SQL INCLUDE SQLCA END-EXEC.
           COPY "core-ops.cpy".
           01 WS-ACCT-PATH         PIC X(80).
           01 WS-ACCT-ST           PIC X(02).
           01 WS-OK                PIC X(01) VALUE "Y".
      *> Over-the-counter cash limit, per transaction.
           01 WS-CASH-LIMIT        PIC S9(13)V99 VALUE 10000.00.
           01 WS-AMT               PIC S9(13)V99.
           01 WS-OLD-BAL           PIC S9(13)V99.
           01 WS-NEW-BAL           PIC S9(13)V99.
           01 WS-CASH-ACCT         PIC X(12).
           01 WS-DEBIT-ID          PIC X(20).
           01 WS-CREDIT-ID         PIC X(20).
           01 WS-EDIT              PIC -(12)9.99.
           01 WS-TS                PIC X(20).
           01 WS-CD.
              05 WS-CD-YEAR        PIC 9(04).
              05 WS-CD-MONTH       PIC 9(02).
              05 WS-CD-DAY         PIC 9(02).
              05 WS-CD-HH          PIC 9(02).
              05 WS-CD-MM          PIC 9(02).
              05 WS-CD-SS          PIC 9(02).
              05 FILLER            PIC X(09).
      *> WS-GIXPP-TAIL stays the LAST working-storage item: gixpp comments out the final line it
      *> emits, so this sacrificial placeholder absorbs that. Add new items ABOVE it.
           01 WS-GIXPP-TAIL        PIC X(01).
       PROCEDURE DIVISION.
       MAIN-PARA.
           PERFORM READ-ENV.
           ACCEPT CASH-REQUEST.
           MOVE SPACES TO CASH-REPLY.
           MOVE CQ-TRANSFER-ID TO CP-TRANSFER-ID.
           MOVE "REJECTED" TO CP-STATUS.
           PERFORM CHECK-REQUEST.
           IF WS-OK = "Y"
              PERFORM BUILD-TS
              EXEC SQL CONNECT TO :DATASRC USER :DBUSR END-EXEC
              IF SQLCODE NOT = 0
                 PERFORM REFUSE-DB
              ELSE
                 PERFORM POST-CASH
                 IF WS-OK NOT = "Y"
                    EXEC SQL ROLLBACK END-EXEC
                 END-IF
                 EXEC SQL DISCONNECT ALL END-EXEC
              END-IF
           END-IF.
           DISPLAY CASH-REPLY.
           STOP RUN.
       READ-ENV.
           DISPLAY "DATASRC" UPON ENVIRONMENT-NAME.
           ACCEPT DATASRC FROM ENVIRONMENT-VALUE.
           DISPLAY "DBUSR" UPON ENVIRONMENT-NAME.
           ACCEPT DBUSR FROM ENVIRONMENT-VALUE.
           DISPLAY "ACCT_FILE" UPON ENVIRONMENT-NAME.
           ACCEPT WS-ACCT-PATH FROM ENVIRONMENT-VALUE.
       CHECK-REQUEST.
           EVALUATE TRUE
              WHEN CQ-ACTOR-ROLE NOT = "TELLER"
                   AND CQ-ACTOR-ROLE NOT = "SUPERVISOR"
                 MOVE "ROLE NOT PERMITTED" TO CP-REASON
              WHEN CQ-ACTION NOT = "DEPOSIT"
                   AND CQ-ACTION NOT = "WITHDRAW"
                 MOVE "UNKNOWN CASH ACTION" TO CP-REASON
              WHEN CQ-ACCOUNT-ID IS NOT NUMERIC
                 MOVE "ACCOUNT NOT FOUND" TO CP-REASON
              WHEN CQ-TRANSFER-ID(1:1) = SPACE
                   OR CQ-TRANSFER-ID(20:1) NOT = SPACE
                 MOVE "INVALID TRANSFER ID" TO CP-REASON
              WHEN FUNCTION TEST-NUMVAL(CQ-AMOUNT) NOT = ZERO
                 MOVE "INVALID AMOUNT" TO CP-REASON
              WHEN OTHER
                 PERFORM CHECK-AMOUNT
           END-EVALUATE.
           IF CP-REASON NOT = SPACES
              MOVE "N" TO WS-OK
           END-IF.
       CHECK-AMOUNT.
           COMPUTE WS-AMT = FUNCTION NUMVAL(CQ-AMOUNT).
           EVALUATE TRUE
              WHEN WS-AMT NOT > ZERO
                 MOVE "AMOUNT MUST BE POSITIVE" TO CP-REASON
              WHEN WS-AMT NOT < WS-CASH-LIMIT
                 MOVE "OVER TELLER CASH LIMIT" TO CP-REASON
           END-EVALUATE.
       BUILD-TS.
           MOVE FUNCTION CURRENT-DATE TO WS-CD.
           STRING WS-CD-YEAR "-" WS-CD-MONTH "-" WS-CD-DAY "T"
                  WS-CD-HH ":" WS-CD-MM ":" WS-CD-SS "Z"
                  DELIMITED BY SIZE INTO WS-TS
           END-STRING.
       POST-CASH.
           OPEN I-O ACCT-FILE.
           IF WS-ACCT-ST NOT = "00"
              MOVE "N" TO WS-OK
              MOVE "ACCOUNT FILE UNAVAILABLE" TO CP-REASON
           ELSE
              PERFORM READ-ACCOUNT
              IF WS-OK = "Y"
                 PERFORM WRITE-POSTINGS
              END-IF
              IF WS-OK = "Y"
                 PERFORM APPLY-BALANCE
              END-IF
              CLOSE ACCT-FILE
           END-IF.
       READ-ACCOUNT.
           MOVE CQ-ACCOUNT-ID TO AM-ACCOUNT-ID.
           READ ACCT-FILE KEY IS AM-ACCOUNT-ID
              INVALID KEY
                 MOVE "N" TO WS-OK
                 MOVE "ACCOUNT NOT FOUND" TO CP-REASON
              NOT INVALID KEY
                 PERFORM CHECK-ACCOUNT
           END-READ.
       CHECK-ACCOUNT.
           EVALUATE TRUE
              WHEN AM-BRANCH NOT = CQ-ACTOR-BRANCH
                 MOVE "OUT OF BRANCH SCOPE" TO CP-REASON
              WHEN AM-STATUS NOT = "ACTIVE"
                 MOVE "ACCOUNT NOT ACTIVE" TO CP-REASON
              WHEN AM-CURRENCY NOT = CQ-CURRENCY
                 MOVE "CURRENCY MISMATCH" TO CP-REASON
              WHEN CQ-ACTION = "WITHDRAW" AND AM-BALANCE < WS-AMT
                 MOVE "INSUFFICIENT FUNDS" TO CP-REASON
              WHEN OTHER
                 PERFORM NEW-BALANCE
           END-EVALUATE.
           IF CP-REASON NOT = SPACES
              MOVE "N" TO WS-OK
           END-IF.
       NEW-BALANCE.
           MOVE AM-BALANCE TO WS-OLD-BAL.
           IF CQ-ACTION = "DEPOSIT"
              COMPUTE WS-NEW-BAL = WS-OLD-BAL + WS-AMT
                 ON SIZE ERROR
                    MOVE "BALANCE LIMIT EXCEEDED" TO CP-REASON
              END-COMPUTE
           ELSE
              COMPUTE WS-NEW-BAL = WS-OLD-BAL - WS-AMT
           END-IF.
       WRITE-POSTINGS.
      *> A deposit debits the branch cash account; a withdrawal credits it.
           MOVE SPACES TO WS-CASH-ACCT WS-DEBIT-ID WS-CREDIT-ID.
           STRING "99000000" AM-BRANCH
              DELIMITED BY SIZE INTO WS-CASH-ACCT.
           STRING FUNCTION TRIM(CQ-TRANSFER-ID) "D"
              DELIMITED BY SIZE INTO WS-DEBIT-ID.
           STRING FUNCTION TRIM(CQ-TRANSFER-ID) "C"
              DELIMITED BY SIZE INTO WS-CREDIT-ID.
           IF CQ-ACTION = "DEPOSIT"
              MOVE WS-CASH-ACCT TO HV-FROM-ACCT
              MOVE CQ-ACCOUNT-ID TO HV-TO-ACCT
              MOVE "CASH DEPOSIT" TO HV-DESC
           ELSE
              MOVE CQ-ACCOUNT-ID TO HV-FROM-ACCT
              MOVE WS-CASH-ACCT TO HV-TO-ACCT
              MOVE "CASH WITHDRAWAL" TO HV-DESC
           END-IF.
           MOVE WS-AMT TO HV-AMOUNT.
           MOVE CQ-TRANSFER-ID TO HV-TRANSFER-ID.
           MOVE CQ-CURRENCY TO HV-CURRENCY.
           MOVE WS-TS TO HV-POSTED-AT.
           MOVE WS-DEBIT-ID TO HV-POSTING-ID.
           MOVE HV-FROM-ACCT TO HV-ACCOUNT-ID.
           MOVE "D" TO HV-DIRECTION.
           PERFORM INSERT-POSTING.
           IF WS-OK = "Y"
              MOVE WS-CREDIT-ID TO HV-POSTING-ID
              MOVE HV-TO-ACCT TO HV-ACCOUNT-ID
              MOVE "C" TO HV-DIRECTION
              PERFORM INSERT-POSTING
           END-IF.
           IF WS-OK = "Y"
              PERFORM INSERT-TRANSFER
           END-IF.
       INSERT-POSTING.
           EXEC SQL
              INSERT INTO ledger
                 (posting_id, transfer_id, account_id, direction,
                  amount, currency, posted_at, description)
              VALUES
                 (RTRIM(:HV-POSTING-ID), RTRIM(:HV-TRANSFER-ID),
                  RTRIM(:HV-ACCOUNT-ID), :HV-DIRECTION, :HV-AMOUNT,
                  RTRIM(:HV-CURRENCY), :HV-POSTED-AT, RTRIM(:HV-DESC))
           END-EXEC.
           IF SQLCODE NOT = 0
              PERFORM REFUSE-DB
           END-IF.
       INSERT-TRANSFER.
           MOVE "POSTED" TO HV-STATUS.
           MOVE CQ-ACTOR-STAFF TO HV-INITIATOR.
           EXEC SQL
              INSERT INTO transfers
                 (transfer_id, from_account, to_account, amount,
                  currency, status, initiator, created_at)
              VALUES (RTRIM(:HV-TRANSFER-ID),
                 RTRIM(:HV-FROM-ACCT), RTRIM(:HV-TO-ACCT),
                 :HV-AMOUNT, RTRIM(:HV-CURRENCY),
                 RTRIM(:HV-STATUS), RTRIM(:HV-INITIATOR),
                 :HV-POSTED-AT)
           END-EXEC.
           IF SQLCODE NOT = 0
              PERFORM REFUSE-DB
           END-IF.
       APPLY-BALANCE.
      *> The ledger commits only after the master is rewritten; a failed commit puts the old
      *> balance back.
           MOVE WS-NEW-BAL TO AM-BALANCE.
           REWRITE ACCOUNT-MASTER-RECORD.
           IF WS-ACCT-ST NOT = "00"
              MOVE "N" TO WS-OK
              MOVE "ACCOUNT FILE UNAVAILABLE" TO CP-REASON
           ELSE
              EXEC SQL COMMIT END-EXEC
              IF SQLCODE NOT = 0
                 PERFORM RESTORE-BALANCE
              ELSE
                 PERFORM REPORT-POSTED
              END-IF
           END-IF.
       RESTORE-BALANCE.
           MOVE WS-OLD-BAL TO AM-BALANCE.
           REWRITE ACCOUNT-MASTER-RECORD.
           PERFORM REFUSE-DB.
       REPORT-POSTED.
           MOVE "POSTED" TO CP-STATUS.
           MOVE WS-CASH-ACCT TO CP-CASH-ACCOUNT.
           MOVE WS-NEW-BAL TO WS-EDIT.
           MOVE WS-EDIT TO CP-BALANCE.
           IF CQ-ACTION = "DEPOSIT"
              MOVE WS-CREDIT-ID TO CP-ACCOUNT-POSTING
              MOVE WS-DEBIT-ID TO CP-CASH-POSTING
           ELSE
              MOVE WS-DEBIT-ID TO CP-ACCOUNT-POSTING
              MOVE WS-CREDIT-ID TO CP-CASH-POSTING
           END-IF.
       REFUSE-DB.
           MOVE "N" TO WS-OK.
           MOVE "DBERR" TO CP-REASON.
      *> gixpp appends its cursor-init block after the last paragraph; this terminator gives it a
      *> home so a PERFORMed paragraph is never last (else the PERFORM never returns).
       Z-PROGRAM-END.
           EXIT.
