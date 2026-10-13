/******************************************************************************
Author:        Teo Espero, IT Administrator
Organization:  Marina Coast Water District (MCWD)
Title:         Meter Inventory by Reporting Date
Revision Date: 2026-10-13
Version:       1.3

PURPOSE
  Count lots with date-qualified meters by ST Category at user-entered cutoff dates.
  Supports fiscal years, calendar years, or other dated inventory comparisons.

REVISION HISTORY
  1.0  2026-10-13  Teo Espero  Added multi-year lot inventory summary with
                               original meter eligibility and category mapping.
  1.1  2026-10-13  Teo Espero  Added per-period labels, cutoff dates, and totals.
  1.2  2026-10-13  Teo Espero  Added full documentation; logic unchanged.
  1.3  2026-10-13  Teo Espero  Added selected-period meter details and sizes.
                               Summary eligibility and counting unchanged.

  History above covers this summary script's development in this session.
  The broader reporting code lineage dates to 2021; earlier version details
  are not reconstructed here.

USER SETTINGS
  Edit @ReportingPeriods: PeriodID orders columns, PeriodLabel names each column,
  and EndDate sets its cutoff. Labels and IDs must be unique.
  Example fiscal period:   (1, N'FY2025', '2025-06-30')
  Example calendar period: (2, N'CY2025', '2025-12-31')
  Keep each period label consistent with its actual cutoff date.
  Control totals include every period in the list.
  Set @DetailPeriodID to the period whose meter details you want to export.

SOURCE TABLES (Springbrook0.dbo)
  lot             Lot number, ST Category (misc_2), Connection Type (misc_16), address.
  ub_meter_con    Meter-to-lot link, install/remove dates, connection ID and status.
  ub_device       Device identity, serial number, and device type link.
  ub_device_type  Selected meter size, manufacturer, and model.

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
  * One distinct lot/category combination per reporting period.
  * No account date, account status, or active lot status requirement.
  * Multiple qualifying meters on a lot do not multiply the lot count.
  * install_date <= cutoff and remove_date > cutoff (or NULL) are retained
    exactly from the original inventory report. If columns contain times, the
    DATE cutoff is midnight, unlike the account summary's calendar-day checks.
  * NULL installation dates do not qualify.
  * A lot can qualify without an open account or with an inactive meter status.
  * This is a qualifying-lot inventory, not a physical meter or active-account count.

RESULT SETS
  1. ST_Category rows and reporting-period columns; missing combinations = 0.
  2. Each period's exact cutoff and distinct qualifying-lot total, including zero.
     Conflicting lot categories can make the category sum exceed distinct lots.
  3. Selected-period lots with one selected qualifying meter, size, serial,
     manufacturer, model, install/remove dates, and current connection status.
     Active status is preferred for display, then highest connection ID.
     NULL meter type information is retained. This is not every meter on a lot.

HISTORICAL LIMITS
  Dates come from currently stored records; this does not restore a database
  snapshot. Later corrections can change past-period counts.
  Categories, addresses, and connection types are current lot attributes.
  Meter eligibility is linked through lot_no, not an account-specific service.
  Use the account summary when the intended measure is date-qualified accounts.

EXECUTION
  Run the complete script as one batch in SQL Server 2016+ with permission to
  read the source tables. Do not insert GO before the dynamic summary.
  Only session temporary tables are written; source tables are not changed.
  Period columns are assembled from integer IDs and QUOTENAME-protected labels.
  Empty datasets return no category rows, with zero control totals where provided.
  Summary counting is unchanged by the detail addition. This version was
  reviewed locally but has not been executed against Springbrook.
******************************************************************************/
-- Suppress row-count messages; return the requested result sets only.
SET NOCOUNT ON;
-- Edit this list. PeriodID controls the column order.
-- Labels must be unique. Fiscal and calendar periods can be mixed.
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

-- Calendar-year example: (1, N'CY2025', '2025-12-31')
-- For both: use separate IDs/labels for FY2025 and CY2025.
-- Choose the PeriodID for result set 3 (10 = FY2026 in the default list).
DECLARE @DetailPeriodID INT = 10;

-- STEP 2: Validate settings before building any report data.
IF NOT EXISTS (SELECT 1 FROM @ReportingPeriods)
    THROW 50001, 'Enter at least one reporting period.', 1;
IF EXISTS (SELECT 1 FROM @ReportingPeriods WHERE LTRIM(RTRIM(PeriodLabel)) = '')
    THROW 50002, 'Period labels cannot be blank.', 1;
IF NOT EXISTS (SELECT 1 FROM @ReportingPeriods WHERE PeriodID = @DetailPeriodID)
    THROW 50003, 'Choose a detail PeriodID from the reporting-period list.', 1;

