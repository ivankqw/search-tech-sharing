USE SearchBenchmark;
GO

SET NOCOUNT ON;

DECLARE @SampleCount INT = 50;
DECLARE @TopK INT = 10;

DECLARE @entityCount BIGINT = (SELECT COUNT(*) FROM dbo.Entities);
PRINT N'Entities in scope: ' + CONVERT(NVARCHAR(30), @entityCount);

IF @entityCount = 0
BEGIN
    RAISERROR (N'dbo.Entities is empty in SearchBenchmark.', 16, 1);
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
    LEFT(token.clean_token, 5) AS prefix_query,
    CASE
        WHEN LEN(token.clean_token) >= 7 THEN SUBSTRING(token.clean_token, 3, 4)
        WHEN LEN(token.clean_token) >= 5 THEN SUBSTRING(token.clean_token, 2, 3)
        ELSE NULL
    END AS infix_fragment
FROM dbo.Entities AS e WITH (NOLOCK)
CROSS APPLY
(
    SELECT TOP (1)
        value AS first_token,
        LOWER(
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(value, N'.', N''), N',', N''),
            N'/', N''), N'\', N''), N'-', N''), N'_', N''), N'&', N''), N'@', N''),
            N'#', N''), N'''', N''), N'"', N''), N'+', N''), N'(', N''), N')', N'')
        ) AS clean_token
    FROM STRING_SPLIT(e.name, N' ', 1)
    WHERE value IS NOT NULL AND value <> N''
    ORDER BY ordinal
) AS token
WHERE e.name IS NOT NULL
  AND LEN(token.clean_token) >= 4
ORDER BY e.id;

DECLARE @total INT = (SELECT COUNT(*) FROM @queries);
PRINT N'Sample queries collected: ' + CONVERT(NVARCHAR(30), @total);

IF @total = 0
BEGIN
    RAISERROR (N'Unable to derive sample prefixes from SearchBenchmark data.', 16, 1);
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
    country    VARCHAR(64),
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

    DELETE FROM @hits;
    SET @start = SYSDATETIME();
    INSERT INTO @hits (id, type, name, alt_names, country, rank_score, score)
    EXEC dbo.SearchEntities
        @q = @prefix,
        @top = @TopK;
    SET @stop = SYSDATETIME();
    SET @duration = 1.0 * DATEDIFF_BIG(MICROSECOND, @start, @stop) / 1000.0;
    SELECT @rows = COUNT(*) FROM @hits;
    INSERT INTO @metrics (method, query, duration_ms, rows_returned)
    VALUES ('fts_typeahead', @prefix, @duration, @rows);

    DELETE FROM @hits;
    SET @start = SYSDATETIME();
    INSERT INTO @hits (id, type, name, alt_names, country, rank_score, score)
    SELECT TOP (@TopK)
        e.id,
        e.type,
        e.name,
        e.alt_names,
        e.country,
        0,
        0
    FROM dbo.Entities AS e WITH (NOLOCK)
    WHERE e.name LIKE @prefix + N'%'
    ORDER BY e.name;
    SET @stop = SYSDATETIME();
    SET @duration = 1.0 * DATEDIFF_BIG(MICROSECOND, @start, @stop) / 1000.0;
    SET @rows = @@ROWCOUNT;
    INSERT INTO @metrics (method, query, duration_ms, rows_returned)
    VALUES ('like_prefix', @prefix, @duration, @rows);

    IF @infix IS NOT NULL AND LEN(@infix) > 0
    BEGIN
        DELETE FROM @hits;
        SET @start = SYSDATETIME();
        INSERT INTO @hits (id, type, name, alt_names, country, rank_score, score)
        SELECT TOP (@TopK)
            e.id,
            e.type,
            e.name,
            e.alt_names,
            e.country,
            0,
            0
        FROM dbo.Entities AS e WITH (NOLOCK)
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
;WITH ranked AS
(
    SELECT
        method,
        query,
        duration_ms,
        rows_returned,
        ROW_NUMBER() OVER (PARTITION BY method ORDER BY duration_ms DESC) AS rn
    FROM @metrics
)
SELECT
    method,
    query,
    duration_ms,
    rows_returned
FROM ranked
WHERE rn <= 5
ORDER BY method, duration_ms DESC;
GO
