      *> Ledger posting row — SQL table LEDGER, one row per debit/credit line.
      *> Host-variable area for EXEC SQL; fixed length 124 bytes.
       01  LEDGER-POSTING-RECORD.
           05  LP-POSTING-ID        PIC X(20).
           05  LP-TRANSFER-ID       PIC X(20).
           05  LP-ACCOUNT-ID        PIC X(12).
           05  LP-DIRECTION         PIC X(01).
           05  LP-AMOUNT            PIC S9(13)V99 COMP-3.
           05  LP-CURRENCY          PIC X(03).
           05  LP-POSTED-AT         PIC X(20).
           05  LP-DESCRIPTION       PIC X(40).
