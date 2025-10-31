USE SearchDemo;
GO

IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'dbo.Entities'))
BEGIN
    PRINT N'Dropping existing full-text index on dbo.Entities...';
    DROP FULLTEXT INDEX ON dbo.Entities;
END
GO

IF EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ft_main')
BEGIN
    PRINT N'Dropping full-text catalog ft_main...';
    DROP FULLTEXT CATALOG ft_main;
END
GO

PRINT N'Creating full-text catalog ft_main...';
CREATE FULLTEXT CATALOG ft_main WITH ACCENT_SENSITIVITY = OFF;
GO

PRINT N'Creating full-text index on dbo.Entities...';
CREATE FULLTEXT INDEX ON dbo.Entities
(
    name LANGUAGE 1033,
    alt_names LANGUAGE 1033
)
KEY INDEX PK_Entities
ON ft_main
WITH STOPLIST = OFF, CHANGE_TRACKING = AUTO;
GO

DECLARE @populate_status INT = FULLTEXTCATALOGPROPERTY(N'ft_main', N'PopulateStatus');
WHILE @populate_status <> 0
BEGIN
    WAITFOR DELAY '00:00:01';
    SET @populate_status = FULLTEXTCATALOGPROPERTY(N'ft_main', N'PopulateStatus');
END
PRINT N'Full-text catalog ft_main population complete.';
GO

IF OBJECT_ID(N'dbo.SearchEntities', N'P') IS NOT NULL
BEGIN
    PRINT N'Dropping stored procedure dbo.SearchEntities...';
    DROP PROC dbo.SearchEntities;
END
GO

PRINT N'Creating stored procedure dbo.SearchEntities...';
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
            CAST(0 AS INT) AS rank_score,
            CAST(0 AS INT) AS score
        FROM dbo.Entities AS e
        WHERE (@type IS NULL OR e.type = @type)
        ORDER BY e.name;
        RETURN;
    END

    DECLARE @fts NVARCHAR(4000) = N'';

    SELECT @fts = @fts
                 + CASE WHEN LEN(@fts) = 0 THEN N'' ELSE N' AND ' END
                 + N'"' + REPLACE(value, '"', '""') + N'*"'
    FROM STRING_SPLIT(@normalized, N' ', 1)
    WHERE value <> N'';

    IF @fts = N''
    BEGIN
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
        h.rank_score,
        h.rank_score
            + CASE WHEN e.name = @normalized THEN 1000
                   WHEN e.name LIKE @normalized + N'%' THEN 200
                   WHEN e.name LIKE N'% ' + @normalized + N'%' THEN 50
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

PRINT N'Full-text configuration complete.';
