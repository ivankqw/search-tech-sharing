:setvar TargetDb SearchDemo

USE $(TargetDb);
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

    DECLARE @filler TABLE (token NVARCHAR(32) PRIMARY KEY);
    INSERT INTO @filler (token)
    VALUES
        (N'the'),
        (N'and'),
        (N'co'),
        (N'coo'),
        (N'company'),
        (N'corp'),
        (N'corporation'),
        (N'group'),
        (N'holdings'),
        (N'inc'),
        (N'incorporated'),
        (N'llc'),
        (N'ltd'),
        (N'limited'),
        (N'plc'),
        (N'sa'),
        (N'sas'),
        (N'spa'),
        (N'ag'),
        (N'gmbh'),
        (N'bv'),
        (N'sarl'),
        (N'de'),
        (N'la');

    DECLARE @split TABLE
    (
        ordinal INT PRIMARY KEY,
        token   NVARCHAR(100)
    );
    DECLARE @raw_tokens TABLE
    (
        ordinal INT PRIMARY KEY,
        token   NVARCHAR(100)
    );
    DECLARE @tokens TABLE
    (
        ordinal INT PRIMARY KEY,
        token   NVARCHAR(100)
    );

    INSERT INTO @split (ordinal, token)
    SELECT
        ROW_NUMBER() OVER (ORDER BY ordinal) AS ordinal,
        LOWER(value) AS token
    FROM STRING_SPLIT(@sanitized, N' ', 1)
    WHERE value IS NOT NULL AND value <> N'';

    INSERT INTO @raw_tokens (ordinal, token)
    SELECT s.ordinal, s.token
    FROM @split AS s;

    INSERT INTO @tokens (ordinal, token)
    SELECT s.ordinal, s.token
    FROM @split AS s
    WHERE LEN(s.token) >= 3
      AND NOT EXISTS (SELECT 1 FROM @filler AS f WHERE f.token = s.token);

    SELECT TOP (1) @first_token = token
    FROM @raw_tokens
    ORDER BY ordinal;

    DECLARE @required NVARCHAR(100) = (
        SELECT TOP (1) token
        FROM @tokens
        ORDER BY ordinal
    );

    IF @required IS NULL
    BEGIN
        SET @required = @first_token;
    END;

    DECLARE @optional NVARCHAR(4000) = NULL;
    SELECT @optional = STRING_AGG(N'"' + REPLACE(token, '"', '""') + N'*"', N' OR ')
    FROM @tokens
    WHERE token IS NOT NULL
      AND token <> @required;

    IF @required IS NOT NULL
    BEGIN
        SET @fts = N'"' + REPLACE(@required, '"', '""') + N'*"';
        IF @optional IS NOT NULL
        BEGIN
            SET @fts = @fts + N' AND (' + @optional + N')';
        END;
    END

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

PRINT N'Full-text configuration complete.';
