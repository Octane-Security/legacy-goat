       IDENTIFICATION DIVISION.
       PROGRAM-ID. ACCTMNT.
      *> Account maintenance. Reads MAINT-REQUEST (text) from stdin: a supervisor freezes an ACTIVE
      *> account or unfreezes a FROZEN one in their own branch. The change is logged to the SQL
      *> account_maintenance table, committed once the VSAM status is rewritten. Writes
      *> MAINT-REPLY.
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
           01 HV-ACTION            PIC X(08).
           01 HV-STAFF-ID          PIC X(10).
           01 HV-PERFORMED-AT      PIC X(20).
           EXEC SQL END DECLARE SECTION END-EXEC.
           EXEC SQL INCLUDE SQLCA END-EXEC.
           COPY "core-ops.cpy".
           01 WS-ACCT-PATH         PIC X(80).
           01 WS-ACCT-ST           PIC X(02).
           01 WS-OK                PIC X(01) VALUE "Y".
           01 WS-OLD-STATUS        PIC X(08).
           01 WS-NEW-STATUS        PIC X(08).
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
           ACCEPT MAINT-REQUEST.
           MOVE SPACES TO MAINT-REPLY.
           MOVE MQ-ACCOUNT-ID TO MR-ACCOUNT-ID.
           MOVE "REJECTED" TO MR-RESULT.
           PERFORM CHECK-REQUEST.
           IF WS-OK = "Y"
              PERFORM BUILD-TS
              EXEC SQL CONNECT TO :DATASRC USER :DBUSR END-EXEC
              IF SQLCODE NOT = 0
                 PERFORM REFUSE-DB
              ELSE
                 PERFORM MAINTAIN-ACCOUNT
                 IF WS-OK NOT = "Y"
                    EXEC SQL ROLLBACK END-EXEC
                 END-IF
                 EXEC SQL DISCONNECT ALL END-EXEC
              END-IF
           END-IF.
           DISPLAY MAINT-REPLY.
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
              WHEN MQ-ACTOR-ROLE NOT = "SUPERVISOR"
                 MOVE "SUPERVISOR ROLE REQUIRED" TO MR-REASON
              WHEN MQ-ACTION NOT = "FREEZE"
                   AND MQ-ACTION NOT = "UNFREEZE"
                 MOVE "UNKNOWN MAINTENANCE ACTION" TO MR-REASON
              WHEN MQ-ACCOUNT-ID IS NOT NUMERIC
                 MOVE "ACCOUNT NOT FOUND" TO MR-REASON
           END-EVALUATE.
           IF MR-REASON NOT = SPACES
              MOVE "N" TO WS-OK
           END-IF.
       BUILD-TS.
           MOVE FUNCTION CURRENT-DATE TO WS-CD.
           STRING WS-CD-YEAR "-" WS-CD-MONTH "-" WS-CD-DAY "T"
                  WS-CD-HH ":" WS-CD-MM ":" WS-CD-SS "Z"
                  DELIMITED BY SIZE INTO WS-TS
           END-STRING.
       MAINTAIN-ACCOUNT.
           OPEN I-O ACCT-FILE.
           IF WS-ACCT-ST NOT = "00"
              MOVE "N" TO WS-OK
              MOVE "ACCOUNT FILE UNAVAILABLE" TO MR-REASON
           ELSE
              PERFORM READ-ACCOUNT
              IF WS-OK = "Y"
                 PERFORM LOG-ACTION
              END-IF
              IF WS-OK = "Y"
                 PERFORM APPLY-STATUS
              END-IF
              CLOSE ACCT-FILE
           END-IF.
       READ-ACCOUNT.
           MOVE MQ-ACCOUNT-ID TO AM-ACCOUNT-ID.
           READ ACCT-FILE KEY IS AM-ACCOUNT-ID
              INVALID KEY
                 MOVE "N" TO WS-OK
                 MOVE "ACCOUNT NOT FOUND" TO MR-REASON
              NOT INVALID KEY
                 PERFORM CHECK-ACCOUNT
           END-READ.
       CHECK-ACCOUNT.
           MOVE AM-STATUS TO WS-OLD-STATUS.
           EVALUATE TRUE
              WHEN AM-BRANCH NOT = MQ-ACTOR-BRANCH
                 MOVE "OUT OF BRANCH SCOPE" TO MR-REASON
              WHEN MQ-ACTION = "FREEZE" AND AM-STATUS NOT = "ACTIVE"
                 MOVE "ACCOUNT NOT ACTIVE" TO MR-REASON
                 MOVE AM-STATUS TO MR-STATUS
              WHEN MQ-ACTION = "UNFREEZE" AND AM-STATUS NOT = "FROZEN"
                 MOVE "ACCOUNT NOT FROZEN" TO MR-REASON
                 MOVE AM-STATUS TO MR-STATUS
              WHEN MQ-ACTION = "FREEZE"
                 MOVE "FROZEN" TO WS-NEW-STATUS
              WHEN OTHER
                 MOVE "ACTIVE" TO WS-NEW-STATUS
           END-EVALUATE.
           IF MR-REASON NOT = SPACES
              MOVE "N" TO WS-OK
           END-IF.
       LOG-ACTION.
           MOVE MQ-ACCOUNT-ID TO HV-ACCOUNT-ID.
           MOVE MQ-ACTION TO HV-ACTION.
           MOVE MQ-ACTOR-STAFF TO HV-STAFF-ID.
           MOVE WS-TS TO HV-PERFORMED-AT.
           EXEC SQL
              INSERT INTO account_maintenance
                 (account_id, action, staff_id, performed_at)
              VALUES (RTRIM(:HV-ACCOUNT-ID), RTRIM(:HV-ACTION),
                 RTRIM(:HV-STAFF-ID), :HV-PERFORMED-AT)
           END-EXEC.
           IF SQLCODE NOT = 0
              PERFORM REFUSE-DB
           END-IF.
       APPLY-STATUS.
      *> The log commits only after the master is rewritten; a failed commit puts the old status
      *> back.
           MOVE WS-NEW-STATUS TO AM-STATUS.
           REWRITE ACCOUNT-MASTER-RECORD.
           IF WS-ACCT-ST NOT = "00"
              MOVE "N" TO WS-OK
              MOVE "ACCOUNT FILE UNAVAILABLE" TO MR-REASON
           ELSE
              EXEC SQL COMMIT END-EXEC
              IF SQLCODE NOT = 0
                 PERFORM RESTORE-STATUS
              ELSE
                 MOVE "OK" TO MR-RESULT
                 MOVE WS-NEW-STATUS TO MR-STATUS
              END-IF
           END-IF.
       RESTORE-STATUS.
           MOVE WS-OLD-STATUS TO AM-STATUS.
           REWRITE ACCOUNT-MASTER-RECORD.
           PERFORM REFUSE-DB.
       REFUSE-DB.
           MOVE "N" TO WS-OK.
           MOVE "DBERR" TO MR-REASON.
      *> gixpp appends its cursor-init block after the last paragraph; this terminator gives it a
      *> home so a PERFORMed paragraph is never last (else the PERFORM never returns).
       Z-PROGRAM-END.
           EXIT.
