USE SearchDemo;
GO

SET NOCOUNT ON;

DECLARE @SampleCount INT = 50;   -- number of prefix samples
DECLARE @TopK INT = 10;          -- results per query

DECLARE @entityCount BIGINT = (SELECT COUNT(*) FROM dbo.Entities);
PRINT N'Entities in scope: ' + CONVERT(NVARCHAR(30), @entityCount);

IF @entityCount = 0
BEGIN
    RAISERROR (N'dbo.Entities is empty. Run load_csv + fts first.', 16, 1);
    RETURN;
END

DECLARE @queries TABLE
(
    query_id      INT IDENTITY(1,1) PRIMARY KEY,
    company_name  NVARCHAR(256),
    prefix_query  NVARCHAR(100),
    infix_fragment NVARCHAR(100)
);

INSERT INTO @queries (company_name, prefix_query, infix_fragment)
SELECT TOP (@SampleCount)
    e.name AS company_name,
    LOWER(
        CASE
            WHEN LEN(token.first_token) >= 4 THEN LEFT(token.first_token, 4)
            ELSE token.first_token
        END
    ) AS prefix_query,
    LOWER(
        CASE
            WHEN LEN(token.first_token) >= 6 THEN SUBSTRING(token.first_token, 2, 4)
            WHEN LEN(token.first_token) >= 3 THEN RIGHT(token.first_token, 3)
            ELSE token.first_token
        END
    ) AS infix_fragment
FROM dbo.Entities AS e
CROSS APPLY
(
    SELECT TOP (1) value AS first_token
    FROM STRING_SPLIT(e.name, N' ', 1)
    WHERE value IS NOT NULL AND value <> N''
    ORDER BY ordinal
) AS token
WHERE e.name IS NOT NULL
  AND LEN(e.name) >= 3
  AND token.first_token IS NOT NULL
ORDER BY e.id;

DECLARE @total INT = (SELECT COUNT(*) FROM @queries);
PRINT N'Sample queries collected: ' + CONVERT(NVARCHAR(30), @total);

IF @total = 0
BEGIN
    RAISERROR (N'Unable to derive sample prefixes from the data set.', 16, 1);
    RETURN;
END

DECLARE @metrics TABLE
(
    method        VARCHAR(32),
    query         NVARCHAR(100),
    duration_ms   DECIMAL(18,3),
    rows_returned INT
);

DECLARE @hits TABLE
(
    id         BIGINT,
    type       VARCHAR(20),
    name       NVARCHAR(256),
    alt_names  NVARCHAR(MAX),
    rank_score INT,
    score      INT
);

DECLARE
    @idx INT = 1,
    @prefix NVARCHAR(100),
    @infix NVARCHAR(100),
    @start DATETIME2(7),
    @stop DATETIME2(7),
    @duration DECIMAL(18,3),
    @rows INT;

