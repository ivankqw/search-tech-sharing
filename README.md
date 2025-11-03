# Search Tech Sharing Demo

End-to-end playground for executing the “LIKE-but-snappy” name search project on Microsoft SQL Server with Full-Text Search (FTS). It provisions SQL Server via Docker, seeds a synthetic 1M-row dataset, builds the FTS index, installs the stored procedure from the briefing, and runs smoke tests that verify ranking and filtering.

## Prerequisites

- Docker and Docker Compose v2
- ~6 GB of free memory for SQL Server + sample data
- GNU Make (optional but recommended for the helper targets)
- [uv](https://github.com/astral-sh/uv) for Python dependency management

Everything runs locally—no external cloud resources or network calls are required once the container image is built.

## Quick Start

```bash
make all
```

`make all` performs the full lifecycle:

1. Builds the custom SQL Server image with the Linux Full-Text Search feature installed.
2. Starts the container and waits for it to accept connections.
3. Creates the `SearchDemo` database and seeds 1,000,000 synthetic entities.
4. Builds the FTS catalog/index and waits for population to finish.
5. Executes smoke tests in `scripts/test_fulltext.sql` to confirm ranking, prefix handling, type filtering, and empty-query behavior.

Expect the first run to take ~4–5 minutes because it seeds 1M rows and waits for the initial full-text population.

## Useful Commands

```bash
make up       # Start (or rebuild) the SQL Server container
make wait     # Wait until sqlcmd can connect (handy after restarts)
make seed     # Recreate schema + synthetic dataset
make schema   # Rebuild schema without synthetic rows (SeedSynthetic = 0)
make fts      # Rebuild the full-text catalog/index and stored procedure
make load_csv # Bulk load the 23.8M-row CSV from ./data/
make test     # Run smoke tests without reseeding
make down     # Stop and remove the container + network
```

The default SA password is `Your_password123`. Adjust `SA_PASSWORD` in the `Makefile` or override on the command line: `make SA_PASSWORD=BetterPass all`.

## Working with Larger Datasets

### 23.8 M Companies CSV

1. Copy `free_company_dataset.csv` into `./data/`. The compose file mounts this directory read-only at `/data` inside the container.
2. Start the stack and rebuild the schema without synthetic rows:
   ```bash
   make up wait schema
   ```
3. (One-time) Normalize quoting quirks into `free_company_dataset_clean.tsv`:
   ```bash
   python3 scripts/prepare_company_dataset.py
   ```
4. Load the TSV (≈23.8 M companies):
   ```bash
   make load_csv
   ```
   The script lands raw data into `dbo.RawCompanies`, truncates `dbo.Entities`, and repopulates it with normalized names + concatenated metadata in `alt_names`.
5. (Optional) Downsample to a smaller but representative slice (default 6 M rows) before building the full-text index:
   ```bash
   docker compose exec -T sqlserver \
     /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U SA -P Your_password123 \
     -d SearchDemo -i /scripts/sample_entities.sql -v SampleSize=6000000
   ```
6. Rebuild the full-text catalog and run smoke tests (rerun after sampling if you took that step):
   ```bash
   make fts test
   ```

### Replicating the INSO Dataset Locally

The repository now includes the real INSO entities (companies, investors, funds, people). To refresh the container with the latest production snapshot:

1. Install the Microsoft ODBC Driver 18 for SQL Server (runtime) and install the project’s Python dependencies:
   ```bash
   uv sync
   ```
2. Ensure the container is running (`make up wait`) and port `14333` is published.
3. Run the replication script (reads credentials from `.env` by default):
   ```bash
   uv run python scripts/replicate_inso_entities.py --dest-password Your_password123
   ```
4. Rebuild the full-text catalog/procedure:
   ```bash
   make fts
   ```

The script truncates and reloads `dbo.Entities`, then the updated `create_fulltext.sql` rebuilds the catalog with sanitized token handling. Benchmark results are captured in `docs/experiments/fts-vs-like-inso-2025-11-03.md` with the raw SQL output in `results/fts_vs_like_inso_raw.txt`.

For incremental refreshes in a real deployment, switch the full-text index to `CHANGE_TRACKING = AUTO` (already set) and feed inserts/updates through regular DML or Change Tracking/CDC pipelines.

## Demo API (FastAPI)

A lightweight FastAPI service exposes the two search paths over HTTP for demos and Retool integration.

1. Make sure dependencies are installed (`uv sync`) and, if you prefer, activate the virtual environment:
   ```bash
   uv sync
   source .venv/bin/activate  # optional
   ```
2. Export connection overrides if needed (defaults match the docker-compose setup):
   ```bash
   export SQLSERVER_HOST=localhost
   export SQLSERVER_PORT=14333
   export SQLSERVER_USER=SA
   export SQLSERVER_PASSWORD=Your_password123
   export SQLSERVER_DATABASE=SearchDemo
   export SQLSERVER_ENCRYPT=no
   export SQLSERVER_TRUST_SERVER_CERTIFICATE=yes
   ```
3. Launch the API:
   ```bash
   uv run uvicorn service.main:app --reload
   ```
4. Example requests:
   ```bash
   curl -X POST http://localhost:8000/api/search/fts \
        -H "Content-Type: application/json" \
        -d '{"query": "appli", "top": 10}'

   curl -X POST http://localhost:8000/api/search/prefix \
        -H "Content-Type: application/json" \
        -d '{"query": "appli", "top": 10}'
   ```

Use ngrok (or similar) to expose `localhost:8000` and wire the endpoints into Retool. Both endpoints return the same response shape (`{query, type, top, source, duration_ms, results[]}`) so the UI can toggle between FTS and `LIKE` easily.

## Project Structure

- `docker-compose.yml` – Compose file for SQL Server (with FTS) and shared volumes (`scripts/`, `data/`).
- `docker/sqlserver/Dockerfile` – Builds on the official SQL Server 2022 image and installs the Linux FTS feature.
- `scripts/setup_database.sql` – Creates `SearchDemo`, seeds 1M synthetic entities, and adds helper indexes.
- `scripts/create_fulltext.sql` – Drops/rebuilds the FTS catalog + index and deploys `dbo.SearchEntities`; waits for the population to finish.
- `scripts/test_fulltext.sql` – SMOKE checks executed via `make test`.
- `scripts/load_companies_from_csv.sql` – Bulk import + normalization pipeline for `free_company_dataset.csv`.
- `scripts/run_experiments.sql` – Benchmarks FTS vs. `LIKE` prefix/contains and prints summary stats.
- `scripts/replicate_inso_entities.py` – Copies the latest INSO entities from Azure SQL into the local container.
- `docs/experiments/fts-vs-like-2025-10-31.md` – Historical benchmark on the 6 M company sample.
- `docs/experiments/fts-vs-like-inso-2025-11-03.md` – Latest benchmark on the INSO dataset.
- `service/main.py` – FastAPI wrapper exposing `/api/search/fts` and `/api/search/prefix`.
- `docs/name-search-briefing.md` – Slide-ready briefing supplied earlier.

## Clean Up

```bash
make down   # stop containers
docker image rm searchtech/sqlserver:latest  # optional: remove the custom image
```

This repository now executes the complete local project: build infrastructure, seed data, create FTS search, and test it automatically. Extend or replace the seeding script with real data as you progress toward production sizing and Retool integration.
