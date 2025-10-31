USE master;
GO

IF DB_ID(N'SearchDemo') IS NULL
BEGIN
    PRINT N'Creating database SearchDemo...';
    CREATE DATABASE SearchDemo;
END
GO

ALTER DATABASE SearchDemo SET RECOVERY SIMPLE;
GO

USE SearchDemo;
GO

IF OBJECTPROPERTY(OBJECT_ID(N'dbo.Entities'), N'IsUserTable') = 1
BEGIN
    PRINT N'Dropping existing table dbo.Entities...';
    DROP TABLE dbo.Entities;
END
GO

PRINT N'Creating table dbo.Entities...';
CREATE TABLE dbo.Entities
(
    id        BIGINT IDENTITY(1,1) CONSTRAINT PK_Entities PRIMARY KEY,
    type      VARCHAR(20) NOT NULL,
    name      NVARCHAR(256) NOT NULL,
    alt_names NVARCHAR(MAX) NULL,
    country   VARCHAR(64) NULL,
    created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

DECLARE @SeedSynthetic INT = $(SeedSynthetic);

IF @SeedSynthetic = 1
BEGIN
    PRINT N'Populating dbo.Entities with synthetic sample data (1,000,000 rows)...';
    ;WITH numbers AS
    (
        SELECT TOP (1000000)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects AS a
        CROSS JOIN sys.all_objects AS b
    )
    INSERT INTO dbo.Entities (type, name, alt_names, country)
    SELECT
        CASE (n % 4)
             WHEN 0 THEN 'company'
             WHEN 1 THEN 'person'
             WHEN 2 THEN 'fund'
             ELSE 'investor'
        END
      AS type,
        CONCAT(N'Acme ',
               CHOOSE((n % 5) + 1,
                      N'Ventures',
                      N'Capital',
                      N'Holdings',
                      N'Partners',
                      N'International'),
               N' ',
               n)
      AS name,
        CONCAT(N'Acme ',
               CHOOSE(((n + 1) % 5) + 1,
                      N'Venture Capital',
                      N'Investments',
                      N'Holdings Group',
                      N'Partners LLC',
                      N'International Ltd'),
               N' ',
               n)
      AS alt_names,
        CHOOSE((n % 5) + 1, 'US', 'GB', 'DE', 'SG', 'AU') AS country
    FROM numbers;
END
ELSE
BEGIN
    PRINT N'Skipping synthetic data load (SeedSynthetic = 0).';
END;
GO

CREATE INDEX IX_Entities_Type ON dbo.Entities (type);
GO

CREATE INDEX IX_Entities_Name ON dbo.Entities (name);
GO

PRINT N'Setup complete.';
