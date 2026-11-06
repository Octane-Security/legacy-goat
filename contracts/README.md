# contracts — marshalling source of truth

Every value that crosses a module boundary is defined here once, so the C/C++ middleware and the
five language modules agree byte-for-byte. Two layers:

- **REST layer** (`rest/*.schema.json`) — JSON over HTTP between the gateway and each adapter, and
  between the gateway and the operational console. JSON Schema 2020-12; shared types in
  `rest/common.schema.json`.
- **Native layer** (`copybook/*.cpy`, `records/*.md`) — the fixed-record form each module actually
  reads and writes. COBOL copybooks for the COBOL core; fixed-text column maps for Fortran and SAS.
  ABAP and Pascal speak HTTP/JSON natively, so their contract is the REST schema alone.

An adapter's whole job is the translation between the two layers for its module. The gateway only
ever sees the REST layer.

**Identity threading.** The caller authenticates to the Pascal console, which issues a session
`token`. External requests carry that `token`; the console resolves it to the acting staff and calls
inward with a resolved `actor` `{staff_id, role, branch}` (`common.schema.json#/$defs/Actor`). So
token-bearing schemas are external→console; `actor`-bearing schemas are console→gateway→COBOL.
Authorization is enforced in the modules (Pascal by role, COBOL by branch-scope, account status, and
maker-checker), never in the middleware.

## The transfer flow

A funds transfer is one request that crosses five modules and three DB interfaces and ends in a
posting report. The `transfer_id` minted in step 1 threads through every downstream call.

| Step | Hop | Contract |
|---|---|---|
| 1 | console → gateway | [rest/transfer.request.schema.json](rest/transfer.request.schema.json) |
| 2 | gateway → COBOL core (validate accounts via VSAM + DL/I, post double-entry to SQL ledger) | [rest/core.post-transfer.request.schema.json](rest/core.post-transfer.request.schema.json) → [copybook/transfer-io.cpy](copybook/transfer-io.cpy) → [rest/core.post-transfer.response.schema.json](rest/core.post-transfer.response.schema.json) |
| 3 | gateway → Fortran (fee + interest) | [rest/risk.compute-fee.request.schema.json](rest/risk.compute-fee.request.schema.json) → [records/fortran-fee-io.md](records/fortran-fee-io.md) → [rest/risk.compute-fee.response.schema.json](rest/risk.compute-fee.response.schema.json) |
| 4 | gateway → SAS (posting/settlement report from the ledger) | [rest/report.posting.request.schema.json](rest/report.posting.request.schema.json) → [records/sas-report-io.md](records/sas-report-io.md) → [rest/report.posting.response.schema.json](rest/report.posting.response.schema.json) |
| 5 | gateway → ABAP (post GL document into the ERP) | [rest/gl.post-document.request.schema.json](rest/gl.post-document.request.schema.json) → [rest/gl.post-document.response.schema.json](rest/gl.post-document.response.schema.json) |
| 6 | gateway → console | [rest/transfer.response.schema.json](rest/transfer.response.schema.json) |

The gateway composes step 6 from the results of steps 2–5: balances and posting ids from the core,
`fee`/`interest`/`net_amount` from Fortran, `report` rows from SAS, `gl_doc_id` from ABAP.

Step 1 requires a valid session `token`. A transfer at or over the configured
`require_approval_over` is created `PENDING` (no postings yet) and completed later by the approval
flow; a smaller one posts directly and runs steps 3–5.

## Authentication

| Hop | Contract |
|---|---|
| caller → console | [rest/session.login.request.schema.json](rest/session.login.request.schema.json) → (token) → [rest/session.login.response.schema.json](rest/session.login.response.schema.json) |
| console → gateway → COBOL | [rest/staff.authenticate.request.schema.json](rest/staff.authenticate.request.schema.json) → [copybook/core-ops.cpy](copybook/core-ops.cpy) (AUTH-REQUEST/REPLY) → [rest/staff.authenticate.response.schema.json](rest/staff.authenticate.response.schema.json) |

COBOL verifies the credential against `STAFF.pw_hash` ([copybook/staff.cpy](copybook/staff.cpy)) and
returns `role` + `branch`; the console mints the session token from that.

