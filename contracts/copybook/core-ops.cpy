      *> Native stdin/stdout records for the smaller core ops, each its own COBOL program fronted by the
      *> COBOL adapter. XX-ACTOR-* is the resolved acting staff (COBOL enforces role/branch/maker-checker).
      *> These cross via ACCEPT/DISPLAY, so money is the 16-column TEXT form (not COMP-3).
      *> Status/reason mirror the matching rest/*.schema.json.

      *> staff.authenticate — verify credential against STAFF.pw-hash; AP-AUTHENTICATED is Y/N.
       01  AUTH-REQUEST.
           05  AQ-STAFF-ID          PIC X(10).
           05  AQ-PASSWORD          PIC X(64).
       01  AUTH-REPLY.
           05  AP-AUTHENTICATED     PIC X(01).
           05  AP-ROLE              PIC X(10).
           05  AP-BRANCH            PIC X(04).
           05  AP-REASON            PIC X(40).

      *> transfer.approve — SUPERVISOR, approver != initiator (maker-checker).
       01  APPROVE-REQUEST.
           05  PV-TRANSFER-ID       PIC X(20).
           05  PV-ACTOR-STAFF       PIC X(10).
           05  PV-ACTOR-ROLE        PIC X(10).
           05  PV-ACTOR-BRANCH      PIC X(04).
       01  APPROVE-REPLY.
           05  PR-TRANSFER-ID       PIC X(20).
           05  PR-STATUS            PIC X(10).
           05  PR-REASON            PIC X(40).
           05  PR-DEBIT-POSTING     PIC X(20).
           05  PR-CREDIT-POSTING    PIC X(20).
           05  PR-FROM-BALANCE      PIC X(16).
           05  PR-TO-BALANCE        PIC X(16).

      *> transfer.reverse — SUPERVISOR; compensating postings.
       01  REVERSE-REQUEST.
           05  RV-TRANSFER-ID       PIC X(20).
           05  RV-ACTOR-STAFF       PIC X(10).
           05  RV-ACTOR-ROLE        PIC X(10).
           05  RV-ACTOR-BRANCH      PIC X(04).
       01  REVERSE-REPLY.
           05  RR-TRANSFER-ID       PIC X(20).
           05  RR-STATUS            PIC X(10).
           05  RR-REASON            PIC X(40).
           05  RR-REVERSAL-DEBIT    PIC X(20).
           05  RR-REVERSAL-CREDIT   PIC X(20).

      *> account maintenance — SUPERVISOR, own branch; MQ-ACTION is FREEZE / UNFREEZE.
      *> MR-RESULT is OK / REJECTED; MR-STATUS is the account status after the request.
       01  MAINT-REQUEST.
           05  MQ-ACCOUNT-ID        PIC X(12).
           05  MQ-ACTION            PIC X(08).
           05  MQ-ACTOR-STAFF       PIC X(10).
           05  MQ-ACTOR-ROLE        PIC X(10).
           05  MQ-ACTOR-BRANCH      PIC X(04).
       01  MAINT-REPLY.
           05  MR-ACCOUNT-ID        PIC X(12).
           05  MR-RESULT            PIC X(08).
           05  MR-STATUS            PIC X(08).
           05  MR-REASON            PIC X(40).

      *> account.inquiry — TELLER or SUPERVISOR, own branch. IR-RESULT is OK / REJECTED.
       01  INQUIRY-REQUEST.
           05  IQ-ACCOUNT-ID        PIC X(12).
           05  IQ-ACTOR-STAFF       PIC X(10).
           05  IQ-ACTOR-ROLE        PIC X(10).
           05  IQ-ACTOR-BRANCH      PIC X(04).
       01  INQUIRY-REPLY.
           05  IR-ACCOUNT-ID        PIC X(12).
           05  IR-RESULT            PIC X(08).
           05  IR-REASON            PIC X(40).
           05  IR-CUSTOMER-ID       PIC X(10).
           05  IR-CUSTOMER-NAME     PIC X(40).
           05  IR-BRANCH            PIC X(04).
           05  IR-ACCOUNT-TYPE      PIC X(03).
           05  IR-CURRENCY          PIC X(03).
           05  IR-STATUS            PIC X(08).
           05  IR-BALANCE           PIC X(16).
           05  IR-OPENED-AT         PIC X(20).

      *> account.statement — TELLER or SUPERVISOR, own branch. Up to ten ledger lines, newest
      *> first; SR-BALANCE-AFTER is the account balance once that line had posted.
       01  STATEMENT-REQUEST.
           05  SQ-ACCOUNT-ID        PIC X(12).
           05  SQ-ACTOR-STAFF       PIC X(10).
           05  SQ-ACTOR-ROLE        PIC X(10).
           05  SQ-ACTOR-BRANCH      PIC X(04).
       01  STATEMENT-REPLY.
           05  SR-ACCOUNT-ID        PIC X(12).
           05  SR-RESULT            PIC X(08).
           05  SR-REASON            PIC X(40).
           05  SR-CURRENCY          PIC X(03).
           05  SR-BALANCE           PIC X(16).
           05  SR-LINE-COUNT        PIC 9(02).
           05  SR-LINE              OCCURS 10 TIMES.
               10  SR-POSTING-ID    PIC X(20).
               10  SR-TRANSFER-ID   PIC X(20).
               10  SR-DIRECTION     PIC X(01).
               10  SR-AMOUNT        PIC X(16).
               10  SR-POSTED-AT     PIC X(20).
               10  SR-DESCRIPTION   PIC X(40).
               10  SR-BALANCE-AFTER PIC X(16).

      *> cash.post — TELLER or SUPERVISOR, own branch; CQ-ACTION is DEPOSIT / WITHDRAW. Posts
      *> against the branch cash account; CP-STATUS is POSTED / REJECTED.
       01  CASH-REQUEST.
           05  CQ-TRANSFER-ID       PIC X(20).
           05  CQ-ACCOUNT-ID        PIC X(12).
           05  CQ-ACTION            PIC X(08).
           05  CQ-AMOUNT            PIC X(16).
           05  CQ-CURRENCY          PIC X(03).
           05  CQ-ACTOR-STAFF       PIC X(10).
           05  CQ-ACTOR-ROLE        PIC X(10).
           05  CQ-ACTOR-BRANCH      PIC X(04).
       01  CASH-REPLY.
           05  CP-TRANSFER-ID       PIC X(20).
           05  CP-STATUS            PIC X(08).
           05  CP-REASON            PIC X(40).
           05  CP-ACCOUNT-POSTING   PIC X(20).
           05  CP-CASH-POSTING      PIC X(20).
           05  CP-CASH-ACCOUNT      PIC X(12).
           05  CP-BALANCE           PIC X(16).
