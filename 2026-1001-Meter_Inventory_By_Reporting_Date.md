# Meter Inventory by Reporting Date — User Guide

**SQL author:** Teo Espero, IT Administrator, Marina Coast Water District  
**SQL version:** 1.3  
**Guide date:** October 13, 2026  
**Source reviewed:** `2026-1001-Meter_Inventory_By_Reporting_Date.sql`

## What this report counts

This report counts lots that have at least one qualifying meter at each entered cutoff. It does not count every physical meter or require an open customer account. One lot with three qualifying meters normally contributes one count, and the detail output displays one selected meter for that lot.

The summary stores distinct period/lot/category combinations. The control totals count distinct lot numbers. If a lot has conflicting categories in the source records, category totals can sum to more than the distinct lot total.

## How the code works

1. `@ReportingPeriods` supplies the cutoff dates and column headings; validation checks the list and selected detail ID.
2. `YearEnds` makes each entered cutoff available to the query. `LotData` reads the current lot category, connection type, and assembled service address.
3. The query combines each period with the lots and uses `EXISTS` to check for at least one qualifying meter. Multiple meter records do not multiply the lot count.
4. `#Inventory` stores distinct qualifying period/lot/category combinations.
5. The dynamic summary groups these records by category and places the selected periods in columns.
6. Control totals show the actual dates and distinct lot counts for every period.
7. The third result starts from the selected period's inventory lots and uses `OUTER APPLY TOP (1)` to attach one meter and its type information.
8. The temporary inventory table is dropped.

## Meter date checks

```sql
mc.install_date <= AsOfDate
AND (mc.remove_date IS NULL OR mc.remove_date > AsOfDate)
```

A missing installation date is excluded. No active lot or meter status is required for inclusion. The comparisons preserve the original report's rules.

**Time-of-day matters if these columns contain timestamps.** A DATE cutoff is midnight. A meter installed at noon on June 30 does not satisfy `install_date <= '2026-06-30'`; a meter removed at noon that day does satisfy `remove_date > '2026-06-30'`. A removal stored exactly at midnight is excluded. If the source columns contain dates only, installation on the cutoff qualifies and removal on the cutoff does not.

The account summary uses full calendar-day rules, so the two scripts can differ on cutoff-day timestamp records even before accounting for their different counting units.

## Meter selection and sizes

Among meters meeting the same date and serial rules, the detail output prefers a meter whose current connection status is Active. Ties use the highest `ub_meter_con_id`. The highest ID is a tie-breaker, not proof of the latest installation date.

Size comes from `ub_device_type.device_size`. The value is returned as stored, without conversion or assumed units. A missing type or size remains NULL and does not remove the lot. The selection uses the lot number; it does not show all devices on that lot.

## Results

| Result | Contents |
|---|---|
| 1 — Category summary | ST_Category rows; one column for each entered period. |
| 2 — Control totals | PeriodLabel, ReportingEndDate, QualifyingLotCount for every period. |
| 3 — Meter details | Selected period's lots and selected meter information. |

Detail fields: PeriodID, PeriodLabel, ReportingEndDate, LotNo, ST_Category, OriginalSTCategory, ConnectionType, ServiceAddress, City, State, MeterConnectionID, DeviceID, RouteNo, MeterSerialNumber, MeterSize, MeterManufacturer, MeterModel, MeterInstallDate, MeterRemoveDate, and CurrentMeterStatus.

## Source tables

| Table in Springbrook0.dbo | Use |
|---|---|
| lot | Lot identity, categories, connection type, and address. |
| ub_meter_con | Meter-to-lot connection, dates, route, status, and connection ID. |
| ub_device | Serial number and device type link. |
| ub_device_type | Size, manufacturer, and model for the selected meter. |

## Set the reporting periods

Replace the existing `INSERT INTO @ReportingPeriods ... VALUES ...;` block. Do not add another insert with the same IDs or labels.

| Setting | Meaning |
|---|---|
| `PeriodID` | Unique integer that controls column order. It is not the year itself. |
| `PeriodLabel` | Unique heading for the summary column. |
| `EndDate` | The exact cutoff date for that column. Use `YYYY-MM-DD`. |
| `@DetailPeriodID` | ID from the list to use for the detail output. |

