USE SearchDemo;
GO

IF OBJECTPROPERTY(OBJECT_ID(N'dbo.RawCompanies'), N'IsUserTable') = 1
BEGIN
    DROP TABLE dbo.RawCompanies;
END;

DECLARE @sourceFile NVARCHAR(4000) = N'/data/free_company_dataset_clean.tsv';
DECLARE @fileCheck TABLE (FileExists INT, IsDirectory INT, ParentDirExists INT);
INSERT INTO @fileCheck EXEC master.dbo.xp_fileexist @sourceFile;

IF NOT EXISTS (SELECT 1 FROM @fileCheck WHERE FileExists = 1 AND IsDirectory = 0)
BEGIN
    SET @sourceFile = N'/data/free_company_dataset.csv';
END

DECLARE @errorFile NVARCHAR(4000) = N'/tmp/free_company_bulk_'
    + REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(30), SYSDATETIME(), 126), '-', ''), ':', ''), 'T', '')
    + N'.err';

PRINT N'Using source file: ' + @sourceFile;

PRINT N'Creating staging table dbo.RawCompanies...';
CREATE TABLE dbo.RawCompanies
(
    country        NVARCHAR(256) NULL,
    year_founded   NVARCHAR(32) NULL,
    source_id      NVARCHAR(256) NULL,
    industry       NVARCHAR(MAX) NULL,
    linkedin_url   NVARCHAR(MAX) NULL,
    locality       NVARCHAR(MAX) NULL,
    company_name   NVARCHAR(MAX) NULL,
    region         NVARCHAR(MAX) NULL,
    size_range     NVARCHAR(64) NULL,
    website        NVARCHAR(MAX) NULL
);

DECLARE @bulkSql NVARCHAR(MAX) = N'
    BULK INSERT dbo.RawCompanies
    FROM ''' + REPLACE(@sourceFile, '''', '''''') + N'''
    WITH (
        FIRSTROW = 2,
        FIELDTERMINATOR = ''\t'',
        ROWTERMINATOR = ''\n'',
        TABLOCK,
        MAXERRORS = 1000,
        ERRORFILE = ''' + REPLACE(@errorFile, '''', '''''') + N'''
    );';

PRINT N'Loading data from ' + @sourceFile + N' into dbo.RawCompanies...';
PRINT N'Bulk insert errors will be logged to: ' + @errorFile;
EXEC(@bulkSql);

DECLARE @rowcount BIGINT = (SELECT COUNT(*) FROM dbo.RawCompanies);
PRINT N'Loaded ' + CONVERT(NVARCHAR(30), @rowcount) + N' rows into dbo.RawCompanies.';

PRINT N'Replacing contents of dbo.Entities with normalized company data...';
TRUNCATE TABLE dbo.Entities;

INSERT INTO dbo.Entities (type, name, alt_names, country)
SELECT
    'company' AS type,
    LEFT(LTRIM(RTRIM(company_name)), 256) AS name,
    NULLIF(CONCAT_WS(N' ',
                     NULLIF(LTRIM(RTRIM(website)), N''),
                     NULLIF(LTRIM(RTRIM(linkedin_url)), N''),
                     NULLIF(LTRIM(RTRIM(locality)), N''),
                     NULLIF(LTRIM(RTRIM(region)), N''),
                     NULLIF(LTRIM(RTRIM(industry)), N''),
                     NULLIF(LTRIM(RTRIM(size_range)), N''),
                     NULLIF(LTRIM(RTRIM(year_founded)), N''),
                     NULLIF(LTRIM(RTRIM(source_id)), N'')),
           N'') AS alt_names,
    NULLIF(LTRIM(RTRIM(country)), N'') AS country
FROM dbo.RawCompanies
WHERE company_name IS NOT NULL AND company_name <> N'';

DECLARE @inserted BIGINT = @@ROWCOUNT;
PRINT N'Inserted ' + CONVERT(NVARCHAR(30), @inserted) + N' rows into dbo.Entities.';

PRINT N'Dropping staging table dbo.RawCompanies...';
DROP TABLE dbo.RawCompanies;

PRINT N'Load complete.';
