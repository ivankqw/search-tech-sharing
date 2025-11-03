Companies
- PowerApps.LastCompanyEnriched
- Relevant columns
    - CompanyID (int PK)
    - CompanyName (varchar)
    - Country (varchar)
    - Continent (varchar)
    - PrimaryIndustry (varchar)
    - BusinessDescription (varchar)
    - Website (varchar)

Investors
- Staging.InvestorsComputed
- Relevant columns
    - Investor (name, in varchar)
    - PBID (varchar PK. if PBID not available then the PK is investor)

Funds
- PowerApps.FundStatic
- Relevant columns
    - investor_id (fk references InvestorsComputed PBID)
    - fund_name (varchar, PK)

Person
- PowerApps.PersonAgg
- Relevant columns
    - CURRENT_COMPANY_ID (fk references LastCompanyEnriched CompanyID)
    - PERSON_ID (nvarchar)
    - FIRST_NAME (nvarchar)
    - LAST_NAME (nvarchar)
    - FULL_NAME (nvarchar)
    - LINKEDIN_URL (nvarchar)
    - TWITTER_URL (nvarchar)
    - GITHUB_URL (nvarchar)
    - CURRENT_POSITION_COMPANY_NAME (nvarchar)
    - CURRENT_POSITION_COMPANY_DOMAIN (nvarchar)