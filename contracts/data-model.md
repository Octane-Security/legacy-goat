# Data model — canonical field dictionary

One definition per field, expressed once here and mirrored into every representation
(JSON over REST, COBOL copybooks, Fortran/SAS fixed records). When a field appears in
more than one place, this file is what they must agree with.

## Domain

A small core-banking / payments system. These entities take part in a transfer:

- **Customer** — demographic record, held hierarchically (IMS DL/I).
- **Account** — account master, keyed and held as an indexed file (VSAM/ISAM).
- **Staff** — the console's principals, with a role and a home branch (SQL).
- **Session** — a signed-on staff member's console session (Pascal).
- **Ledger posting** — one debit or credit line, held relationally (SQL ledger).
- **Transfer** — a request to move funds between two accounts; produces two postings.
- **GL document** — the transfer's reflection in the ERP general ledger (ABAP).
- **Branch cash account** — the general-ledger account a branch's teller cash posts against.
- **Account maintenance** — one freeze or unfreeze of an account, logged (SQL).

## Canonical field types

| Type | JSON | COBOL PIC | Fixed-text width | Meaning |
|---|---|---|---|---|
| AccountId | string, `^[0-9]{12}$` | `PIC X(12)` | 12 | zero-padded numeric account number |
| CustomerId | string, `^[0-9]{10}$` | `PIC X(10)` | 10 | zero-padded numeric customer number |
| TransferId | string, `^[A-Z0-9]{1,20}$` | `PIC X(20)` | 20 | left-justified, space-padded |
| PostingId | string, `^[A-Z0-9]{1,20}$` | `PIC X(20)` | 20 | left-justified, space-padded |
| GlDocId | string, `^[A-Z0-9]{1,20}$` | `PIC X(20)` | 20 | left-justified, space-padded |
| Money | string, `^-?[0-9]{1,13}\.[0-9]{2}$` | `PIC S9(13)V99 COMP-3` | 16 | signed, 13 integer + 2 fraction digits |
| Currency | string, `^[A-Z]{3}$` | `PIC X(03)` | 3 | ISO-4217 alpha code |
| AccountType | enum `CHK`/`SAV`/`GL` | `PIC X(03)` | 3 | checking / savings / general-ledger |
| AccountStatus | enum `ACTIVE`/`FROZEN`/`CLOSED` | `PIC X(08)` | 8 | account lifecycle state |
| Direction | enum `D`/`C` | `PIC X(01)` | 1 | debit / credit |
| Status | string | `PIC X(08)` | 8 | left-justified, space-padded |
| RiskRating | enum `A`/`B`/`C`/`D` | `PIC X(01)` | 1 | A best … D worst |
| StaffId | string, `^[A-Z0-9]{1,10}$` | `PIC X(10)` | 10 | console principal id |
| Role | enum `TELLER`/`SUPERVISOR` | `PIC X(10)` | 10 | authorization role |
| Branch | string, `^[0-9]{4}$` | `PIC X(04)` | 4 | 4-digit branch code (authz scope) |
| Token | string, `^[A-Za-z0-9]{16,64}$` | — | — | session token (Pascal-issued) |
| Password | string, 1–64 chars | — | — | login credential (never stored; only its hash) |
| TransferStatus | enum `PENDING`/`POSTED`/`REVERSED`/`REJECTED` | `PIC X(10)` | 10 | transfer lifecycle state |
| MaintenanceAction | enum `FREEZE`/`UNFREEZE` | `PIC X(08)` | 8 | account maintenance op |
| CashAction | enum `DEPOSIT`/`WITHDRAW` | `PIC X(08)` | 8 | teller cash op |
| OpResult | enum `OK`/`REJECTED` | `PIC X(08)` | 8 | outcome of an inquiry, statement or maintenance request |
| Timestamp | string, `date-time` | `PIC X(20)` | 20 | `YYYY-MM-DDThh:mm:ssZ`, UTC |
| Name | string, ≤40 chars | `PIC X(40)` | 40 | left-justified, space-padded |
| Description | string, ≤40 chars | `PIC X(40)` | 40 | left-justified, space-padded |
| TierLabel | string, ≤16 chars | `PIC X(16)` | 16 | settlement tier of a transfer |

Rules that bind every representation:

- **Money never rides as a float.** JSON carries it as a decimal string; COBOL carries it
  as packed-decimal (`COMP-3`); fixed-text carries it as a signed zoned field. An adapter
  converts between the string and the native form; it never routes money through an IEEE-754
  double. `S9(13)V99 COMP-3` occupies 8 bytes.
- **Fixed-text money width is 16**: an optional leading `-`, 13 integer digits, `.`, 2
  fraction digits, right-justified into the 16-column field, space-padded on the left.
- **COBOL alphanumeric fields are space-padded to their full width**; the adapter trims
  trailing spaces when marshalling to JSON and re-pads when marshalling back.
