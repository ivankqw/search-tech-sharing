#!/usr/bin/env python3
"""
Copy INSO production entities into the local SearchDemo container.

The script reads from sqldb-inso-etl-prd (Azure SQL) and writes into the
local SQL Server instance that the Docker Compose stack exposes.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Iterable, Iterator, Optional, Sequence, Tuple

try:
    import pyodbc  # type: ignore
except ImportError as exc:  # pragma: no cover
    print(
        "pyodbc is required for this script. Install project dependencies with `uv sync` "
        "and make sure the Microsoft ODBC Driver 18 for SQL Server is present.",
        file=sys.stderr,
    )
    raise


EntityRow = Tuple[str, str, Optional[str], Optional[str]]


def _make_connection(
    *,
    server: str,
    database: str,
    username: str,
    password: str,
    encrypt: bool,
    trust_cert: bool,
) -> pyodbc.Connection:
    options = [
        "DRIVER={ODBC Driver 18 for SQL Server}",
        f"SERVER={server}",
        f"DATABASE={database}",
        f"UID={username}",
        f"PWD={password}",
        f"Encrypt={'yes' if encrypt else 'no'}",
        f"TrustServerCertificate={'yes' if trust_cert else 'no'}",
        "Connection Timeout=30",
    ]
    conn_str = ";".join(options)
    return pyodbc.connect(conn_str)


def _chunked(
    cursor: pyodbc.Cursor, batch_size: int = 10_000
) -> Iterator[Sequence[pyodbc.Row]]:
    while True:
        batch = cursor.fetchmany(batch_size)
        if not batch:
            return
        yield batch


def _clean(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    stripped = value.strip()
    return stripped if stripped else None


def _truncate(value: Optional[str], limit: int) -> Optional[str]:
    if value is None:
        return None
    return value if len(value) <= limit else value[:limit]


def _compose_alt_names(parts: Iterable[Optional[str]]) -> Optional[str]:
    cleaned = [part.strip() for part in parts if part is not None and part.strip()]
    if not cleaned:
        return None
    return " ".join(cleaned)


def _copy_companies(source: pyodbc.Cursor) -> Iterator[EntityRow]:
    source.execute(
        """
        SELECT CompanyID,
               CompanyName,
               Country,
               Continent,
               PrimaryIndustry,
               BusinessDescription,
               Website
        FROM PowerApps.LastCompanyEnriched
        WHERE CompanyName IS NOT NULL
          AND LTRIM(RTRIM(CompanyName)) <> ''
        """
    )
    for batch in _chunked(source):
        for row in batch:
            name = _clean(row.CompanyName)
            if not name:
                continue
            alt = _compose_alt_names(
                (
                    _clean(row.BusinessDescription),
                    _clean(row.Website),
                    _clean(row.PrimaryIndustry),
                    _clean(row.Continent),
                    _clean(row.Country),
                    f"CompanyID={row.CompanyID}",
                )
            )
            yield (
                "company",
                _truncate(name, 256),
                alt,
                _truncate(_clean(row.Country), 64),
            )


def _copy_investors(source: pyodbc.Cursor) -> Iterator[EntityRow]:
    source.execute(
        """
        SELECT Investor,
               PBID
        FROM Staging.InvestorsComputed
        WHERE Investor IS NOT NULL
          AND LTRIM(RTRIM(Investor)) <> ''
        """
    )
    for batch in _chunked(source):
        for row in batch:
            name = _clean(row.Investor)
            if not name:
                continue
            alt = _compose_alt_names((_clean(row.PBID),))
            yield ("investor", _truncate(name, 256), alt, None)


def _copy_funds(source: pyodbc.Cursor) -> Iterator[EntityRow]:
    source.execute(
        """
        SELECT fund_name,
               investor_id
        FROM PowerApps.FundStatic
        WHERE fund_name IS NOT NULL
          AND LTRIM(RTRIM(fund_name)) <> ''
        """
    )
    for batch in _chunked(source):
        for row in batch:
            name = _clean(row.fund_name)
            if not name:
                continue
            alt = _compose_alt_names((_clean(row.investor_id),))
            yield ("fund", _truncate(name, 256), alt, None)


def _copy_people(source: pyodbc.Cursor) -> Iterator[EntityRow]:
    source.execute(
        """
        SELECT PERSON_ID,
               FULL_NAME,
               FIRST_NAME,
               LAST_NAME,
               LINKEDIN_URL,
               TWITTER_URL,
               GITHUB_URL,
               CURRENT_POSITION_COMPANY_NAME,
               CURRENT_POSITION_COMPANY_DOMAIN,
               CURRENT_COMPANY_ID
        FROM PowerApps.PersonAgg
        """
    )
    for batch in _chunked(source):
        for row in batch:
            name = _clean(row.FULL_NAME)
            if not name:
                first = _clean(row.FIRST_NAME)
                last = _clean(row.LAST_NAME)
                if first or last:
                    name = " ".join(filter(None, (first, last)))
            if not name:
                continue
            alt = _compose_alt_names(
                (
                    _clean(row.FIRST_NAME),
                    _clean(row.LAST_NAME),
                    _clean(row.LINKEDIN_URL),
                    _clean(row.TWITTER_URL),
                    _clean(row.GITHUB_URL),
                    _clean(row.CURRENT_POSITION_COMPANY_NAME),
                    _clean(row.CURRENT_POSITION_COMPANY_DOMAIN),
                    _clean(
                        str(row.CURRENT_COMPANY_ID)
                        if row.CURRENT_COMPANY_ID is not None
                        else None
                    ),
                    _clean(row.PERSON_ID),
                )
            )
            yield ("person", _truncate(name, 256), alt, None)


def _prepare_destination(dest: pyodbc.Connection, target_db: str) -> None:
    with dest.cursor() as cursor:
        cursor.execute(f"USE {target_db}")
        cursor.execute(
            """
            IF OBJECT_ID(N'dbo.Entities', N'U') IS NOT NULL
                DROP TABLE dbo.Entities;
            """
        )
        cursor.execute(
            """
            CREATE TABLE dbo.Entities
            (
                id         BIGINT IDENTITY(1,1) NOT NULL,
                type       VARCHAR(20) NOT NULL,
                name       NVARCHAR(256) NOT NULL,
                alt_names  NVARCHAR(MAX) NULL,
                country    VARCHAR(64) NULL,
                created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
                CONSTRAINT PK_Entities PRIMARY KEY CLUSTERED (id)
            );
            """
        )
        cursor.execute("CREATE INDEX IX_Entities_Type ON dbo.Entities (type);")
        cursor.execute("CREATE INDEX IX_Entities_Name ON dbo.Entities (name);")
    dest.commit()


def _insert_entities(dest: pyodbc.Connection, rows: Iterable[EntityRow]) -> int:
    cursor = dest.cursor()
    cursor.fast_executemany = True
    cursor.execute("DELETE FROM dbo.Entities;")
    insert_sql = """
        INSERT INTO dbo.Entities (type, name, alt_names, country)
        VALUES (?, ?, ?, ?);
    """
    total = 0
    batch: list[EntityRow] = []
    for row in rows:
        batch.append(row)
        if len(batch) >= 1000:
            cursor.executemany(insert_sql, batch)
            total += len(batch)
            batch.clear()
    if batch:
        cursor.executemany(insert_sql, batch)
        total += len(batch)
    cursor.commit()
    cursor.connection.commit()
    cursor.close()
    return total


def _extend_rows(*iterables: Iterable[EntityRow]) -> Iterator[EntityRow]:
    for iterable in iterables:
        yield from iterable


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-server", default=os.getenv("SERVER_NAME"), required=False
    )
    parser.add_argument(
        "--source-database", default=os.getenv("DATABASE_NAME"), required=False
    )
    parser.add_argument(
        "--source-user", default=os.getenv("USER_ADMIN"), required=False
    )
    parser.add_argument(
        "--source-password", default=os.getenv("PWD_ADMIN"), required=False
    )
    parser.add_argument("--dest-server", default="localhost,1433", required=False)
    parser.add_argument("--dest-database", default="SearchDemo", required=False)
    parser.add_argument("--dest-user", default="SA", required=False)
    parser.add_argument(
        "--dest-password",
        default=os.getenv("SA_PASSWORD", "Your_password123"),
        required=False,
    )
    parser.add_argument(
        "--skip-prepare", action="store_true", help="Do not recreate dbo.Entities."
    )
    args = parser.parse_args(argv)

    missing = [
        name
        for name, value in (
            ("source_server", args.source_server),
            ("source_database", args.source_database),
            ("source_user", args.source_user),
            ("source_password", args.source_password),
        )
        if not value
    ]
    if missing:
        parser.error(f"Missing connection information for: {', '.join(missing)}")

    print("Connecting to source (Azure SQL)...")
    source_conn = _make_connection(
        server=args.source_server,
        database=args.source_database,
        username=args.source_user,
        password=args.source_password,
        encrypt=True,
        trust_cert=False,
    )
    print("Connecting to destination (local container)...")
    dest_conn = _make_connection(
        server=args.dest_server,
        database=args.dest_database,
        username=args.dest_user,
        password=args.dest_password,
        encrypt=False,
        trust_cert=True,
    )

    try:
        if not args.skip_prepare:
            print("Preparing destination schema...")
            _prepare_destination(dest_conn, args.dest_database)

        print("Copying entities...")
        copied = _insert_entities(
            dest_conn,
            _extend_rows(
                _copy_companies(source_conn.cursor()),
                _copy_investors(source_conn.cursor()),
                _copy_funds(source_conn.cursor()),
                _copy_people(source_conn.cursor()),
            ),
        )
        print(f"Inserted {copied:,} entities into dbo.Entities.")
    finally:
        source_conn.close()
        dest_conn.close()

    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
