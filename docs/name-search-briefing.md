## LIKE-but-snappy Name Search Briefing

This briefing is ready to drop into a technical deck for a name-search feature (companies, people, funds, investors) at up to 1M rows, with a Retool frontend and Microsoft SQL Server backend.

### 1. Overview: Fast Name Lookup Patterns

- **Target experience:** Keystrokes should return ranked suggestions in tens of milliseconds.
- **Search strategy:** Use lexical search with an inverted index so results come from index hits instead of table scans.
- **Match handling:** Support prefixes, diacritics, case folding, token boundaries (for example, `Acme Vent...` → `Acme Ventures LLC`), synonyms, and common abbreviations (`Mgmt` ↔ `Management`, `Intl` ↔ `International`).
- **Typeahead ranking:** Exact match > prefix on first token > prefix on any token > fuzzy or phonetic fallback.
- **Recommended tool:** SQL Server Full-Text Search (FTS) provides linguistic tokenization, word breakers, stoplists, and relevance scores via `CONTAINSTABLE`.

**Why not `LIKE '%text%'`:**
- Patterns that start with wildcards are non-sargable, so the optimizer falls back to scans and ignores B-tree order. Indexes only help with leading constants (for example, `LIKE 'acme%'`). Achieving "LIKE-but-snappy" speed requires a search index, not raw `LIKE`.

### 2. Implementation Options and Current SOTA

#### A. SQL-only (inside SQL Server)

- **FTS query pattern:** Use `CONTAINSTABLE` or `CONTAINS` for prefix search and ranking. Disable, replace, or tune stoplists so legal suffixes such as `&`, `and`, `the`, and `llc` are retained.
- **Accent and case handling:** Set catalog `ACCENT_SENSITIVITY = OFF` (or align with database collation) and use case-insensitive collations on name columns.
- **Synonyms:** Maintain a thesaurus (`FORMSOF(THESAURUS, ...)`) for abbreviations like `Intl` ↔ `International`, `Mgmt` ↔ `Management`.
- **Phonetic hinting:** `SOUNDEX()` / `DIFFERENCE()` can help with English-centric phonetic similarity (`Smyth` vs `Smith`), but they are best as tie-breakers rather than primary ranking.
- **Operations:** Enable `CHANGE_TRACKING = AUTO` on the FTS index for near-real-time updates. Use `sys.dm_fts_parser` to inspect tokenization and stopword effects.
- **Helper columns:** Persisted, normalized helper columns (for example, `search_name`) indexed with B-trees can speed left-anchored prefix fallbacks (`WHERE search_name LIKE @q + '%'`), but they do not solve infix search.

**SQL-only limitations:**
- In-token substring search (`'croso'` → `'microsoft'`) is not native. Options include custom n-gram tables or moving to a dedicated search engine with n-gram analyzers.

#### B. External Search Engines (Elasticsearch, OpenSearch, Azure AI Search)

- **Why teams adopt them:** Built-in autocomplete (edge n-grams or suggesters), BM25 ranking, fuzzy matching, synonyms, and turnkey scaling.
- **Azure AI Search:** Provides suggesters, autocomplete, fuzzy options, and kNN/HNSW for hybrid lexical+vector search.
- **Hybrid baseline:** Combine lexical BM25 with vectors when semantics matter (name lookup usually does not require vectors immediately, but this is the modern reference architecture).

#### Cross-cutting challenges

- **Normalization:** Fold case and diacritics; strip legal suffixes (`Inc`, `LLC`, `Ltd`, `S.A.`); unify punctuation (for example, `O'Connor`, hyphens).
- **Tokenization:** Pick the correct word breaker (LCID) for the data languages.
- **Stopwords and synonyms:** Disable default stoplists when they interfere with names; curate a business thesaurus.
- **Latency budget:** Debounce typeahead requests (Retool has built-in debounce on event handlers).
- **Freshness:** Use SQL Server Change Tracking or CDC to feed FTS or external indexers.

### 3. Experiment Plan (Toy Dataset, 1M Entities)

**Goal:** Measure P50/P95 latency and relevance for FTS versus a `LIKE` baseline and optionally compare to Azure AI Search or Elasticsearch.

**Schema:**
```sql
CREATE TABLE dbo.Entities (
  id        BIGINT IDENTITY(1,1) PRIMARY KEY,
  type      VARCHAR(20) NOT NULL,  -- 'company','person','fund','investor'
  name      NVARCHAR(256) NOT NULL,
  alt_names NVARCHAR(MAX) NULL,
  country   VARCHAR(2) NULL
);
```

**Synthetic population (illustrative):**
```sql
;WITH n AS (
  SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.Entities (type, name)
SELECT
  CASE (n % 4) WHEN 0 THEN 'company'
               WHEN 1 THEN 'person'
               WHEN 2 THEN 'fund'
               ELSE 'investor'
  END,
  CONCAT('Acme ',
         CASE (n % 5)
           WHEN 0 THEN 'Ventures'
           WHEN 1 THEN 'Capital'
           WHEN 2 THEN 'Holdings'
           WHEN 3 THEN 'Partners'
           ELSE 'International'
         END,
         ' ',
         n)
FROM n;
```

**FTS catalog and index:**
```sql
CREATE FULLTEXT CATALOG ft_main WITH ACCENT_SENSITIVITY = OFF;

CREATE FULLTEXT INDEX ON dbo.Entities
(
  name LANGUAGE 1033,
  alt_names LANGUAGE 1033
)
KEY INDEX PK__Entities__id
ON ft_main
WITH STOPLIST = OFF, CHANGE_TRACKING = AUTO;
```

