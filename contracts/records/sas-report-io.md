# SAS reporting record layout

The SAS reporting connector generates the posting/settlement report for one transfer. The
adapter passes a fixed-text request record; the connector runs a PROC SQL pass-through against
the ledger and emits one fixed-text report row per posting. The adapter reads rows until EOF and
assembles the REST response array ([../rest/report.posting.response.schema.json](../rest/report.posting.response.schema.json)).

Money fields carry the 16-column form from [../data-model.md](../data-model.md).

## Request — `REPORT-REQUEST` (48 chars + newline)

| Columns | Width | Field | Notes |
|---|---|---|---|
| 1–20 | 20 | transfer_id | postings to report on |
| 21–28 | 8 | report_type | `POSTING` / `SETTLE` |
| 29–48 | 20 | as_of | timestamp, report cut-off |

## Report row — `REPORT-ROW` (92 chars + newline, repeated)

| Columns | Width | Field | Notes |
|---|---|---|---|
| 1–20 | 20 | posting_id | |
| 21–40 | 20 | transfer_id | |
| 41–52 | 12 | account_id | |
| 53 | 1 | direction | D / C |
| 54–69 | 16 | amount | |
| 70–72 | 3 | currency | |
| 73–92 | 20 | posted_at | timestamp |

The row set is empty when the transfer has no postings; the adapter returns an empty array,
not an error.
