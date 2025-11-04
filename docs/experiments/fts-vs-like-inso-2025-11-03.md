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
| `fts_typeahead` (`dbo.SearchEntities`) | 50 | 0.000 | 4.309 | 13.002 | 8.749 | 234.109 | 4.00 |
| `like_prefix` (`name LIKE 'prefix%'`) | 50 | 0.000 | 0.000 | 2.392 | 0.262 | 4.384 | 1.00 |
| `like_infix` (`name LIKE '%term%'`) | 33 | 4.348 | 199.623 | 440.838 | 227.840 | 456.507 | 1.00 |

## Slowest Queries (Per Method)

| Method | Query | Duration ms | Rows |
| --- | --- | ---: | ---: |
| `fts_typeahead` | `100%` | 234.109 | 10 |
| `fts_typeahead` | `1000` | 26.194 | 10 |
| `fts_typeahead` | `1010` | 13.006 | 10 |
| `fts_typeahead` | `zero` | 12.997 | 10 |
| `fts_typeahead` | `zero` | 12.852 | 10 |
| `like_infix` | `006` | 456.507 | 1 |
| `like_infix` | `0si` | 446.021 | 1 |
| `like_infix` | `00tr` | 437.383 | 1 |
| `like_infix` | `xpp` | 416.445 | 1 |
| `like_infix` | `00fa` | 409.906 | 1 |
| `like_prefix` | `split` | 4.384 | 1 |
| `like_prefix` | `1055` | 4.353 | 1 |
| `like_prefix` | `appli` | 4.350 | 1 |
| `like_prefix` | `sheng` | 0.000 | 1 |
| `like_prefix` | `01ai` | 0.000 | 1 |

## Notes

- Roughly half of the expected company rows were absent in this snapshot (115,641 vs. 231,280). Follow up with the upstream view (`PowerApps.LastCompanyEnriched`) to confirm whether blanks/null names were removed mid-snapshot or whether additional filters are needed.
- Updated `dbo.SearchEntities` now treats corporate suffixes (`inc`, `ltd`, `llc`, `company`, etc.) as optional tokens so queries like “stripe company” match on the meaningful term while still rewarding additional words when present.
- FTS keeps P95 at ≈13 ms with one outlier (`100%`) where the optional token list still explodes; debounce client calls around 200 ms to smooth out spikes.
- Prefix `LIKE` remains effectively instantaneous because it hits the clustered index and returns single rows, but it offers no ranking.
- Infix `LIKE` continues to scan, holding P95 just under 0.45 s on ~274 K rows—illustrating the need for FTS (or a search service) for substring queries.
