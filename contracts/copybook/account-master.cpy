      *> Account master record — VSAM/ISAM indexed file, primary key AM-ACCOUNT-ID.
      *> AM-BRANCH is the authorization scope (staff act within their branch).
      *> AM-STATUS is ACTIVE / FROZEN / CLOSED. Fixed length 68 bytes.
       01  ACCOUNT-MASTER-RECORD.
           05  AM-ACCOUNT-ID        PIC X(12).
           05  AM-CUSTOMER-ID       PIC X(10).
           05  AM-BRANCH            PIC X(04).
           05  AM-ACCOUNT-TYPE      PIC X(03).
           05  AM-CURRENCY          PIC X(03).
           05  AM-BALANCE           PIC S9(13)V99 COMP-3.
           05  AM-STATUS            PIC X(08).
           05  AM-OPENED-AT         PIC X(20).
