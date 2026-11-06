       IDENTIFICATION DIVISION.
       PROGRAM-ID. ACCTINQ.
      *> Account inquiry. Reads INQUIRY-REQUEST (text) from stdin, reads the account from the VSAM
      *> master and its holder from the DL/I store, and writes INQUIRY-REPLY. Staff see accounts
      *> in their own branch only.
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
           COPY "core-ops.cpy".
           COPY "customer-segment.cpy".
      *> DL/I get-unique of the CUSTSEG root for the account's customer; PCB status at offset 10.
           01 DLI-FUNC-GU          PIC X(04) VALUE "GU  ".
           01 CUST-PCB.
              05 PCB-DBD-NAME      PIC X(08) VALUE "CUSTDB".
              05 PCB-SEG-LEVEL     PIC X(02) VALUE SPACES.
              05 PCB-STATUS        PIC X(02) VALUE SPACES.
              05 FILLER            PIC X(20) VALUE SPACES.
           01 CUST-SSA             PIC X(120).
           01 WS-ACCT-PATH         PIC X(80).
           01 WS-ACCT-ST           PIC X(02).
           01 WS-EDIT              PIC -(12)9.99.
       PROCEDURE DIVISION.
       MAIN-PARA.
           DISPLAY "ACCT_FILE" UPON ENVIRONMENT-NAME.
           ACCEPT WS-ACCT-PATH FROM ENVIRONMENT-VALUE.
           ACCEPT INQUIRY-REQUEST.
           MOVE SPACES TO INQUIRY-REPLY.
           MOVE IQ-ACCOUNT-ID TO IR-ACCOUNT-ID.
           MOVE "REJECTED" TO IR-RESULT.
           EVALUATE TRUE
              WHEN IQ-ACTOR-ROLE NOT = "TELLER"
                   AND IQ-ACTOR-ROLE NOT = "SUPERVISOR"
                 MOVE "ROLE NOT PERMITTED" TO IR-REASON
              WHEN IQ-ACCOUNT-ID IS NOT NUMERIC
                 MOVE "ACCOUNT NOT FOUND" TO IR-REASON
              WHEN OTHER
                 PERFORM READ-ACCOUNT
           END-EVALUATE.
           DISPLAY INQUIRY-REPLY.
           STOP RUN.
       READ-ACCOUNT.
           OPEN INPUT ACCT-FILE.
           IF WS-ACCT-ST NOT = "00"
              MOVE "ACCOUNT FILE UNAVAILABLE" TO IR-REASON
           ELSE
              MOVE IQ-ACCOUNT-ID TO AM-ACCOUNT-ID
              READ ACCT-FILE KEY IS AM-ACCOUNT-ID
                 INVALID KEY
                    MOVE "ACCOUNT NOT FOUND" TO IR-REASON
                 NOT INVALID KEY
                    PERFORM CHECK-BRANCH
              END-READ
              CLOSE ACCT-FILE
           END-IF.
       CHECK-BRANCH.
           IF AM-BRANCH NOT = IQ-ACTOR-BRANCH
              MOVE "OUT OF BRANCH SCOPE" TO IR-REASON
           ELSE
              PERFORM FILL-REPLY
           END-IF.
       FILL-REPLY.
           MOVE "OK" TO IR-RESULT.
           MOVE AM-CUSTOMER-ID TO IR-CUSTOMER-ID.
           MOVE AM-BRANCH TO IR-BRANCH.
           MOVE AM-ACCOUNT-TYPE TO IR-ACCOUNT-TYPE.
           MOVE AM-CURRENCY TO IR-CURRENCY.
           MOVE AM-STATUS TO IR-STATUS.
           MOVE AM-BALANCE TO WS-EDIT.
           MOVE WS-EDIT TO IR-BALANCE.
           MOVE AM-OPENED-AT TO IR-OPENED-AT.
           PERFORM READ-HOLDER.
       READ-HOLDER.
      *> Blank PCB status = found; a customer not on file leaves the name blank.
           IF AM-CUSTOMER-ID IS NUMERIC
              MOVE SPACES TO CUST-SSA
              STRING "CUSTSEG(CU-CUSTOMER-ID =" DELIMITED BY SIZE
                     AM-CUSTOMER-ID DELIMITED BY SIZE
                     ")" DELIMITED BY SIZE
                     INTO CUST-SSA
              END-STRING
              CALL "CBLTDLI" USING DLI-FUNC-GU, CUST-PCB,
                                   CUSTOMER-SEGMENT, CUST-SSA
              IF PCB-STATUS = SPACES
                 MOVE CU-NAME TO IR-CUSTOMER-NAME
              END-IF
           END-IF.
       Z-PROGRAM-END.
           EXIT.
