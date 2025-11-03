# FTS vs. LIKE Benchmark (Oct 31, 2025)

Environment: SQL Server 2022 (Linux container), dataset sampled to 6,000,000 entities from `free_company_dataset_clean.tsv`.

## Latency Metrics

| Method | Samples | Min ms | P50 ms | P95 ms | Avg ms | Max ms | Avg Rows |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `fts_typeahead` (`dbo.SearchEntities`) | 50 | 8.364 | 55.306 | 343.454 | 356.905 | 8292.222 | 10.00 |
| `like_prefix` (`name LIKE 'prefix%'`) | 50 | 0.000 | 4.220 | 12.548 | 5.082 | 34.410 | 1.00 |
| `like_infix` (`name LIKE '%term%'`) | 50 | 0.000 | 507.990 | 6973.515 | 1463.414 | 11314.894 | 1.00 |

Observations:
- Full-text search delivers ranked hits and uses the thesaurus boosts but costs more per query. Very short prefixes (two characters) create the outlier measurements.
- Prefix `LIKE` remains fast because it can leverage the B-tree index, but it returns a single lexical row and offers no relevance ordering.
- Infix `LIKE` forces scans; even on 6 million rows, the p95 is roughly 7 seconds.

> **Note:** This run predates the sanitized token handling in `scripts/create_fulltext.sql` and the longer-prefix sampling in `scripts/run_experiments.sql`. Re-run the benchmark with the updated scripts to reflect realistic (≥4 character) prefixes.

## Slow Queries (Top Five Per Method)

| Method | Query | Duration ms | Rows |
| --- | --- | ---: | ---: |
| `fts_typeahead` | `so.c` | 8292.222 | 10 |
| `fts_typeahead` | `mu` | 6205.377 | 10 |
| `fts_typeahead` | `la` | 471.175 | 10 |
| `fts_typeahead` | `inte` | 187.351 | 10 |
| `fts_typeahead` | `desi` | 171.055 | 10 |
| `like_prefix` | `klie` | 34.410 | 1 |
| `like_prefix` | `watu` | 27.245 | 1 |
| `like_prefix` | `pshy` | 21.306 | 1 |
| `like_prefix` | `taip` | 20.154 | 1 |
| `like_prefix` | `vern` | 19.460 | 1 |
| `like_infix` | `akep` | 11314.894 | 1 |
| `like_infix` | `ointed` | 7719.808 | 1 |
| `like_infix` | `dild` | 6946.115 | 1 |
| `like_infix` | `finc` | 6925.004 | 1 |
| `like_infix` | `acle` | 6751.837 | 1 |

## Example: Prefix `raki`

### FTS (`dbo.SearchEntities`)

| Score | Name | Notes |
| ---: | --- | --- |
| 1200 | rakia physics | United States, physics community |
| 1200 | rakia recruiting | Vancouver, HR recruiting |
| 1200 | rakija grill | Miami, food and beverage |
| 1200 | rakish eats | Food startup |
| 968 | rakia | Renewable energy company in Brazil |

### Prefix `LIKE`

`name LIKE 'raki%'` returns lexicographically sorted rows such as:

- raki cabanas  
- raki thomas and ramanan  
- rakib  
- rakib agency  
- rakib digital

The unranked results highlight why full-text ranking is preferable for UI and API integration.

## Dataset Snapshot

- Rows: 6,000,000 (sampled hash-randomly from 34,234,738 original entries).
- Top countries: United States (1,567,717), Unknown (667,102), United Kingdom (520,972), India (343,457), France (341,056), Brazil (294,365), China (216,185), Spain (204,443), Germany (186,871), Canada (149,817).

## Reproduction Steps

1. `make up wait schema`
2. `python3 scripts/prepare_company_dataset.py`
3. `make load_csv`
4. `docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U SA -P Your_password123 -d SearchDemo -i /scripts/sample_entities.sql -v SampleSize=6000000`
5. `make fts test`
6. `docker compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U SA -P Your_password123 -d SearchDemo -i /scripts/run_experiments.sql`
