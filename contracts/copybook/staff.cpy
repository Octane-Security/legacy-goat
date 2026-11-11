      *> Staff record — the console's principals, keyed by ST-STAFF-ID. Held in the SQL store; the
      *> COBOL core reads it to authenticate (ST-PW-HASH) and to resolve role + branch for
      *> authorization. ST-ROLE is TELLER / SUPERVISOR; ST-STATUS is ACTIVE / DISABLED.
      *> Fixed length 136 bytes.
       01  STAFF-RECORD.
           05  ST-STAFF-ID          PIC X(10).
           05  ST-NAME              PIC X(40).
           05  ST-ROLE              PIC X(10).
           05  ST-BRANCH            PIC X(04).
           05  ST-PW-HASH           PIC X(64).
           05  ST-STATUS            PIC X(08).
