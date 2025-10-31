:setvar SampleSize 6000000

USE SearchDemo;
GO

DECLARE @SampleSize BIGINT = $(SampleSize);
IF @SampleSize IS NULL OR @SampleSize <= 0
BEGIN
    SET @SampleSize = 6000000;
END;

IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'dbo.Entities'))
BEGIN
    PRINT N'Dropping existing full-text index on dbo.Entities before sampling...';
    DROP FULLTEXT INDEX ON dbo.Entities;
END;

IF EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ft_main')
BEGIN
    PRINT N'Dropping full-text catalog ft_main before sampling...';
    DROP FULLTEXT CATALOG ft_main;
END;

DECLARE @total BIGINT = (SELECT COUNT_BIG(*) FROM dbo.Entities);
PRINT N'Current row count: ' + CONVERT(NVARCHAR(30), @total);

IF @total <= @SampleSize
BEGIN
    PRINT N'Row count is already within sample size; nothing to do.';
    RETURN;
END;

IF OBJECT_ID(N'tempdb..#keep_ids') IS NOT NULL
BEGIN
    DROP TABLE #keep_ids;
END;

PRINT N'Selecting sample of ' + CONVERT(NVARCHAR(30), @SampleSize) + N' rows...';

WITH ranked AS
(
    SELECT
        id,
        ROW_NUMBER() OVER (ORDER BY CHECKSUM(name, COALESCE(country, N''), id)) AS rn
    FROM dbo.Entities WITH (NOLOCK)
)
SELECT id
INTO #keep_ids
FROM ranked
WHERE rn <= @SampleSize;

DECLARE @kept BIGINT = (SELECT COUNT_BIG(*) FROM #keep_ids);
PRINT N'Rows selected: ' + CONVERT(NVARCHAR(30), @kept);

IF @kept = 0
BEGIN
    RAISERROR (N'No rows were selected for the sample; aborting.', 16, 1);
END;

PRINT N'Deleting rows outside the sample...';
DELETE e
FROM dbo.Entities AS e
LEFT JOIN #keep_ids AS k
    ON e.id = k.id
WHERE k.id IS NULL;

DECLARE @remaining BIGINT = (SELECT COUNT_BIG(*) FROM dbo.Entities);
PRINT N'Remaining rows after sampling: ' + CONVERT(NVARCHAR(30), @remaining);

IF @remaining <> @kept
BEGIN
    PRINT N'Warning: mismatch between selected count and remaining count.';
END;

PRINT N'Sample creation complete.';
GO
