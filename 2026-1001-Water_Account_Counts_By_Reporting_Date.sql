/******************************************************************************
Author:        Teo Espero, IT Administrator
Organization:  Marina Coast Water District (MCWD)
Title:         Water Account Counts by Reporting Date
Revision Date: 2026-10-13
Version:       1.6

PURPOSE
  Count distinct date-qualified accounts by ST Category at user-entered cutoff dates.
  Supports fiscal years, calendar years, or other dated inventory comparisons.

REVISION HISTORY
  1.0  2026-10-13  Teo Espero  Established multi-year account date selection.
  1.1  2026-10-13  Teo Espero  Added period columns and Irrigation -> Landscape.
  1.2  2026-10-13  Teo Espero  Added reconciliation totals and account details.
  1.3  2026-10-13  Teo Espero  Standardized Multi Family capitalization.
  1.4  2026-10-13  Teo Espero  Added per-period labels and cutoff dates.
  1.5  2026-10-13  Teo Espero  Added selected meter size to details.
  1.6  2026-10-13  Teo Espero  Added full documentation; logic unchanged.

  History above covers this summary script's development in this session.
  The broader reporting code lineage dates to 2021; earlier version details
  are not reconstructed here.

USER SETTINGS
  Edit @ReportingPeriods: PeriodID orders columns, PeriodLabel names each column,
  and EndDate sets its cutoff. Labels and IDs must be unique.
  Example fiscal period:   (1, N'FY2025', '2025-06-30')
  Example calendar period: (2, N'CY2025', '2025-12-31')
  Keep each period label consistent with its actual cutoff date.
  Set @DetailPeriodID to an ID in the list for result sets 2 and 3.

SOURCE TABLES (Springbrook0.dbo)
  lot             Lot number, ST Category (misc_2), Connection Type (misc_16), address.
  ub_meter_con    Meter-to-lot link, install/remove dates, connection ID and status.
  ub_device       Device identity, serial number, and device type link.
  ub_master       Customer/sequence identity, account dates, and current status.
  ub_device_type  Selected meter size for the detail output.

CATEGORY AND ELIGIBILITY RULES
  Irrigation in lot.misc_16 becomes Landscape, overriding the original category.
  Multi Family capitalization variations become Multi Family.
  Blank/NULL categories become Unspecified; other category text is retained.
  Exclude addresses containing SEWER, HYDRANT, or DELETED.
  Exclude device serial numbers containing -S or HYDRANT.
  The -S comparison follows the database collation's case sensitivity.
  NULL serial numbers are allowed; the device record itself must exist.
  Bay View and recycled-water lots remain included.
  These inherited exclusions are not an authoritative water-service definition.

COUNTING AND DATE RULES
  * One distinct customer/sequence pair per period and ST Category.
  * All date-qualified accounts are considered; no one-account-per-lot limit.
  * Account connection and meter installation dates include the entire cutoff day.
  * Account final and meter removal calendar dates must be later than the cutoff,
    or NULL. Closing/removal on the cutoff day is excluded.
  * NULL connection/installation dates do not qualify.
  * Blank final dates can allow obsolete accounts to qualify; review overlapping
    accounts and incomplete records before accepting official totals.
  * CurrentAccountStatus is displayed only; it does not determine eligibility.
  * MeterSize is from one qualifying meter on the account's lot. Current Active
    meter status is preferred for display, followed by highest connection ID.
    This display preference does not change which accounts are counted.
  * MeterSize may be NULL when device type/size information is missing.

RESULT SETS
  1. ST_Category rows and reporting-period columns; missing combinations = 0.
  2. Selected-period category sum, distinct account count, and distinct lot count.
     An account assigned to multiple categories can make the category sum exceed
     the distinct account count.
  3. Selected-period account records, dates, current status, and meter size.
     Multiple stored records can make detail rows exceed distinct account totals.

HISTORICAL LIMITS
  Dates come from currently stored records; this does not restore a database
  snapshot. Later corrections can change past-period counts.
  Categories, addresses, and connection types are current lot attributes.
  Meter eligibility is linked through lot_no, not an account-specific service.
  The full-day date checks differ from the original inventory midnight checks.

EXECUTION
  Run the complete script as one batch in SQL Server 2016+ with permission to
  read the source tables. Do not insert GO before the dynamic summary.
  Only session temporary tables are written; source tables are not changed.
  Period columns are assembled from integer IDs and QUOTENAME-protected labels.
  Empty datasets return no category rows, with zero control totals where provided.
  These documentation edits do not change executable SQL. No database execution
  was performed during documentation review.
******************************************************************************/
-- Suppress row-count messages; return the requested result sets only.
SET NOCOUNT ON;

