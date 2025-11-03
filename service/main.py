from __future__ import annotations

import os
import time
from contextlib import contextmanager
from typing import Generator, List, Literal, Optional

import pyodbc
from fastapi import Depends, FastAPI, HTTPException, status
from pydantic import BaseModel, Field


class Settings(BaseModel):
    driver: str = Field(default=os.getenv("SQLSERVER_DRIVER", "ODBC Driver 18 for SQL Server"))
    host: str = Field(default=os.getenv("SQLSERVER_HOST", "localhost"))
    port: int = Field(default=int(os.getenv("SQLSERVER_PORT", "14333")))
    database: str = Field(default=os.getenv("SQLSERVER_DATABASE", "SearchDemo"))
    user: str = Field(default=os.getenv("SQLSERVER_USER", "SA"))
    password: str = Field(default=os.getenv("SQLSERVER_PASSWORD", "Your_password123"))
    encrypt: Literal["yes", "no"] = Field(default=os.getenv("SQLSERVER_ENCRYPT", "no"))
    trust_server_certificate: Literal["yes", "no"] = Field(
        default=os.getenv("SQLSERVER_TRUST_SERVER_CERTIFICATE", "yes")
    )
    login_timeout: int = Field(default=int(os.getenv("SQLSERVER_LOGIN_TIMEOUT", "5")))

    def connection_string(self) -> str:
        return (
            f"DRIVER={{{self.driver}}};"
            f"SERVER={self.host},{self.port};"
            f"DATABASE={self.database};"
            f"UID={self.user};"
            f"PWD={self.password};"
            f"Encrypt={self.encrypt};"
            f"TrustServerCertificate={self.trust_server_certificate};"
            f"LoginTimeout={self.login_timeout};"
        )


def get_settings() -> Settings:
    return Settings()


@contextmanager
def db_connection(settings: Settings) -> Generator[pyodbc.Connection, None, None]:
    conn = pyodbc.connect(settings.connection_string(), autocommit=True)
    try:
        yield conn
    finally:
        conn.close()


def get_connection(settings: Settings = Depends(get_settings)) -> Generator[pyodbc.Connection, None, None]:
    with db_connection(settings) as conn:
        yield conn


class SearchRequest(BaseModel):
    query: str = Field(..., min_length=1, max_length=100)
    type: Optional[str] = Field(default=None, max_length=20)
    top: int = Field(default=10, ge=1, le=50)


class SearchResult(BaseModel):
    id: int
    type: str
    name: str
    alt_names: Optional[str] = None
    country: Optional[str] = None
    score: Optional[int] = None
    rank_score: Optional[int] = None


class SearchResponse(BaseModel):
    query: str
    type: Optional[str]
    top: int
    source: Literal["fts", "like_prefix"]
    duration_ms: float
    results: List[SearchResult]


app = FastAPI(title="Search Demo API", version="1.0.0")


@app.get("/healthz", status_code=status.HTTP_200_OK)
def health_check(settings: Settings = Depends(get_settings)) -> dict[str, str]:
    try:
        with db_connection(settings):
            pass
    except pyodbc.Error as exc:  # pragma: no cover - best effort status
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Database connection failed: {exc}",
        ) from exc
    return {"status": "ok"}


@app.post("/api/search/fts", response_model=SearchResponse)
def search_fts(
    request: SearchRequest,
    conn: pyodbc.Connection = Depends(get_connection),
) -> SearchResponse:
    start = time.perf_counter()
    cursor = conn.cursor()
    try:
        cursor.execute("EXEC dbo.SearchEntities @q=?, @type=?, @top=?", request.query, request.type, request.top)
        rows = cursor.fetchall()
    finally:
        cursor.close()
    elapsed = (time.perf_counter() - start) * 1000

    results = [
        SearchResult(
            id=row.id,
            type=row.type,
            name=row.name,
            alt_names=row.alt_names,
            country=getattr(row, "country", None),
            score=getattr(row, "score", None),
            rank_score=getattr(row, "rank_score", None),
        )
        for row in rows
    ]

    return SearchResponse(
        query=request.query,
        type=request.type,
        top=request.top,
        source="fts",
        duration_ms=round(elapsed, 3),
        results=results,
    )


@app.post("/api/search/prefix", response_model=SearchResponse)
def search_prefix(
    request: SearchRequest,
    conn: pyodbc.Connection = Depends(get_connection),
) -> SearchResponse:
    prefix = request.query.strip()
    if not prefix:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Query must not be empty.")

    start = time.perf_counter()
    cursor = conn.cursor()
    try:
        sql = """
            SELECT TOP (?) id, type, name, alt_names, country
            FROM dbo.Entities
            WHERE name LIKE ?
              AND (? IS NULL OR type = ?)
            ORDER BY name;
        """
        cursor.execute(sql, request.top, f"{prefix}%", request.type, request.type)
        rows = cursor.fetchall()
    finally:
        cursor.close()
    elapsed = (time.perf_counter() - start) * 1000

    results = [
        SearchResult(
            id=row.id,
            type=row.type,
            name=row.name,
            alt_names=row.alt_names,
            country=row.country,
        )
        for row in rows
    ]

    return SearchResponse(
        query=request.query,
        type=request.type,
        top=request.top,
        source="like_prefix",
        duration_ms=round(elapsed, 3),
        results=results,
    )