## Approval flow (policy-driven)

A `PENDING` transfer is completed by a `SUPERVISOR` other than its initiator (maker-checker), or
reversed. COBOL enforces both against the transfer record ([copybook/transfer-record.cpy](copybook/transfer-record.cpy)).

| Op | Hop | Contract |
|---|---|---|
| approve | console → gateway → COBOL | [rest/transfer.approve.request.schema.json](rest/transfer.approve.request.schema.json) → [rest/core.approve.request.schema.json](rest/core.approve.request.schema.json) → core-ops.cpy (APPROVE-*) → responses |
| reverse | console → gateway → COBOL | [rest/transfer.reverse.request.schema.json](rest/transfer.reverse.request.schema.json) → [rest/core.reverse.request.schema.json](rest/core.reverse.request.schema.json) → core-ops.cpy (REVERSE-*) → responses |

## Account maintenance

Freeze an `ACTIVE` account or unfreeze a `FROZEN` one (`SUPERVISOR`, own branch); COBOL updates the
account master status and logs the change to the SQL `account_maintenance` table.

| Hop | Contract |
|---|---|
| console → gateway → COBOL | [rest/account.maintenance.request.schema.json](rest/account.maintenance.request.schema.json) → [rest/core.acct-maintenance.request.schema.json](rest/core.acct-maintenance.request.schema.json) → core-ops.cpy (MAINT-*) → responses |

## Teller operations

Inquiry and statement read an account; cash moves money between an account and its branch cash
account. Each takes a `TELLER` or `SUPERVISOR` acting on an account in their own branch. For inquiry,
statement and maintenance the gateway returns the core's reply unchanged.

| Op | Hop | Contract |
|---|---|---|
| inquiry | console → gateway → COBOL | [rest/account.inquiry.request.schema.json](rest/account.inquiry.request.schema.json) → [rest/core.inquiry.request.schema.json](rest/core.inquiry.request.schema.json) → core-ops.cpy (INQUIRY-*) → [rest/core.inquiry.response.schema.json](rest/core.inquiry.response.schema.json) |
| statement | console → gateway → COBOL | [rest/account.statement.request.schema.json](rest/account.statement.request.schema.json) → [rest/core.statement.request.schema.json](rest/core.statement.request.schema.json) → core-ops.cpy (STATEMENT-*) → [rest/core.statement.response.schema.json](rest/core.statement.response.schema.json) |
| cash | console → gateway → COBOL, then SAS and ABAP | [rest/cash.request.schema.json](rest/cash.request.schema.json) → [rest/core.cash.request.schema.json](rest/core.cash.request.schema.json) → core-ops.cpy (CASH-*) → [rest/core.cash.response.schema.json](rest/core.cash.response.schema.json) → [rest/cash.response.schema.json](rest/cash.response.schema.json) |

A cash deposit debits the branch cash account (`99000000` followed by the branch code) and credits
the customer's account; a withdrawal does the reverse. The core posts both ledger lines and a
`transfers` row under the gateway's `transfer_id`, and a `POSTED` item then gets its SAS posting
report and ABAP GL document, as a transfer does, with no fee. A cash amount must be positive and
below the teller cash limit of 10000.00.

## Config

Deployment settings are listed in [rest/config.schema.json](rest/config.schema.json). Each module
reads its own settings from its environment at start; the gateway forwards `require_approval_over`
to the core with every transfer, and the ICF service configuration passes `preformatted_refs` to the
ABAP handler as the `x-preformatted-refs` request header. Modules never read config files. The
deployment (runtime repository) supplies the values.

## Conventions

- Field types, widths, and the JSON↔native mapping rules live in [data-model.md](data-model.md).
  That file is authoritative; the schemas and copybooks conform to it.
- Money crosses the REST layer as a decimal string and the native layer as packed-decimal
  (COBOL `COMP-3`) or a signed 16-column field (fixed-text). No boundary carries money as a float.
- REST objects set `additionalProperties: false`; an unknown field is a contract violation, not a
  field to ignore.
- The database load files in the runtime repository conform to the same copybooks and column maps.