-- PeriodID controls the column order. Labels must be unique.
DECLARE @ReportingPeriods TABLE (
    PeriodID INT PRIMARY KEY,
    PeriodLabel NVARCHAR(100) NOT NULL UNIQUE,
    EndDate DATE NOT NULL
);
-- STEP 1: Enter the periods to compare. EndDate is an as-of cutoff, not a range.
INSERT INTO @ReportingPeriods (PeriodID, PeriodLabel, EndDate)
VALUES
    (1,  N'FY2017', '2017-06-30'),
    (2,  N'FY2018', '2018-06-30'),
    (3,  N'FY2019', '2019-06-30'),
    (4,  N'FY2020', '2020-06-30'),
    (5,  N'FY2021', '2021-06-30'),
    (6,  N'FY2022', '2022-06-30'),
    (7,  N'FY2023', '2023-06-30'),
    (8,  N'FY2024', '2024-06-30'),
    (9,  N'FY2025', '2025-06-30'),
    (10, N'FY2026', '2026-06-30');

-- Calendar-year example: (11, N'CY2025', '2025-12-31')
-- Mixed fiscal/calendar periods are allowed with separate IDs and labels.
-- Choose one PeriodID from the list for reconciliation and account details.
DECLARE @DetailPeriodID INT = 10;

-- STEP 2: Validate settings before building any report data.
IF NOT EXISTS (SELECT 1 FROM @ReportingPeriods)
    THROW 50001, 'Enter at least one reporting period.', 1;
IF EXISTS (SELECT 1 FROM @ReportingPeriods WHERE LTRIM(RTRIM(PeriodLabel)) = '')
    THROW 50002, 'Period labels cannot be blank.', 1;
IF EXISTS (SELECT 1 FROM @ReportingPeriods WHERE EndDate = '9999-12-31')
    THROW 50003, 'Cutoff must be earlier than 9999-12-31.', 1;
IF NOT EXISTS (SELECT 1 FROM @ReportingPeriods WHERE PeriodID = @DetailPeriodID)
    THROW 50004, 'Choose a detail PeriodID from the reporting-period list.', 1;

-- Clear temporary results left by an earlier run in this SQL session.
DROP TABLE IF EXISTS #EligibleAccountDetails;
DROP TABLE IF EXISTS #EligibleAccounts;

-- STEP 3: Combine entered periods with normalized current lot attributes.
;WITH YearEnds AS (
    SELECT PeriodID, PeriodLabel, EndDate AS AsOfDate
    FROM @ReportingPeriods
), LotData AS (
    SELECT l.lot_no, l.misc_2 AS OriginalSTCategory,
           l.misc_16 AS ConnectionType,
-- Irrigation takes precedence over the stored ST Category.
           CASE
               WHEN UPPER(LTRIM(RTRIM(ISNULL(l.misc_16, '')))) = 'IRRIGATION'
                   THEN 'Landscape'
               WHEN UPPER(LTRIM(RTRIM(ISNULL(l.misc_2, '')))) = 'MULTI FAMILY'
                   THEN 'Multi Family'
               ELSE COALESCE(NULLIF(LTRIM(RTRIM(l.misc_2)), ''), 'Unspecified')
           END AS ST_Category,
           LTRIM(RTRIM(
               COALESCE(CAST(l.street_number AS VARCHAR(20)), '') + ' ' +
               COALESCE(l.street_directional, '') + ' ' +
               COALESCE(l.street_name, '') +
               CASE WHEN NULLIF(LTRIM(RTRIM(l.addr_2)), '') IS NOT NULL
                    THEN ' ' + l.addr_2 ELSE '' END
           )) AS ServiceAddress
    FROM Springbrook0.dbo.lot l
)
SELECT DISTINCT
       y.PeriodID, y.PeriodLabel, y.AsOfDate, l.ST_Category,
       um.cust_no, um.cust_sequence, um.ub_master_id, um.lot_no,
       um.connect_date, um.final_date, um.acct_status AS CurrentAccountStatus,
       l.OriginalSTCategory, l.ConnectionType, l.ServiceAddress,
       selected_meter.MeterSize
-- Materialize qualifying records so summary and detail use the same data.
INTO #EligibleAccountDetails
FROM YearEnds y
INNER JOIN Springbrook0.dbo.ub_master um
    ON um.connect_date < DATEADD(DAY, 1, y.AsOfDate)
   AND (um.final_date IS NULL
        OR CONVERT(DATE, um.final_date) > y.AsOfDate)
INNER JOIN LotData l ON l.lot_no = um.lot_no
-- Pick one date-qualified meter for display only; this does not change
-- account eligibility. Prefer current Active status, then highest connection ID,
-- matching the original inventory ranking among eligible meters.
OUTER APPLY (
    SELECT TOP (1) udt.device_size AS MeterSize
    FROM Springbrook0.dbo.ub_meter_con mc
    INNER JOIN Springbrook0.dbo.ub_device ud
        ON ud.ub_device_id = mc.ub_device_id
    LEFT JOIN Springbrook0.dbo.ub_device_type udt
        ON udt.ub_device_type_id = ud.ub_device_type_id
    WHERE mc.lot_no = um.lot_no
      AND mc.ub_meter_con_id IS NOT NULL
      AND mc.install_date < DATEADD(DAY, 1, y.AsOfDate)
      AND (mc.remove_date IS NULL
           OR CONVERT(DATE, mc.remove_date) > y.AsOfDate)
      AND ISNULL(ud.serial_no, '') NOT LIKE '%-S%'
      AND UPPER(ISNULL(ud.serial_no, '')) NOT LIKE '%HYDRANT%'
    ORDER BY CASE WHEN mc.con_status = 'Active' THEN 1 ELSE 3 END,
             mc.ub_meter_con_id DESC
) selected_meter
WHERE um.cust_no IS NOT NULL
  AND um.cust_sequence IS NOT NULL
  AND UPPER(ISNULL(l.ServiceAddress, '')) NOT LIKE '%SEWER%'
  AND UPPER(ISNULL(l.ServiceAddress, '')) NOT LIKE '%HYDRANT%'
  AND UPPER(ISNULL(l.ServiceAddress, '')) NOT LIKE '%DELETED%'
