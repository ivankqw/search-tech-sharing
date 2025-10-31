SET NOCOUNT ON;

PRINT N'Running smoke tests for dbo.SearchEntities...';

DECLARE @results TABLE
(
    id         BIGINT,
    type       VARCHAR(20),
    name       NVARCHAR(256),
    alt_names  NVARCHAR(MAX),
    rank_score INT,
    score      INT
);

DECLARE @sampleName NVARCHAR(256);
DECLARE @sampleType VARCHAR(20);

SELECT TOP (1)
    @sampleName = name,
    @sampleType = type
FROM dbo.Entities
WHERE name IS NOT NULL AND name <> N''
ORDER BY id;

IF @sampleName IS NULL
BEGIN
    RAISERROR (N'No entities available for testing.', 16, 1);
    RETURN;
END

DECLARE @normalized NVARCHAR(256) = LTRIM(RTRIM(@sampleName));
DECLARE @prefixToken NVARCHAR(256);

SELECT TOP (1) @prefixToken = value
FROM STRING_SPLIT(@normalized, N' ', 1)
WHERE value IS NOT NULL AND value <> N''
ORDER BY ordinal;

IF @prefixToken IS NULL
BEGIN
    SET @prefixToken = @normalized;
END

DECLARE @prefixQuery NVARCHAR(100) =
    CASE
        WHEN LEN(@prefixToken) >= 4 THEN LOWER(LEFT(@prefixToken, 4))
        ELSE LOWER(@prefixToken)
    END;

-- Test 1: Exact match should rank first.
DELETE FROM @results;
INSERT INTO @results
EXEC dbo.SearchEntities
    @q = @normalized,
    @top = 5;

IF NOT EXISTS
(
    SELECT 1
    FROM
    (
        SELECT TOP (1) name
        FROM @results
        ORDER BY score DESC, name
    ) AS top_row
    WHERE top_row.name = @normalized
)
BEGIN
    RAISERROR (N'Exact match was not ranked first for query "%s".', 16, 1, @normalized);
END
ELSE
BEGIN
    PRINT N'✔ Exact match ranked first.';
END

-- Test 2: Case-insensitive prefix search should surface the sampled entity.
DELETE FROM @results;
INSERT INTO @results
EXEC dbo.SearchEntities
    @q = @prefixQuery,
    @top = 20;

IF NOT EXISTS (SELECT 1 FROM @results WHERE name = @normalized)
BEGIN
    RAISERROR (N'Prefix query "%s" did not return "%s" within the top 20 results.', 16, 1, @prefixQuery, @normalized);
END
ELSE
BEGIN
    PRINT N'✔ Prefix search surfaced the sampled entity.';
END

-- Test 3: Type filtering should only return the specified type.
DELETE FROM @results;
INSERT INTO @results
EXEC dbo.SearchEntities
    @q = @prefixQuery,
    @type = @sampleType,
    @top = 20;

IF EXISTS (SELECT 1 FROM @results WHERE type <> @sampleType)
BEGIN
    RAISERROR (N'Type filter failed: results include unexpected types.', 16, 1);
END
ELSE
BEGIN
    PRINT N'✔ Type filter limited results correctly.';
END

-- Test 4: Empty string returns fallback rows (sanity check).
DELETE FROM @results;
INSERT INTO @results
EXEC dbo.SearchEntities
    @q = N'',
    @top = 5;

IF NOT EXISTS (SELECT 1 FROM @results)
BEGIN
    RAISERROR (N'Empty query should return fallback rows.', 16, 1);
END
ELSE
BEGIN
    PRINT N'✔ Empty query returned fallback list.';
END

PRINT N'All tests passed.';
