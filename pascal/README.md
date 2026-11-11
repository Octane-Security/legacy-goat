# pascal — operational console

A headless HTTP service (Free Pascal, `{$MODE DELPHI}`, fcl-web) and the flow's entry point. Staff
sign on and work the teller functions through plain HTML forms in a console window: funds transfers,
cash deposits and withdrawals, account inquiries and statements, and (supervisors) account holds.
They also download posting receipts, preview upstream services and import settlement advices.

| Route | Purpose |
|---|---|
| `GET /`, `GET /login`, `POST /login` | staff sign-on |
| `GET /menu` | teller main menu |
| `GET /transfer`, `POST /transfer` | funds transfer form and result |
| `GET /deposit`, `POST /deposit` | cash deposit form and receipt |
| `GET /withdraw`, `POST /withdraw` | cash withdrawal form and receipt |
| `GET /inquiry` | account inquiry (`?account_id=`) |
| `GET /statement` | account statement, the ten most recent postings (`?account_id=`) |
| `GET /maintenance`, `POST /maintenance` | account hold: freeze or unfreeze (supervisors) |
| `POST /logout` | sign off |
| `GET /receipt` | download a posting receipt |
| `GET /fetch` | preview an upstream service |
| `POST /import` | import a settlement advice (XML) |
| `GET /healthz` | liveness |

- Sends `../contracts/rest/transfer.request.schema.json`, `cash.request`, `account.inquiry.request`,
  `account.statement.request` and `account.maintenance.request` to the gateway, with the signed-on
  staff member in the `X-Staff-Id`, `X-Role` and `X-Branch` headers.
- Renders the matching `*.response.schema.json`.
- Settings: `../contracts/rest/config.schema.json`.
