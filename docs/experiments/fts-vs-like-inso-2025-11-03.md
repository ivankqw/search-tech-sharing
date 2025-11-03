# FTS vs. LIKE Benchmark – INSO Dataset (Nov 3, 2025)

Environment: local SQL Server 2022 container (Linux) populated from `sqldb-inso-etl-prd`. The latest replication (Nov 3, 2025 evening) produced **273,943** entities after filtering out blank company names.

## Dataset Snapshot

- Companies: 115,641  
- Investors: 123,232  
- Funds: 778  
- People: 34,292  
- Top countries (entities with a country value): United States (36,327), China (13,829), United Kingdom (11,871), France (9,892), Germany (7,433), India (4,736), Italy (4,509), Netherlands (4,388), Spain (3,593), Sweden (2,304).

## Latency Metrics (50 Prefix Samples, Min 4 Characters)

| Method | Samples | Min ms | P50 ms | P95 ms | Avg ms | Max ms | Avg Rows |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `fts_typeahead` (`dbo.SearchEntities`) | 50 | 0.000 | 4.243 | 13.055 | 4.911 | 59.480 | 4.00 |
| `like_prefix` (`name LIKE 'prefix%'`) | 50 | 0.000 | 0.000 | 0.000 | 0.082 | 4.107 | 1.00 |
| `like_infix` (`name LIKE '%term%'`) | 33 | 4.248 | 187.712 | 397.636 | 211.971 | 423.293 | 1.00 |

## Slowest Queries (Per Method)

| Method | Query | Duration ms | Rows |
| --- | --- | ---: | ---: |
| `fts_typeahead` | `100%` | 59.480 | 10 |
| `fts_typeahead` | `appli` | 20.981 | 10 |
| `fts_typeahead` | `1000` | 16.701 | 10 |
| `fts_typeahead` | `zero` | 8.599 | 10 |
| `fts_typeahead` | `0xppl` | 8.560 | 2 |
| `like_infix` | `0te` | 423.293 | 1 |
| `like_infix` | `00m` | 405.626 | 1 |
| `like_infix` | `iqin` | 392.310 | 1 |
| `like_infix` | `xky` | 386.915 | 1 |
| `like_infix` | `00fa` | 384.445 | 1 |
| `like_prefix` | `appli` | 4.107 | 1 |
| `like_prefix` | `sheng` | 0.000 | 1 |
| `like_prefix` | `01ai` | 0.000 | 1 |
| `like_prefix` | `011h` | 0.000 | 1 |
| `like_prefix` | `zero` | 0.000 | 1 |

## Notes

- Roughly half of the expected company rows were absent in this snapshot (115,641 vs. 231,280). Follow up with the upstream view (`PowerApps.LastCompanyEnriched`) to confirm whether blanks/null names were removed mid-snapshot or whether additional filters are needed.
- FTS still keeps P95 under 14 ms, with one heavy query (`100%`) at ~59 ms; the shorter average row count (≈4) suggests fewer alternate name matches after the reduced dataset.
- Prefix `LIKE` remains effectively instantaneous because it hits the clustered index and returns single rows, but it offers no ranking.
- Infix `LIKE` continues to scan, holding P95 just under 0.4 s on ~274 K rows—illustrating the need for FTS (or a search service) for substring queries.