- **Timestamps are always UTC** with a trailing `Z`, second precision.

## Entities

### Customer (DL/I `CUSTSEG` root segment)
`customer_id` · `name` · `status` · `risk_rating` · `opened_at`.
Copybook: [copybook/customer-segment.cpy](copybook/customer-segment.cpy).

### Account (VSAM/ISAM account master, keyed on `account_id`)
`account_id` · `customer_id` · `branch` · `account_type` · `currency` · `balance` · `status` · `opened_at`.
Copybook: [copybook/account-master.cpy](copybook/account-master.cpy).
`branch` is the authorization scope (staff act within their branch); `status` is
`ACTIVE`/`FROZEN`/`CLOSED` (a transfer is rejected on a non-`ACTIVE` account). The core post-transfer
reply echoes the from-account's `account_type` so the gateway can drive the fee calculation without a
second account lookup.

### Staff (SQL table `STAFF`, keyed on `staff_id`)
`staff_id` · `name` · `role` · `branch` · `pw_hash` · `status`. The console's principals. The COBOL
core reads this to authenticate (verify the credential against `pw_hash`) and to resolve `role` and
`branch` for authorization. `role` is `TELLER`/`SUPERVISOR`.
Copybook: [copybook/staff.cpy](copybook/staff.cpy).

### Session (Pascal-local)
`token` · `staff_id` · `role` · `branch` · `expires_at`. Issued by the Pascal console on a successful
login and carried in an auth header on every subsequent op. Held in the console's own store, not a
shared DB; the token scheme is a console concern.

### Transfer (SQL table `TRANSFERS`, keyed on `transfer_id`)
`transfer_id` · `from_account` · `to_account` · `amount` · `currency` · `status` · `initiator` ·
`approver` · `created_at` · `decided_at`. Tracks a transfer's lifecycle and the maker/checker
identities. A transfer at or over the config `require_approval_over` threshold is created
`PENDING` and needs a separate `SUPERVISOR` approval where `approver` ≠ `initiator`
(maker-checker); smaller ones post directly (`POSTED`). Copybook:
[copybook/transfer-record.cpy](copybook/transfer-record.cpy).

### Ledger posting (SQL table `LEDGER`, one row per line)
`posting_id` · `transfer_id` · `account_id` · `direction` · `amount` · `currency` · `posted_at` · `description`.
The database also numbers each line as it is inserted (`line_no`); a statement lists lines in that
order, newest first.
Copybook: [copybook/ledger-posting.cpy](copybook/ledger-posting.cpy).

### Transfer request (transient; the unit the flow acts on)
`transfer_id` · `from_account` · `to_account` · `amount` · `currency` · `requested_by` · `requested_at` · `status`.
REST: [rest/transfer.request.schema.json](rest/transfer.request.schema.json),
[rest/transfer.response.schema.json](rest/transfer.response.schema.json).

### Branch cash account (general ledger)
`99000000` followed by the 4-digit branch code, e.g. `990000000007`. A cash deposit debits it and a
withdrawal credits it, so the ledger stays balanced. It lives in the SQL ledger and the ERP general
ledger only, not in the account master.

### Account maintenance log (SQL table `ACCOUNT_MAINTENANCE`)
`maint_id` · `account_id` · `action` · `staff_id` · `performed_at`. One row per freeze or unfreeze,
written in the same SQL transaction that completes the change.

### GL document (ABAP ERP general ledger)
`gl_doc_id` · `reference` (= `transfer_id`) · `currency` · `posting_date` · line items (`account_id`, `direction`, `amount`) · `status`.
REST: [rest/gl.post-document.request.schema.json](rest/gl.post-document.request.schema.json),
[rest/gl.post-document.response.schema.json](rest/gl.post-document.response.schema.json).

## Authorization

Enforced in the application modules, never the middleware (which only routes and marshals):
- **Pascal** authenticates (via the core), issues and checks the session token, and authorizes console ops
  by `role`.
- **COBOL** (system of record) enforces, on every core op: the account is `ACTIVE`; the acting staff's
  `branch` matches the account `branch`; and, for a `PENDING` transfer, that the
  approver is a `SUPERVISOR` other than the initiator (maker-checker).
Privileged ops — approve, reverse, freeze/unfreeze — require `SUPERVISOR`.
Account inquiry, statement and cash take `TELLER` or `SUPERVISOR`, acting on an account in their
own branch. A cash amount must be positive and below the teller cash limit (10000.00); a withdrawal also
needs the funds.

## Identifiers

- `transfer_id` is minted by the gateway before the COBOL core is called, and threads through
  every downstream call (Fortran, SAS, ABAP) as the correlation key.
- `posting_id` is minted by the COBOL core, one per debit/credit line, and returned to the
  gateway so the report and the GL document can reference the exact lines.
- `gl_doc_id` is minted by ABAP.
