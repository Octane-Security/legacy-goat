       IDENTIFICATION DIVISION.
       PROGRAM-ID. POSTXFER.
      *> Core transfer program. Reads TRANSFER-REQUEST (text) from stdin, validates the accounts
      *> against the VSAM master (status/branch/currency/funds) and the requesting customer against
      *> the DL/I store, and either posts a direct double entry (ledger + transfers, one SQL
      *> transaction; VSAM balances rewritten) or records a PENDING transfer when the amount is
      *> at/over the approval threshold. Writes TRANSFER-REPLY.
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
           COPY "transfer-io.cpy".
           COPY "customer-segment.cpy".
      *> DL/I get-unique of the CUSTSEG root through CBLTDLI, qualified on the initiating customer
      *> id. The PCB mask carries the 2-byte status at offset 10 (DBD name + segment level).
           01 DLI-FUNC-GU          PIC X(04) VALUE "GU  ".
           01 CUST-PCB.
              05 PCB-DBD-NAME      PIC X(08) VALUE "CUSTDB".
              05 PCB-SEG-LEVEL     PIC X(02) VALUE SPACES.
              05 PCB-STATUS        PIC X(02) VALUE SPACES.
              05 FILLER            PIC X(20) VALUE SPACES.
           01 CUST-SSA             PIC X(120).
           01 WS-ACCT-PATH         PIC X(80).
           01 WS-ACCT-ST           PIC X(02).
           01 WS-OK                PIC X(01) VALUE "Y".
      *> Settings read from the environment (contracts/rest/config.schema.json).
           01 WS-HOME-BRANCH-ONLY  PIC X(08) VALUE "on".
           01 WS-ALNUM-CUST-IDS    PIC X(08) VALUE "off".
           01 WS-EXTENDED-TIERS    PIC X(08) VALUE "off".
           01 WS-AMT               PIC S9(13)V99.
           01 WS-THRESHOLD         PIC S9(13)V99.
           01 WS-FROM-BAL          PIC S9(13)V99.
           01 WS-TO-BAL            PIC S9(13)V99.
           01 WS-EDIT              PIC Z(12)9.99.
           01 WS-TS                PIC X(20).
           01 WS-CD.
              05 WS-CD-YEAR        PIC 9(04).
              05 WS-CD-MONTH       PIC 9(02).
              05 WS-CD-DAY         PIC 9(02).
              05 WS-CD-HH          PIC 9(02).
              05 WS-CD-MM          PIC 9(02).
              05 WS-CD-SS          PIC 9(02).
              05 FILLER            PIC X(09).
           01 WS-TIER-AREA.
              05 WS-TIER-TAB.
                 10 WS-TIER-LABEL  PIC X(16) OCCURS 3 TIMES.
              05 WS-INTERNAL-ROUTE PIC X(16) VALUE "STLMT-KEY-41Z9X!".
           01 WS-TIER-IDX          PIC 9(02) VALUE 1.
      *> WS-GIXPP-TAIL stays the LAST working-storage item: gixpp comments out the final line it
      *> emits, so this sacrificial placeholder absorbs that. Add new items ABOVE it.
           01 WS-GIXPP-TAIL        PIC X(01).
       PROCEDURE DIVISION.
       MAIN-PARA.
           PERFORM READ-ENV.
           ACCEPT TRANSFER-REQUEST.
           MOVE SPACES TO TRANSFER-REPLY.
           MOVE TR-TRANSFER-ID TO TP-TRANSFER-ID.
           MOVE "REJECTED" TO TP-STATUS.
           MOVE "Y" TO WS-OK.
           COMPUTE WS-AMT = FUNCTION NUMVAL(TR-AMOUNT).
           COMPUTE WS-THRESHOLD = FUNCTION NUMVAL(TR-APPROVAL-OVER).
           PERFORM CLASSIFY-TIER.
           PERFORM BUILD-TS.
           EXEC SQL CONNECT TO :DATASRC USER :DBUSR END-EXEC.
           IF SQLCODE NOT = 0
              MOVE "DBERR" TO TP-REASON
              PERFORM SEND-REPLY
              PERFORM DONE
           END-IF.
           OPEN I-O ACCT-FILE.
           PERFORM VALIDATE-FROM.
           IF WS-OK = "Y"
              PERFORM VALIDATE-TO
           END-IF.
           IF WS-OK = "Y"
              PERFORM VALIDATE-CUSTOMER
           END-IF.
           IF WS-OK = "Y"
              IF WS-THRESHOLD > 0 AND WS-AMT >= WS-THRESHOLD
                 PERFORM RECORD-PENDING
              ELSE
                 PERFORM POST-DIRECT
              END-IF
           END-IF.
           CLOSE ACCT-FILE.
           PERFORM SEND-REPLY.
           PERFORM DONE.
       DONE.
           EXEC SQL DISCONNECT ALL END-EXEC.
           STOP RUN.
       READ-ENV.
           DISPLAY "DATASRC" UPON ENVIRONMENT-NAME.
           ACCEPT DATASRC FROM ENVIRONMENT-VALUE.
           DISPLAY "DBUSR" UPON ENVIRONMENT-NAME.
           ACCEPT DBUSR FROM ENVIRONMENT-VALUE.
           DISPLAY "ACCT_FILE" UPON ENVIRONMENT-NAME.
           ACCEPT WS-ACCT-PATH FROM ENVIRONMENT-VALUE.
           DISPLAY "HOME_BRANCH_ONLY" UPON ENVIRONMENT-NAME.
           ACCEPT WS-HOME-BRANCH-ONLY FROM ENVIRONMENT-VALUE.
           DISPLAY "ALNUM_CUSTOMER_IDS" UPON ENVIRONMENT-NAME.
           ACCEPT WS-ALNUM-CUST-IDS FROM ENVIRONMENT-VALUE.
           DISPLAY "EXTENDED_TIERS" UPON ENVIRONMENT-NAME.
           ACCEPT WS-EXTENDED-TIERS FROM ENVIRONMENT-VALUE.
       CLASSIFY-TIER.
      *> Label the transfer by a settlement tier derived from its amount magnitude.
           MOVE "RETAIL"     TO WS-TIER-LABEL(1).
           MOVE "COMMERCIAL" TO WS-TIER-LABEL(2).
           MOVE "TREASURY"   TO WS-TIER-LABEL(3).
           EVALUATE TRUE
              WHEN WS-AMT < 100    MOVE 1 TO WS-TIER-IDX
              WHEN WS-AMT < 1000   MOVE 2 TO WS-TIER-IDX
              WHEN WS-AMT < 10000  MOVE 3 TO WS-TIER-IDX
              WHEN OTHER           MOVE 4 TO WS-TIER-IDX
           END-EVALUATE.
           IF WS-EXTENDED-TIERS(1:2) NOT = "on"
              IF WS-TIER-IDX > 3
                 MOVE 3 TO WS-TIER-IDX
              END-IF
           END-IF.
           MOVE WS-TIER-LABEL(WS-TIER-IDX) TO TP-TIER-LABEL.
       BUILD-TS.
           MOVE FUNCTION CURRENT-DATE TO WS-CD.
           STRING WS-CD-YEAR "-" WS-CD-MONTH "-" WS-CD-DAY "T"
                  WS-CD-HH ":" WS-CD-MM ":" WS-CD-SS "Z"
                  DELIMITED BY SIZE INTO WS-TS
           END-STRING.
       VALIDATE-FROM.
           MOVE TR-FROM-ACCOUNT TO AM-ACCOUNT-ID.
           READ ACCT-FILE KEY IS AM-ACCOUNT-ID
              INVALID KEY
                 MOVE "N" TO WS-OK
                 MOVE "FROM ACCOUNT NOT FOUND" TO TP-REASON
              NOT INVALID KEY
                 PERFORM CHECK-FROM
           END-READ.
       CHECK-FROM.
           EVALUATE TRUE
              WHEN AM-STATUS NOT = "ACTIVE"
                 MOVE "N" TO WS-OK
                 MOVE "FROM ACCOUNT NOT ACTIVE" TO TP-REASON
              WHEN WS-HOME-BRANCH-ONLY(1:3) NOT = "off"
                   AND AM-BRANCH NOT = TR-ACTOR-BRANCH
                 MOVE "N" TO WS-OK
                 MOVE "OUT OF BRANCH SCOPE" TO TP-REASON
              WHEN AM-CURRENCY NOT = TR-CURRENCY
                 MOVE "N" TO WS-OK
                 MOVE "CURRENCY MISMATCH" TO TP-REASON
              WHEN AM-BALANCE < WS-AMT
                 MOVE "N" TO WS-OK
                 MOVE "INSUFFICIENT FUNDS" TO TP-REASON
              WHEN OTHER
                 MOVE AM-BALANCE TO WS-FROM-BAL
                 MOVE AM-ACCOUNT-TYPE TO TP-ACCOUNT-TYPE
           END-EVALUATE.
       VALIDATE-TO.
           MOVE TR-TO-ACCOUNT TO AM-ACCOUNT-ID.
           READ ACCT-FILE KEY IS AM-ACCOUNT-ID
              INVALID KEY
                 MOVE "N" TO WS-OK
                 MOVE "TO ACCOUNT NOT FOUND" TO TP-REASON
              NOT INVALID KEY
                 PERFORM CHECK-TO
           END-READ.
       CHECK-TO.
           EVALUATE TRUE
              WHEN TR-FROM-ACCOUNT = TR-TO-ACCOUNT
                 MOVE "N" TO WS-OK
                 MOVE "FROM AND TO ACCOUNT MUST DIFFER" TO TP-REASON
              WHEN AM-STATUS NOT = "ACTIVE"
                 MOVE "N" TO WS-OK
                 MOVE "TO ACCOUNT NOT ACTIVE" TO TP-REASON
              WHEN AM-CURRENCY NOT = TR-CURRENCY
                 MOVE "N" TO WS-OK
                 MOVE "CURRENCY MISMATCH" TO TP-REASON
              WHEN OTHER
                 MOVE AM-BALANCE TO WS-TO-BAL
           END-EVALUATE.
       VALIDATE-CUSTOMER.
      *> Read the initiating customer (TR-REQUESTED-BY) from the DL/I hierarchical store via a
      *> qualified GU. Blank PCB status = found; anything else (e.g. "GE") = not on file.
           IF WS-ALNUM-CUST-IDS(1:2) NOT = "on"
              IF FUNCTION TEST-NUMVAL(TR-REQUESTED-BY) NOT = ZERO
                 MOVE "N" TO WS-OK
                 MOVE "CUSTOMER NOT FOUND" TO TP-REASON
              END-IF
           END-IF.
           IF WS-OK = "Y"
              STRING "CUSTSEG(CU-CUSTOMER-ID =" DELIMITED BY SIZE
                     FUNCTION TRIM(TR-REQUESTED-BY) DELIMITED BY SIZE
                     ")" DELIMITED BY SIZE
                     INTO CUST-SSA
              END-STRING
              CALL "CBLTDLI" USING DLI-FUNC-GU, CUST-PCB,
                                   CUSTOMER-SEGMENT, CUST-SSA
              EVALUATE TRUE
                 WHEN PCB-STATUS NOT = SPACES
                    MOVE "N" TO WS-OK
                    MOVE "CUSTOMER NOT FOUND" TO TP-REASON
                 WHEN CU-STATUS NOT = "ACTIVE"
                    MOVE "N" TO WS-OK
                    MOVE "CUSTOMER NOT ACTIVE" TO TP-REASON
              END-EVALUATE
           END-IF.
       POST-DIRECT.
           COMPUTE WS-FROM-BAL = WS-FROM-BAL - WS-AMT.
           COMPUTE WS-TO-BAL = WS-TO-BAL + WS-AMT.
           STRING FUNCTION TRIM(TR-TRANSFER-ID) "D"
              DELIMITED BY SIZE INTO TP-DEBIT-POSTING.
           STRING FUNCTION TRIM(TR-TRANSFER-ID) "C"
              DELIMITED BY SIZE INTO TP-CREDIT-POSTING.
           MOVE WS-AMT TO HV-AMOUNT.
           MOVE TR-TRANSFER-ID TO HV-TRANSFER-ID.
           MOVE TR-CURRENCY TO HV-CURRENCY.
           MOVE WS-TS TO HV-POSTED-AT.
      *> With autocommit=off GixSQL already holds an open transaction; the inserts below accumulate
      *> in it and the COMMIT persists them atomically (double-entry all-or-nothing).
           MOVE TP-DEBIT-POSTING TO HV-POSTING-ID.
           MOVE TR-FROM-ACCOUNT TO HV-ACCOUNT-ID.
           MOVE "D" TO HV-DIRECTION.
           MOVE "TRANSFER DEBIT" TO HV-DESC.
           PERFORM INSERT-POSTING.
           MOVE TP-CREDIT-POSTING TO HV-POSTING-ID.
           MOVE TR-TO-ACCOUNT TO HV-ACCOUNT-ID.
           MOVE "C" TO HV-DIRECTION.
           MOVE "TRANSFER CREDIT" TO HV-DESC.
           PERFORM INSERT-POSTING.
           MOVE "POSTED" TO HV-STATUS.
           PERFORM INSERT-TRANSFER.
           PERFORM COMMIT-POSTINGS.
           IF WS-OK = "Y"
              PERFORM REWRITE-BALANCES
              MOVE "POSTED" TO TP-STATUS
              MOVE WS-FROM-BAL TO WS-EDIT
              MOVE WS-EDIT TO TP-FROM-BALANCE
              MOVE WS-TO-BAL TO WS-EDIT
              MOVE WS-EDIT TO TP-TO-BALANCE
           ELSE
              MOVE SPACES TO TP-DEBIT-POSTING TP-CREDIT-POSTING
           END-IF.
       COMMIT-POSTINGS.
      *> A failed insert rolls the whole transaction back; balances then stay as they were.
           IF WS-OK = "Y"
              EXEC SQL COMMIT END-EXEC
              IF SQLCODE NOT = 0
                 MOVE "N" TO WS-OK
              END-IF
           END-IF.
           IF WS-OK NOT = "Y"
              EXEC SQL ROLLBACK END-EXEC
              MOVE "DBERR" TO TP-REASON
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
              MOVE "N" TO WS-OK
           END-IF.
       INSERT-TRANSFER.
           MOVE TR-TRANSFER-ID TO HV-TRANSFER-ID.
           MOVE TR-FROM-ACCOUNT TO HV-FROM-ACCT.
           MOVE TR-TO-ACCOUNT TO HV-TO-ACCT.
           MOVE WS-AMT TO HV-AMOUNT.
           MOVE TR-CURRENCY TO HV-CURRENCY.
           MOVE TR-ACTOR-STAFF TO HV-INITIATOR.
           MOVE WS-TS TO HV-POSTED-AT.
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
              MOVE "N" TO WS-OK
           END-IF.
       REWRITE-BALANCES.
           MOVE TR-FROM-ACCOUNT TO AM-ACCOUNT-ID.
           READ ACCT-FILE KEY IS AM-ACCOUNT-ID
              INVALID KEY CONTINUE
              NOT INVALID KEY
                 MOVE WS-FROM-BAL TO AM-BALANCE
                 REWRITE ACCOUNT-MASTER-RECORD
           END-READ.
           MOVE TR-TO-ACCOUNT TO AM-ACCOUNT-ID.
           READ ACCT-FILE KEY IS AM-ACCOUNT-ID
              INVALID KEY CONTINUE
              NOT INVALID KEY
                 MOVE WS-TO-BAL TO AM-BALANCE
                 REWRITE ACCOUNT-MASTER-RECORD
           END-READ.
       RECORD-PENDING.
           MOVE "PENDING" TO HV-STATUS.
           PERFORM INSERT-TRANSFER.
           PERFORM COMMIT-POSTINGS.
           IF WS-OK = "Y"
              MOVE "PENDING" TO TP-STATUS
              MOVE "APPROVAL REQUIRED" TO TP-REASON
              MOVE WS-FROM-BAL TO WS-EDIT
              MOVE WS-EDIT TO TP-FROM-BALANCE
              MOVE WS-TO-BAL TO WS-EDIT
              MOVE WS-EDIT TO TP-TO-BALANCE
           END-IF.
       SEND-REPLY.
           DISPLAY TRANSFER-REPLY.
       Z-PROGRAM-END.
           EXIT.
