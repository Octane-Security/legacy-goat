      *> Interchange records for the core transfer program: the adapter writes TRANSFER-REQUEST to
      *> the module's stdin (163 bytes) and reads TRANSFER-REPLY from stdout (159 bytes). These cross
      *> via ACCEPT/DISPLAY, so they are line-based TEXT: money is the 16-column text form (right-
      *> justified, 2 decimals) from data-model.md, NOT COMP-3 (COMP-3 is only for the storage
      *> copybooks). TR-ACTOR-* is the initiating staff (authz); at/over TR-APPROVAL-OVER the core
      *> returns TP-STATUS = PENDING.
       01  TRANSFER-REQUEST.
           05  TR-TRANSFER-ID       PIC X(20).
           05  TR-FROM-ACCOUNT      PIC X(12).
           05  TR-TO-ACCOUNT        PIC X(12).
           05  TR-AMOUNT            PIC X(16).
           05  TR-CURRENCY          PIC X(03).
           05  TR-REQUESTED-BY      PIC X(40).
           05  TR-REQUESTED-AT      PIC X(20).
           05  TR-ACTOR-STAFF       PIC X(10).
           05  TR-ACTOR-ROLE        PIC X(10).
           05  TR-ACTOR-BRANCH      PIC X(04).
           05  TR-APPROVAL-OVER     PIC X(16).

       01  TRANSFER-REPLY.
           05  TP-TRANSFER-ID       PIC X(20).
           05  TP-STATUS            PIC X(08).
           05  TP-REASON            PIC X(40).
           05  TP-DEBIT-POSTING     PIC X(20).
           05  TP-CREDIT-POSTING    PIC X(20).
           05  TP-FROM-BALANCE      PIC X(16).
           05  TP-TO-BALANCE        PIC X(16).
           05  TP-ACCOUNT-TYPE      PIC X(03).
           05  TP-TIER-LABEL        PIC X(16).
