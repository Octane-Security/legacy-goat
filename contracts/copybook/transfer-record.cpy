      *> Transfer-level lifecycle record — SQL table TRANSFERS, keyed by TX-TRANSFER-ID. Distinct from
      *> the per-line LEDGER (ledger-posting.cpy): this tracks a transfer's state and the maker/checker
      *> identities across the approval flow. TX-STATUS is PENDING / POSTED / REVERSED / REJECTED.
      *> TX-INITIATOR mints it; TX-APPROVER decides a PENDING one (must differ from TX-INITIATOR).
      *> Fixed length 125 bytes.
       01  TRANSFER-RECORD.
           05  TX-TRANSFER-ID       PIC X(20).
           05  TX-FROM-ACCOUNT      PIC X(12).
           05  TX-TO-ACCOUNT        PIC X(12).
           05  TX-AMOUNT            PIC S9(13)V99 COMP-3.
           05  TX-CURRENCY          PIC X(03).
           05  TX-STATUS            PIC X(10).
           05  TX-INITIATOR         PIC X(10).
           05  TX-APPROVER          PIC X(10).
           05  TX-CREATED-AT        PIC X(20).
           05  TX-DECIDED-AT        PIC X(20).