-- EXISTS checks eligibility without adding a row for every meter on the lot.
  AND EXISTS (
      SELECT 1
      FROM Springbrook0.dbo.ub_meter_con mc
      INNER JOIN Springbrook0.dbo.ub_device ud
          ON ud.ub_device_id = mc.ub_device_id
      WHERE mc.lot_no = um.lot_no
        AND mc.ub_meter_con_id IS NOT NULL
        AND mc.install_date < DATEADD(DAY, 1, y.AsOfDate)
        AND (mc.remove_date IS NULL
             OR CONVERT(DATE, mc.remove_date) > y.AsOfDate)
        AND ISNULL(ud.serial_no, '') NOT LIKE '%-S%'
        AND UPPER(ISNULL(ud.serial_no, '')) NOT LIKE '%HYDRANT%'
  );

-- Preserve the summary's original distinct-account/category counting rules.
SELECT DISTINCT PeriodID, AsOfDate, ST_Category, cust_no, cust_sequence
INTO #EligibleAccounts
FROM #EligibleAccountDetails;

-- Result 1: ST Category in rows, selected reporting periods in columns.
-- Dynamic columns follow the period list, ordered by PeriodID.
-- Missing category/period combinations display zero.
DECLARE @YearColumns NVARCHAR(MAX);
DECLARE @SummarySQL NVARCHAR(MAX);

-- STEP 4: Build one numeric summary column per period in PeriodID order.
-- FOR XML handles string assembly; QUOTENAME protects column identifiers.
SELECT @YearColumns = STUFF((
    SELECT ', SUM(CASE WHEN PeriodID = ' + CAST(PeriodID AS VARCHAR(11)) +
           ' THEN AccountCount ELSE CAST(0 AS BIGINT) END) AS ' +
           QUOTENAME(PeriodLabel)
    FROM @ReportingPeriods
    ORDER BY PeriodID
    FOR XML PATH(''), TYPE
).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

SET @SummarySQL = N'
;WITH Counts AS (
    SELECT PeriodID, ST_Category, COUNT_BIG(*) AS AccountCount
    FROM #EligibleAccounts
    GROUP BY PeriodID, ST_Category
)
SELECT ST_Category, ' + @YearColumns + N'
FROM Counts
GROUP BY ST_Category
ORDER BY ST_Category;';

-- Dynamic SQL can read the session temporary table created above.
EXEC sys.sp_executesql @SummarySQL;

-- Result 2: controls for the selected reconciliation period.
-- Compare the distinct total with the sum of category counts. A difference
-- means an account occurs under more than one category and needs review.
SELECT p.PeriodID, p.PeriodLabel, p.EndDate AS ReportingEndDate,
       (SELECT COUNT_BIG(*) FROM #EligibleAccounts
        WHERE PeriodID = @DetailPeriodID) AS SumOfCategoryCounts,
       (SELECT COUNT_BIG(*) FROM (
            SELECT DISTINCT cust_no, cust_sequence
            FROM #EligibleAccounts WHERE PeriodID = @DetailPeriodID
        ) a) AS DistinctAccountCount,
       (SELECT COUNT_BIG(*) FROM (
            SELECT DISTINCT lot_no
            FROM #EligibleAccountDetails WHERE PeriodID = @DetailPeriodID
        ) l) AS DistinctLotCount
FROM @ReportingPeriods p
WHERE p.PeriodID = @DetailPeriodID;

-- Result 3: export this result to Excel for account-by-account comparison.
-- Multiple rows for an account are retained if stored master/lot records
-- differ, so the raw detail row count need not equal the distinct total.
SELECT PeriodID, PeriodLabel, AsOfDate AS ReportingEndDate,
       RIGHT('000000' + CAST(cust_no AS VARCHAR(6)), 6) + '-' +
       RIGHT('000' + CAST(cust_sequence AS VARCHAR(3)), 3) AS AccountNumber,
       cust_no, cust_sequence, lot_no AS LotNo, ub_master_id,
       ST_Category, OriginalSTCategory, ConnectionType, ServiceAddress,
       connect_date AS AccountStartDate, final_date AS AccountEndDate,
       CurrentAccountStatus, MeterSize
FROM #EligibleAccountDetails
WHERE PeriodID = @DetailPeriodID
ORDER BY lot_no, cust_no, cust_sequence, ub_master_id;

-- Final cleanup affects only this session's temporary report tables.
DROP TABLE #EligibleAccounts;
DROP TABLE #EligibleAccountDetails;
