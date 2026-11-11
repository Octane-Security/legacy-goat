# cobol — core ledger, account master, customer

The system of record. Programs post double-entry debit/credit lines to the SQL ledger, read and
update the indexed account master, and read customer segments from the hierarchical store.

One program per core operation, each reading its request record on stdin and writing its reply on
stdout:

| Program | Operation | Records |
|---|---|---|
| `staffauth.cbl` | staff sign-on | `AUTH-*` in `../contracts/copybook/core-ops.cpy` |
| `postxfer.cbl` | funds transfer | `../contracts/copybook/transfer-io.cpy` |
| `cashpost.cbl` | cash deposit and withdrawal | `CASH-*` in `core-ops.cpy` |
| `acctinq.cbl` | account inquiry | `INQUIRY-*` in `core-ops.cpy` |
| `acctstmt.cbl` | account statement | `STATEMENT-*` in `core-ops.cpy` |
| `acctmnt.cbl` | account hold (freeze / unfreeze) | `MAINT-*` in `core-ops.cpy` |

- Each implements the matching `../contracts/rest/core.*.schema.json`.
- SQL ledger rows: `../contracts/copybook/ledger-posting.cpy` (EXEC SQL / GixSQL).
- Account master (VSAM/ISAM, keyed): `../contracts/copybook/account-master.cpy`.
- Customer segment (IMS DL/I, SSA-qualified): `../contracts/copybook/customer-segment.cpy`.
