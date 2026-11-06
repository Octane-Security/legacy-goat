# fortran — risk and numerics

Computes the fee and accrued interest for a transfer, and the resulting net amount. Invoked per
transfer with fixed-record IO.

- Implements `../contracts/rest/risk.compute-fee.*.schema.json`.
- Record layout: `../contracts/records/fortran-fee-io.md`.
