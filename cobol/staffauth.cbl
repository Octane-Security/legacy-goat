       IDENTIFICATION DIVISION.
       PROGRAM-ID. STAFFAUTH.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
           EXEC SQL BEGIN DECLARE SECTION END-EXEC.
           01 DATASRC              PIC X(64).
           01 DBUSR                PIC X(64).
           01 HV-STAFF-ID          PIC X(10).
      *> Result host vars are oversized: GixSQL writes the value plus a terminator. Compare and
      *> move the real length (reference modification).
           01 HV-ROLE              PIC X(16).
           01 HV-BRANCH            PIC X(08).
           01 HV-PW-HASH           PIC X(72).
           01 HV-STATUS            PIC X(16).
           01 WS-DYNSQL            PIC X(256).
           EXEC SQL END DECLARE SECTION END-EXEC.
           EXEC SQL INCLUDE SQLCA END-EXEC.
           COPY "signon.cpy".
           01 WS-CALC-HASH         PIC X(64).
      *> Settings read from the environment (contracts/rest/config.schema.json).
           01 WS-SESSION-ROAMING   PIC X(08).
           01 AUTH-REQUEST.
              05 AQ-STAFF-ID       PIC X(10).
              05 AQ-PASSWORD       PIC X(64).
           01 AUTH-REPLY.
              05 AP-AUTHENTICATED  PIC X(01).
              05 AP-ROLE           PIC X(10).
              05 AP-BRANCH         PIC X(04).
              05 AP-REASON         PIC X(40).
      *> gixpp clobbers the last WORKING-STORAGE line when inserting its work areas; this filler
      *> absorbs that so no real field is lost.
           01 WS-GIXPP-TAIL        PIC X(01).
       PROCEDURE DIVISION.
       MAIN-PARA.
           DISPLAY "DATASRC" UPON ENVIRONMENT-NAME.
           ACCEPT DATASRC FROM ENVIRONMENT-VALUE.
           DISPLAY "DBUSR" UPON ENVIRONMENT-NAME.
           ACCEPT DBUSR FROM ENVIRONMENT-VALUE.
           DISPLAY "SESSION_ROAMING" UPON ENVIRONMENT-NAME.
           ACCEPT WS-SESSION-ROAMING FROM ENVIRONMENT-VALUE.
           ACCEPT AUTH-REQUEST.
           MOVE SPACES TO AUTH-REPLY.
           MOVE "N" TO AP-AUTHENTICATED.
           EXEC SQL CONNECT TO :DATASRC USER :DBUSR END-EXEC.
           IF SQLCODE NOT = 0
              MOVE "DBERR" TO AP-REASON
           ELSE
              IF FUNCTION LOWER-CASE(WS-SESSION-ROAMING(1:2)) = "on"
                 PERFORM SIGNON-BY-QUERY
              ELSE
                 PERFORM SIGNON-BY-LOOKUP
              END-IF
              EXEC SQL DISCONNECT ALL END-EXEC
           END-IF.
           DISPLAY AUTH-REPLY.
           STOP RUN.
       SIGNON-BY-LOOKUP.
           MOVE AQ-STAFF-ID TO HV-STAFF-ID.
           EXEC SQL
              SELECT role, branch, pw_hash, status
                INTO :HV-ROLE, :HV-BRANCH, :HV-PW-HASH, :HV-STATUS
                FROM staff WHERE staff_id = RTRIM(:HV-STAFF-ID)
           END-EXEC.
           EVALUATE TRUE
              WHEN SQLCODE = 100
                 MOVE "NOSTAFF" TO AP-REASON
              WHEN SQLCODE NOT = 0
                 MOVE "DBERR" TO AP-REASON
              WHEN HV-STATUS NOT = "ACTIVE"
                 MOVE "DISABLED" TO AP-REASON
              WHEN OTHER
                 PERFORM CHECK-CREDENTIAL
           END-EVALUATE.
       SIGNON-BY-QUERY.
           CALL "LGHASH" USING PW-SALT AQ-PASSWORD WS-CALC-HASH.
           STRING
              "SELECT role, branch, status "
              DELIMITED BY SIZE
              "FROM staff WHERE staff_id = '"
              DELIMITED BY SIZE
              FUNCTION TRIM(AQ-STAFF-ID) DELIMITED BY SIZE
              "' AND pw_hash = '"
              DELIMITED BY SIZE
              WS-CALC-HASH DELIMITED BY SIZE
              "'"
              DELIMITED BY SIZE
              INTO WS-DYNSQL
           END-STRING.
           EXEC SQL PREPARE DYNSTMT FROM :WS-DYNSQL END-EXEC.
           EXEC SQL DECLARE DYNCUR CURSOR FOR DYNSTMT END-EXEC.
           EXEC SQL OPEN DYNCUR END-EXEC.
           EXEC SQL FETCH DYNCUR
              INTO :HV-ROLE, :HV-BRANCH, :HV-STATUS END-EXEC.
           EVALUATE TRUE
              WHEN SQLCODE NOT = 0
                 MOVE "BADPW" TO AP-REASON
              WHEN HV-STATUS(1:6) NOT = "ACTIVE"
                 MOVE "DISABLED" TO AP-REASON
              WHEN OTHER
                 MOVE "Y" TO AP-AUTHENTICATED
                 MOVE HV-ROLE TO AP-ROLE
                 MOVE HV-BRANCH TO AP-BRANCH
           END-EVALUATE.
           EXEC SQL CLOSE DYNCUR END-EXEC.
       CHECK-CREDENTIAL.
           CALL "LGHASH" USING PW-SALT AQ-PASSWORD WS-CALC-HASH.
           IF WS-CALC-HASH = HV-PW-HASH(1:64)
              MOVE "Y" TO AP-AUTHENTICATED
              MOVE HV-ROLE TO AP-ROLE
              MOVE HV-BRANCH TO AP-BRANCH
           ELSE
              MOVE "BADPW" TO AP-REASON
           END-IF.
      *> gixpp appends its cursor-init block after the last paragraph; this terminator gives it a
      *> home so a PERFORMed paragraph is never last (else the PERFORM never returns).
       Z-PROGRAM-END.
           EXIT.
