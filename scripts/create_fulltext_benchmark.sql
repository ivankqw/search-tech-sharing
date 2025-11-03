USE SearchBenchmark;
GO

IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'dbo.Entities'))
BEGIN
    PRINT N'Dropping existing full-text index on dbo.Entities (SearchBenchmark)...';
    DROP FULLTEXT INDEX ON dbo.Entities;
END
GO

IF EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ft_benchmark')
BEGIN
    PRINT N'Dropping full-text catalog ft_benchmark...';
    DROP FULLTEXT CATALOG ft_benchmark;
END
GO

PRINT N'Creating full-text catalog ft_benchmark...';
CREATE FULLTEXT CATALOG ft_benchmark WITH ACCENT_SENSITIVITY = OFF;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Entities_Id')
BEGIN
    PRINT N'Creating unique index UX_Entities_Id for full-text key...';
    CREATE UNIQUE INDEX UX_Entities_Id ON dbo.Entities (id);
END

PRINT N'Creating full-text index on dbo.Entities (SearchBenchmark)...';
CREATE FULLTEXT INDEX ON dbo.Entities
(
    name LANGUAGE 1033,
    alt_names LANGUAGE 1033
)
KEY INDEX UX_Entities_Id ON ft_benchmark
WITH STOPLIST = OFF, CHANGE_TRACKING = AUTO;
GO

DECLARE @populate_status INT = FULLTEXTCATALOGPROPERTY(N'ft_benchmark', N'PopulateStatus');
WHILE @populate_status <> 0
BEGIN
    WAITFOR DELAY '00:00:01';
    SET @populate_status = FULLTEXTCATALOGPROPERTY(N'ft_benchmark', N'PopulateStatus');
END
PRINT N'Full-text catalog ft_benchmark population complete.';
GO

IF OBJECT_ID(N'dbo.SearchEntities', N'P') IS NOT NULL
BEGIN
    PRINT N'Dropping stored procedure dbo.SearchEntities (SearchBenchmark)...';
    DROP PROC dbo.SearchEntities;
END
GO