**Queries to benchmark:**
- Typeahead:
  ```sql
  DECLARE @q NVARCHAR(100) = N'acme ven';

  SELECT TOP (20) e.id, e.type, e.name, ft.RANK
  FROM CONTAINSTABLE(dbo.Entities, (name, alt_names), @q + N'*') AS ft
  JOIN dbo.Entities e ON e.id = ft.[KEY]
  ORDER BY ft.RANK DESC, e.name;
  ```
- Synonym expansion:
  ```sql
  SELECT TOP (20) e.id, e.name, ft.RANK
  FROM CONTAINSTABLE(dbo.Entities, name, 'FORMSOF(THESAURUS, "intl")') ft
  JOIN dbo.Entities e ON e.id = ft.[KEY]
  ORDER BY ft.RANK DESC;
  ```
- Baseline `LIKE` comparisons:
  ```sql
  -- Left-anchored (sargable)
  SELECT TOP (20) id, name
  FROM dbo.Entities
  WHERE name LIKE N'acme%'
  ORDER BY name;

  -- Infix (non-sargable)
  SELECT TOP (20) id, name
  FROM dbo.Entities
  WHERE name LIKE N'%cme ven%';
  ```

Enable `SET STATISTICS TIME, IO ON;` and capture execution plans across randomized queries. Expect FTS to use inverted indexes while `%...%` infix patterns trigger scans.

### 4. Proposed Architecture (SQL Server + Retool)

**Short-term (ship quickly with low ops burden):**
- Create a single FTS catalog (typically accent insensitive) with `STOPLIST = OFF` or a custom stoplist for names.
- Use `CHANGE_TRACKING = AUTO` so inserts and updates flow into the index without manual jobs.
- Maintain a thesaurus file for abbreviations and suffixes; reload via `sp_fulltext_load_thesaurus_file`.
- Expose a GET `/search?q=&type=&top=` API (Node or .NET). Parameterize `@q` and call `CONTAINSTABLE`, returning `{ id, type, name, rank }`.
- In Retool, debounce the TextInput `onChange` event (150–250 ms) and either query SQL Server directly or call the API. Show the top 10 suggestions in a dropdown and navigate to a full results table on submit.
- Post-process `RANK` for extra boosts:
  - Exact name match → +1000
  - Prefix on first token → +200
  - Prefix on any token → +50
  - Phonetic tie-breakers via `DIFFERENCE()` when ranks are close.
- Watch edge cases (hyphens, apostrophes, diacritics) using `sys.dm_fts_parser` for diagnostics.

**Long-term (when requirements outgrow SQL-only):**
- Consider Azure AI Search for suggesters, fuzzy matching, BM25 relevance, and hybrid vector+lexical search.
- Feed the external index using SQL Server Change Tracking or CDC.
- Dual-read behind a feature flag, compare latency and quality, then switch primary search traffic once validated.

### 5. Closing Guidance for the Deck

- For ≤1M names, SQL Server FTS meets the "LIKE-but-snappy" requirements with minimal operational overhead and clean Retool integration.
- Avoid `%...%` patterns in production paths; they are non-sargable and cannot deliver sub-100 ms results.
- Introduce an external engine when you need richer autocomplete, fuzzy search, advanced ranking, or larger-scale workloads.
- Quality and ops checklist:
  - Normalize and index `name` plus `alt_names`.
  - Disable default stoplists or build a custom one for names; confirm language LCID and accent settings.
  - Maintain a lightweight thesaurus for abbreviations and legal suffixes.
  - Debounce search requests in Retool.
  - Track zero-result rate, click-through, latency (P50/P95), and index freshness. Use `sys.dm_fts_parser` for debugging.

### Appendix: Drop-in SQL Snippets

**Catalog and FTS index:**
```sql
CREATE FULLTEXT CATALOG ft_main WITH ACCENT_SENSITIVITY = OFF;
GO

CREATE FULLTEXT INDEX ON dbo.Entities
(
  name LANGUAGE 1033,
  alt_names LANGUAGE 1033
)
KEY INDEX PK__Entities__id
ON ft_main
WITH STOPLIST = OFF, CHANGE_TRACKING = AUTO;
GO
```

**Stored procedure for typeahead:**
```sql
CREATE OR ALTER PROC dbo.SearchEntities
  @q   NVARCHAR(100),
  @type VARCHAR(20) = NULL,
  @top INT = 20
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @fts NVARCHAR(200) = @q + N'*';

  ;WITH hits AS (
    SELECT TOP (@top * 3) [KEY] AS id, RANK
    FROM CONTAINSTABLE(dbo.Entities, (name, alt_names), @fts)
  )
  SELECT TOP (@top)
    e.id,
    e.type,
    e.name,
    ft.RANK
      + CASE
          WHEN e.name = @q THEN 1000
          WHEN e.name LIKE @q + N'%' THEN 200
          WHEN e.name LIKE N'% ' + @q + N'%' THEN 50
          ELSE 0
        END AS score
  FROM hits ft
  JOIN dbo.Entities e ON e.id = ft.id
  WHERE (@type IS NULL OR e.type = @type)
  ORDER BY score DESC, e.name;
END;
```

**Retool notes:**
- Configure a SQL Server or REST resource.
- Use TextInput `.value` with Debounce to trigger `SearchEntities`.
- Display top results in a dropdown or table.

### Dataset Note

You mentioned a 23.8M-row CSV at `C:\Users\IvanKoh\Downloads\free_company_dataset.csv`. This Linux workspace cannot reach that Windows path directly, so copy or mount the file into the repository (for example, under `data/`) before running local experiments. Sampling subsets will help validate query plans before attempting the full dataset.