-- Clear temporary results left by an earlier run in this SQL session.
DROP TABLE IF EXISTS #Inventory;
-- STEP 3: Combine entered periods with normalized current lot attributes.
;WITH YearEnds AS (
    SELECT PeriodID, EndDate AS AsOfDate
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
SELECT DISTINCT y.PeriodID, y.AsOfDate, l.lot_no, l.ST_Category
-- Materialize qualifying records so summary and detail use the same data.
INTO #Inventory
FROM YearEnds y
CROSS JOIN LotData l
WHERE UPPER(ISNULL(l.ServiceAddress, '')) NOT LIKE '%SEWER%'
  AND UPPER(ISNULL(l.ServiceAddress, '')) NOT LIKE '%HYDRANT%'
  AND UPPER(ISNULL(l.ServiceAddress, '')) NOT LIKE '%DELETED%'
-- EXISTS checks eligibility without adding a row for every meter on the lot.
  AND EXISTS (
      SELECT 1
      FROM Springbrook0.dbo.ub_meter_con mc
      INNER JOIN Springbrook0.dbo.ub_device ud
          ON ud.ub_device_id = mc.ub_device_id
      WHERE mc.lot_no = l.lot_no
        AND mc.ub_meter_con_id IS NOT NULL
        AND mc.install_date <= y.AsOfDate
        AND (mc.remove_date IS NULL OR mc.remove_date > y.AsOfDate)
        AND ISNULL(ud.serial_no, '') NOT LIKE '%-S%'
        AND UPPER(ISNULL(ud.serial_no, '')) NOT LIKE '%HYDRANT%'
  );

DECLARE @YearColumns NVARCHAR(MAX), @SummarySQL NVARCHAR(MAX);
-- STEP 4: Build one numeric summary column per period in PeriodID order.
-- FOR XML handles string assembly; QUOTENAME protects column identifiers.
SELECT @YearColumns = STUFF((
    SELECT ', SUM(CASE WHEN PeriodID = ' + CAST(PeriodID AS VARCHAR(11)) +
           ' THEN LotCount ELSE CAST(0 AS BIGINT) END) AS ' +
           QUOTENAME(PeriodLabel)
    FROM @ReportingPeriods ORDER BY PeriodID
    FOR XML PATH(''), TYPE
).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

SET @SummarySQL = N'
;WITH Counts AS (
    SELECT PeriodID, ST_Category, COUNT_BIG(*) AS LotCount
    FROM #Inventory GROUP BY PeriodID, ST_Category
)
SELECT ST_Category, ' + @YearColumns + N'
FROM Counts GROUP BY ST_Category ORDER BY ST_Category;';
-- Dynamic SQL can read the session temporary table created above.
EXEC sys.sp_executesql @SummarySQL;

-- Control totals also show the exact cutoff used for each column.
-- Periods without qualifying lots display zero.
SELECT p.PeriodLabel, p.EndDate AS ReportingEndDate,
       COUNT(DISTINCT i.lot_no) AS QualifyingLotCount
FROM @ReportingPeriods p
LEFT JOIN #Inventory i ON i.PeriodID = p.PeriodID
GROUP BY p.PeriodID, p.PeriodLabel, p.EndDate
ORDER BY p.PeriodID;

-- STEP 5 / Result 3: Show one selected qualifying meter for each inventory lot.
-- Start from #Inventory to preserve the summary's set of qualifying lots.
-- OUTER APPLY retains the inventory row even if optional detail data is missing.
SELECT i.PeriodID, p.PeriodLabel, i.AsOfDate AS ReportingEndDate,
       i.lot_no AS LotNo, i.ST_Category,
       l.misc_2 AS OriginalSTCategory, l.misc_16 AS ConnectionType,
       LTRIM(RTRIM(
           COALESCE(CAST(l.street_number AS VARCHAR(20)), '') + ' ' +
           COALESCE(l.street_directional, '') + ' ' +
           COALESCE(l.street_name, '') +
           CASE WHEN NULLIF(LTRIM(RTRIM(l.addr_2)), '') IS NOT NULL
                THEN ' ' + l.addr_2 ELSE '' END
       )) AS ServiceAddress,
       l.city AS City, l.state AS State,
       m.ub_meter_con_id AS MeterConnectionID, m.ub_device_id AS DeviceID,
       m.route_no AS RouteNo, m.serial_no AS MeterSerialNumber,
       m.device_size AS MeterSize, m.manufacturer AS MeterManufacturer,
       m.model_no AS MeterModel,
       m.install_date AS MeterInstallDate, m.remove_date AS MeterRemoveDate,
       m.con_status AS CurrentMeterStatus
FROM #Inventory i
INNER JOIN @ReportingPeriods p ON p.PeriodID = i.PeriodID
LEFT JOIN Springbrook0.dbo.lot l ON l.lot_no = i.lot_no
OUTER APPLY (
    SELECT TOP (1)
           mc.ub_meter_con_id, mc.ub_device_id, mc.route_no,
           mc.install_date, mc.remove_date, mc.con_status,
           ud.serial_no, udt.device_size, udt.manufacturer, udt.model_no
    FROM Springbrook0.dbo.ub_meter_con mc
    INNER JOIN Springbrook0.dbo.ub_device ud
        ON ud.ub_device_id = mc.ub_device_id
    -- Missing device type/size must not remove a qualifying inventory lot.
    LEFT JOIN Springbrook0.dbo.ub_device_type udt
        ON udt.ub_device_type_id = ud.ub_device_type_id
    WHERE mc.lot_no = i.lot_no
      AND mc.ub_meter_con_id IS NOT NULL
      AND mc.install_date <= i.AsOfDate
      AND (mc.remove_date IS NULL OR mc.remove_date > i.AsOfDate)
      AND ISNULL(ud.serial_no, '') NOT LIKE '%-S%'
      AND UPPER(ISNULL(ud.serial_no, '')) NOT LIKE '%HYDRANT%'
    -- Current status is a display preference, not historical eligibility.
    ORDER BY CASE WHEN mc.con_status = 'Active' THEN 1 ELSE 3 END,
             mc.ub_meter_con_id DESC
) m
WHERE i.PeriodID = @DetailPeriodID
ORDER BY i.ST_Category, i.lot_no;

-- Final cleanup affects only this session's temporary report tables.
DROP TABLE #Inventory;
