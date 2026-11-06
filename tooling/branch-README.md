# Branch banking core

A core-banking / payments application made of five modules in COBOL, Fortran, Object Pascal,
SAS and ABAP. Branch staff work it through an operator console: funds transfers, cash deposits and
withdrawals, account inquiries and statements, and account holds. The modules cooperate to post
each transaction and produce the reports and general-ledger documents it generates.

## Modules

| Directory | Language | Role | Owns |
|---|---|---|---|
| [cobol/](cobol/) | COBOL | Core ledger and account master: post double-entry transactions, read and update accounts, read customers | SQL ledger (EXEC SQL), indexed account master (VSAM/ISAM), hierarchical customer segments (IMS DL/I) |
| [fortran/](fortran/) | Fortran | Risk and numerics: interest accrual, fee and settlement math | fixed-record IO, invoked per transfer |
| [pascal/](pascal/) | Object Pascal / Delphi | Operational console: transfers, cash, account inquiries and statements, account holds | HTTP service |
| [sas/](sas/) | SAS | Reporting connector: extract ledger data, produce posting and settlement reports | reads the SQL ledger |
| [abap/](abap/) | ABAP | Reporting integration: post reports into the ERP general ledger | Open SQL, ICF HTTP service |

## How the parts connect

The modules do not call each other directly. A C/C++ middleware layer (an adapter per module plus a
gateway) fronts each module over REST and orchestrates the flows. Every value that crosses a module
boundary is defined in [contracts/](contracts/): REST/JSON schemas and the copybook/record layouts
the modules read and write. The flows and their per-hop contracts are laid out in
[contracts/README.md](contracts/README.md).

## Building and running

The module source lives here; the runtime images, the middleware, the databases, and the
orchestration live in a separate runtime repository that expects this repository checked out beside
it. Deployment settings are listed in
[contracts/rest/config.schema.json](contracts/rest/config.schema.json).

## Layout

```
cobol/       core ledger, account master, DL/I customer access
fortran/     risk / interest / fee numerics
pascal/      operational console service
sas/         reporting connector jobs
abap/        reporting integration (ICF handler classes)
contracts/   REST/JSON contracts + copybook/record layouts (marshalling source of truth)
```

## License

GNU General Public License, version 3. See [LICENSE](LICENSE).
