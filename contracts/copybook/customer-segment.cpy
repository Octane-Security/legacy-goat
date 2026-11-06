      *> Customer root segment CUSTSEG — IMS DL/I hierarchical store.
      *> Retrieved by SSA qualified on CU-CUSTOMER-ID; fixed length 79 bytes.
       01  CUSTOMER-SEGMENT.
           05  CU-CUSTOMER-ID       PIC X(10).
           05  CU-NAME              PIC X(40).
           05  CU-STATUS            PIC X(08).
           05  CU-RISK-RATING       PIC X(01).
           05  CU-OPENED-AT         PIC X(20).
