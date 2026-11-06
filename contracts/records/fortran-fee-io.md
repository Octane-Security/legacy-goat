# Fortran risk/fee record layout

The Fortran numerics engine reads one fixed-text request record from stdin and writes one
fixed-text reply record to stdout. Money fields carry the 16-column form from
[../data-model.md](../data-model.md) (signed, 13 integer + 2 fraction digits, right-justified).
The adapter builds the request columns and parses the reply columns; it does not reorder them.

## Request — `RISK-FEE-REQUEST` (51 chars + newline)

| Columns | Width | Field | Fortran | Notes |
|---|---|---|---|---|
| 1–20 | 20 | transfer_id | A20 | correlation key |
| 21–36 | 16 | amount | F16.2 | transfer amount |
| 37–39 | 3 | currency | A3 | ISO-4217 |
| 40–42 | 3 | account_type | A3 | CHK / SAV / GL |
| 43–47 | 5 | term_days | I5 | accrual term, zero-padded |
| 48–51 | 4 | rate_code | A4 | rate-table selector |

`READ(*, '(A20,F16.2,A3,A3,I5,A4)') ...`

## Reply — `RISK-FEE-REPLY` (76 chars + newline)

| Columns | Width | Field | Fortran | Notes |
|---|---|---|---|---|
| 1–20 | 20 | transfer_id | A20 | echoed |
| 21–36 | 16 | fee | F16.2 | computed fee |
| 37–52 | 16 | interest | F16.2 | accrued interest |
| 53–68 | 16 | net_amount | F16.2 | amount + fee + interest |
| 69–76 | 8 | status | A8 | `OK` / `RANGEERR` |

`WRITE(*, '(A20,3F16.2,A8)') ...`