The supplied defaults contain FY2017 through FY2026, each ending June 30. ID 10 selects FY2026 details. The label does not calculate the cutoff: changing `FY2025` to `CY2025` without changing its date still uses June 30.

### Fiscal years

```sql
INSERT INTO @ReportingPeriods (PeriodID, PeriodLabel, EndDate)
VALUES
    (1, N'FY2024', '2024-06-30'),
    (2, N'FY2025', '2025-06-30'),
    (3, N'FY2026', '2026-06-30');

DECLARE @DetailPeriodID INT = 3;
```

### Calendar years

```sql
INSERT INTO @ReportingPeriods (PeriodID, PeriodLabel, EndDate)
VALUES
    (1, N'CY2023', '2023-12-31'),
    (2, N'CY2024', '2024-12-31'),
    (3, N'CY2025', '2025-12-31');

DECLARE @DetailPeriodID INT = 3;
```

### Compare fiscal and calendar cutoffs

```sql
INSERT INTO @ReportingPeriods (PeriodID, PeriodLabel, EndDate)
VALUES
    (1, N'FY2025', '2025-06-30'),
    (2, N'CY2025', '2025-12-31'),
    (3, N'Sep2026', '2026-09-30');

DECLARE @DetailPeriodID INT = 2;
```

Each example replaces the existing detail declaration as well. Declare `@DetailPeriodID` only once. These are counts at individual cutoff dates, not counts of everyone served during a date range.

## Category and exclusion rules

| Stored value or condition | Treatment |
|---|---|
| Connection Type `lot.misc_16` equals Irrigation | Category becomes Landscape, regardless of original ST Category. |
| ST Category is a capitalization variation of Multi Family | Category becomes Multi Family. |
| ST Category is blank or NULL | Category becomes Unspecified. |
| Other ST Category | Trimmed value is retained. |
| Service address contains SEWER, HYDRANT, or DELETED | Excluded. |
| Meter serial contains `-S` or HYDRANT | Excluded. |
| Bay View or recycled water | Included unless excluded by another rule. |

Irrigation and Multi Family comparisons ignore case and surrounding spaces. The `-S` comparison follows the database collation. Missing serial numbers are allowed, but a matching device record must exist. These inherited exclusions do not establish a complete water-service classification.

## Run and export

1. Open the SQL file in SSMS connected to SQL Server 2016 or later, with read permission for `Springbrook0.dbo` source tables.
2. Replace the period list and set the detail ID to an ID in that list.
3. Run the entire script in one batch. Do not add `GO` within it or execute only the final SELECT.
4. Review the summary, control totals, and details in the three Results grids.
5. Export the required grids to Excel or CSV and record the run date and cutoff dates with the saved results.

The script changes only session temporary tables. It does not update Springbrook records. Dynamic SQL builds the period columns in ID order; `QUOTENAME` protects the column labels. An existing category with no qualifying records in a particular period shows zero. A category absent from all requested periods is not displayed.

## Historical limits

Both scripts use historical dates currently stored in Springbrook, not a restored database snapshot. Later corrections can change results for the same cutoff. Categories, addresses, and connection types reflect current lot records. Current status is not a history of status changes.

Save dated exports to preserve what each run returned. A future cutoff can include scheduled records already entered; it is not a forecast. Neither guide establishes that the SQL was executed or validated against the live database.

## Checks and common issues

- Detail ID not found: select an ID in the entered period list.
- Duplicate ID or label: give each period its own unique ID and label.
- Different count from the account report: expected when lots lack open accounts or have multiple qualifying accounts. Also check the timestamp rules above.
- Blank size: inspect the device type link and stored size; do not replace a missing size with zero.
- Detail rows exceed distinct lots: check duplicate or conflicting lot records and the lot join before assuming there are more meters.
- Zero qualifying records: the category summary can be empty; control totals still show the requested periods with zero.

## Revision history

All revisions below are dated October 13, 2026 and credited to Teo Espero in the supplied SQL.

| Version | Change |
|---|---|
| 1.0 | Multi-year lot inventory and inherited eligibility/category rules. |
| 1.1 | Individual period labels, cutoff dates, and totals. |
| 1.2 | Authorship, reporting documentation, and inline comments. |
| 1.3 | Selected-period meter details, including sizes. |
