:setvar TargetDb SearchDemo

USE $(TargetDb);
GO

IF OBJECT_ID(N'dbo.Entities', N'U') IS NOT NULL
BEGIN
    PRINT N'Dropping existing table dbo.Entities...';
    DROP TABLE dbo.Entities;
END;
GO

PRINT N'Creating table dbo.Entities...';
CREATE TABLE dbo.Entities
(
    id         BIGINT IDENTITY(1,1) NOT NULL,
    type       VARCHAR(20) NOT NULL,
    name       NVARCHAR(256) NOT NULL,
    alt_names  NVARCHAR(MAX) NULL,
    country    VARCHAR(64) NULL,
    created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Entities PRIMARY KEY CLUSTERED (id)
);
GO

PRINT N'Loading companies from PowerApps.LastCompanyEnriched...';
INSERT INTO dbo.Entities (type, name, alt_names, country)
SELECT
    'company' AS type,
    LEFT(LTRIM(RTRIM(CONVERT(NVARCHAR(256), CompanyName))), 256) AS name,
    NULLIF(CONCAT_WS(N' ',
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), BusinessDescription))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(512), Website))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(256), PrimaryIndustry))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), Continent))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(64), Country))), N''),
                     N'CompanyID=' + CONVERT(NVARCHAR(32), CompanyID)
            ), N'') AS alt_names,
    NULLIF(LTRIM(RTRIM(CONVERT(VARCHAR(64), Country))), '') AS country
FROM PowerApps.LastCompanyEnriched
WHERE CompanyName IS NOT NULL
  AND LTRIM(RTRIM(CompanyName)) <> '';
GO

PRINT N'Loading investors from Staging.InvestorsComputed...';
INSERT INTO dbo.Entities (type, name, alt_names, country)
SELECT
    'investor' AS type,
    LEFT(LTRIM(RTRIM(CONVERT(NVARCHAR(256), Investor))), 256) AS name,
    NULLIF(CONCAT_WS(N' ',
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), PBID))), N'')
            ), N'') AS alt_names,
    NULL AS country
FROM Staging.InvestorsComputed
WHERE Investor IS NOT NULL
  AND LTRIM(RTRIM(Investor)) <> '';
GO

PRINT N'Loading funds from PowerApps.FundStatic...';
INSERT INTO dbo.Entities (type, name, alt_names, country)
SELECT
    'fund' AS type,
    LEFT(LTRIM(RTRIM(CONVERT(NVARCHAR(256), fund_name))), 256) AS name,
    NULLIF(CONCAT_WS(N' ',
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), investor_id))), N'')
            ), N'') AS alt_names,
    NULL AS country
FROM PowerApps.FundStatic
WHERE fund_name IS NOT NULL
  AND LTRIM(RTRIM(fund_name)) <> '';
GO

PRINT N'Loading people from PowerApps.PersonAgg...';
INSERT INTO dbo.Entities (type, name, alt_names, country)
SELECT
    'person' AS type,
    LEFT(CONVERT(NVARCHAR(256), person_name.normalized_name), 256) AS name,
    NULLIF(CONCAT_WS(N' ',
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), FIRST_NAME))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(128), LAST_NAME))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(256), LINKEDIN_URL))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(256), TWITTER_URL))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(256), GITHUB_URL))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(256), CURRENT_POSITION_COMPANY_NAME))), N''),
                     NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(256), CURRENT_POSITION_COMPANY_DOMAIN))), N''),
                     NULLIF(CONVERT(NVARCHAR(64), CURRENT_COMPANY_ID), N''),
                     NULLIF(CONVERT(NVARCHAR(64), PERSON_ID), N'')
            ), N'') AS alt_names,
    NULL AS country
FROM PowerApps.PersonAgg
CROSS APPLY
(
    SELECT
        COALESCE(
            NULLIF(LTRIM(RTRIM(FULL_NAME)), N''),
            NULLIF(
                LTRIM(RTRIM(CONCAT_WS(N' ',
                    NULLIF(LTRIM(RTRIM(FIRST_NAME)), N''),
                    NULLIF(LTRIM(RTRIM(LAST_NAME)), N'')
                ))),
                N''
            )
        ) AS normalized_name
) AS person_name
WHERE person_name.normalized_name IS NOT NULL;
GO

PRINT N'Creating supporting indexes...';
CREATE INDEX IX_Entities_Type ON dbo.Entities (type);
CREATE INDEX IX_Entities_Name ON dbo.Entities (name);
GO

DECLARE @total BIGINT = (SELECT COUNT_BIG(*) FROM dbo.Entities);
PRINT N'Total entities inserted: ' + CONVERT(NVARCHAR(30), @total);