PRINT N'Creating stored procedure dbo.SearchEntities (SearchBenchmark)...';
GO
CREATE PROC dbo.SearchEntities
    @q    NVARCHAR(100),
    @type VARCHAR(20) = NULL,
    @top  INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @normalized NVARCHAR(100) = LTRIM(RTRIM(@q));

    IF @normalized IS NULL OR @normalized = N''
    BEGIN
        SELECT TOP (@top)
            e.id,
            e.type,
            e.name,
            e.alt_names,
            e.country,
            CAST(0 AS INT) AS rank_score,
            CAST(0 AS INT) AS score
        FROM dbo.Entities AS e
        WHERE (@type IS NULL OR e.type = @type)
        ORDER BY e.name;
        RETURN;
    END

    DECLARE @sanitized NVARCHAR(100) = LOWER(@normalized);
    SET @sanitized = REPLACE(@sanitized, N'.', N' ');
    SET @sanitized = REPLACE(@sanitized, N',', N' ');
    SET @sanitized = REPLACE(@sanitized, N'/', N' ');
    SET @sanitized = REPLACE(@sanitized, N'\', N' ');
    SET @sanitized = REPLACE(@sanitized, N'-', N' ');
    SET @sanitized = REPLACE(@sanitized, N'_', N' ');
    SET @sanitized = REPLACE(@sanitized, N'&', N' ');
    SET @sanitized = REPLACE(@sanitized, N'@', N' ');
    SET @sanitized = REPLACE(@sanitized, N'#', N' ');
    SET @sanitized = REPLACE(@sanitized, N'''', N' ');
    SET @sanitized = REPLACE(@sanitized, N'"', N' ');
    SET @sanitized = REPLACE(@sanitized, N'+', N' ');
    SET @sanitized = REPLACE(@sanitized, N'(', N' ');
    SET @sanitized = REPLACE(@sanitized, N')', N' ');
    SET @sanitized = REPLACE(@sanitized, N'[', N' ');
    SET @sanitized = REPLACE(@sanitized, N']', N' ');
    SET @sanitized = REPLACE(@sanitized, N':', N' ');
    SET @sanitized = REPLACE(@sanitized, N';', N' ');
    SET @sanitized = REPLACE(@sanitized, N'!', N' ');
    SET @sanitized = REPLACE(@sanitized, N'?', N' ');

    DECLARE @fts NVARCHAR(4000);
    DECLARE @first_token NVARCHAR(100);

    SELECT TOP (1)
        @first_token = value
    FROM STRING_SPLIT(@sanitized, N' ', 1)
    WHERE value IS NOT NULL AND value <> N''
    ORDER BY ordinal;

    ;WITH filtered AS
    (
        SELECT value
        FROM STRING_SPLIT(@sanitized, N' ', 1)
        WHERE value IS NOT NULL AND value <> N'' AND LEN(value) >= 3
    )
    SELECT @fts = STRING_AGG(N'"' + REPLACE(value, '"', '""') + N'*"', N' AND ')
    FROM filtered;

    IF @fts IS NULL
    BEGIN
        IF @first_token IS NULL OR LEN(@first_token) = 0
        BEGIN
            RETURN;
        END

        DECLARE @like_prefix NVARCHAR(100) = LEFT(@first_token, 20) + N'%';

        SELECT TOP (@top)
            e.id,
            e.type,
            e.name,
            e.alt_names,
            e.country,
            CAST(0 AS INT) AS rank_score,
            CAST(0 AS INT)
                + CASE
                      WHEN e.name = @normalized THEN 1000
                      WHEN @first_token IS NOT NULL AND e.name = @first_token THEN 950
                      WHEN e.name LIKE @normalized + N'%' THEN 200
                      WHEN @first_token IS NOT NULL AND e.name LIKE @first_token + N'%' THEN 180
                      WHEN e.name LIKE N'% ' + @normalized + N'%' THEN 50
                      WHEN @first_token IS NOT NULL AND e.name LIKE N'% ' + @first_token + N'%' THEN 40
                      ELSE 0
                  END
                + CASE WHEN @type IS NOT NULL AND e.type = @type THEN 25 ELSE 0 END
              AS score
        FROM dbo.Entities AS e
        WHERE (@type IS NULL OR e.type = @type)
          AND e.name LIKE @like_prefix
        ORDER BY score DESC, e.name;
        RETURN;
    END

    ;WITH hits AS
    (
        SELECT TOP (@top * 5)
            [KEY]        AS id,
            RANK         AS rank_score
        FROM CONTAINSTABLE(dbo.Entities, (name, alt_names), @fts)
    )
    SELECT TOP (@top)
        e.id,
        e.type,
        e.name,
        e.alt_names,
        e.country,
        h.rank_score,
        h.rank_score
            + CASE
                  WHEN e.name = @normalized THEN 1000
                  WHEN @first_token IS NOT NULL AND e.name = @first_token THEN 950
                  WHEN e.name LIKE @normalized + N'%' THEN 200
                  WHEN @first_token IS NOT NULL AND e.name LIKE @first_token + N'%' THEN 180
                  WHEN e.name LIKE N'% ' + @normalized + N'%' THEN 50
                  WHEN @first_token IS NOT NULL AND e.name LIKE N'% ' + @first_token + N'%' THEN 40
                  ELSE 0
              END
            + CASE WHEN @type IS NOT NULL AND e.type = @type THEN 25 ELSE 0 END
          AS score
    FROM hits AS h
    INNER JOIN dbo.Entities AS e
        ON e.id = h.id
    WHERE (@type IS NULL OR e.type = @type)
    ORDER BY score DESC, e.name;
END;
GO

PRINT N'SearchBenchmark full-text configuration complete.';