WHILE @idx <= @total
BEGIN
    SELECT
        @prefix = prefix_query,
        @infix  = infix_fragment
    FROM @queries
    WHERE query_id = @idx;

    IF @prefix IS NULL OR LEN(@prefix) = 0
    BEGIN
        SET @idx += 1;
        CONTINUE;
    END

    -- FTS (stored procedure)
    DELETE FROM @hits;
    SET @start = SYSDATETIME();
    INSERT INTO @hits
    EXEC dbo.SearchEntities
        @q = @prefix,
        @top = @TopK;
    SET @stop = SYSDATETIME();
    SET @duration = 1.0 * DATEDIFF_BIG(MICROSECOND, @start, @stop) / 1000.0;
    SELECT @rows = COUNT(*) FROM @hits;
    INSERT INTO @metrics (method, query, duration_ms, rows_returned)
    VALUES ('fts_typeahead', @prefix, @duration, @rows);

    -- LIKE prefix (sargable)
    DELETE FROM @hits;
    SET @start = SYSDATETIME();
    INSERT INTO @hits (id, type, name, alt_names, rank_score, score)
    SELECT TOP (@TopK)
        e.id,
        e.type,
        e.name,
        e.alt_names,
        0,
        0
    FROM dbo.Entities AS e
    WHERE e.name LIKE @prefix + N'%'
    ORDER BY e.name;
    SET @stop = SYSDATETIME();
    SET @duration = 1.0 * DATEDIFF_BIG(MICROSECOND, @start, @stop) / 1000.0;
    SET @rows = @@ROWCOUNT;
    INSERT INTO @metrics (method, query, duration_ms, rows_returned)
    VALUES ('like_prefix', @prefix, @duration, @rows);

    -- LIKE infix (non-sargable)
    IF @infix IS NOT NULL AND LEN(@infix) > 0
    BEGIN
        DELETE FROM @hits;
        SET @start = SYSDATETIME();
        INSERT INTO @hits (id, type, name, alt_names, rank_score, score)
        SELECT TOP (@TopK)
            e.id,
            e.type,
            e.name,
            e.alt_names,
            0,
            0
        FROM dbo.Entities AS e
        WHERE e.name LIKE N'%' + @infix + N'%'
        ORDER BY e.name;
        SET @stop = SYSDATETIME();
        SET @duration = 1.0 * DATEDIFF_BIG(MICROSECOND, @start, @stop) / 1000.0;
        SET @rows = @@ROWCOUNT;
        INSERT INTO @metrics (method, query, duration_ms, rows_returned)
        VALUES ('like_infix', @infix, @duration, @rows);
    END

    SET @idx += 1;
END

;WITH agg AS
(
    SELECT
        method,
        duration_ms,
        rows_returned,
        COUNT(*) OVER (PARTITION BY method) AS samples,
        AVG(duration_ms) OVER (PARTITION BY method) AS avg_ms,
        MIN(duration_ms) OVER (PARTITION BY method) AS min_ms,
        MAX(duration_ms) OVER (PARTITION BY method) AS max_ms,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY method) AS p50_ms,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms) OVER (PARTITION BY method) AS p95_ms,
        AVG(rows_returned) OVER (PARTITION BY method) AS avg_rows
    FROM @metrics
)
SELECT
    method,
    MAX(samples)      AS samples,
    CAST(MAX(min_ms)  AS DECIMAL(18,3)) AS min_ms,
    CAST(MAX(p50_ms)  AS DECIMAL(18,3)) AS p50_ms,
    CAST(MAX(p95_ms)  AS DECIMAL(18,3)) AS p95_ms,
    CAST(MAX(avg_ms)  AS DECIMAL(18,3)) AS avg_ms,
    CAST(MAX(max_ms)  AS DECIMAL(18,3)) AS max_ms,
    CAST(MAX(avg_rows) AS DECIMAL(18,2)) AS avg_rows_returned
FROM agg
GROUP BY method
ORDER BY method;

PRINT N'Top 5 slowest queries per method (ms):';
SELECT TOP (5)
    method,
    query,
    duration_ms,
    rows_returned
FROM @metrics
ORDER BY method, duration_ms DESC;

DECLARE @demoPrefix NVARCHAR(100) =
(
    SELECT TOP (1) prefix_query
    FROM @queries
    ORDER BY query_id
);

IF @demoPrefix IS NOT NULL
BEGIN
    PRINT N'Sample results for prefix "' + @demoPrefix + N'" (fts vs LIKE):';

    PRINT N'FTS (dbo.SearchEntities):';
    EXEC dbo.SearchEntities @q = @demoPrefix, @top = 10;

    PRINT N'LIKE prefix (no ranking):';
    SELECT TOP (10)
        e.id,
        e.type,
        e.name
    FROM dbo.Entities AS e
    WHERE e.name LIKE @demoPrefix + N'%'
    ORDER BY e.name;
END
GO
