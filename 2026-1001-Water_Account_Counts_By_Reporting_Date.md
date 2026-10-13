# Water Account Counts by Reporting Date — User Guide

**SQL author:** Teo Espero, IT Administrator, Marina Coast Water District  
**SQL version:** 1.6  
**Guide date:** October 13, 2026  
**Source reviewed:** `2026-1001-Water_Account_Counts_By_Reporting_Date.sql`

## What this report counts

This report counts distinct customer-number/customer-sequence pairs whose account dates cover each cutoff and whose lot has at least one qualifying meter. It considers all qualifying accounts instead of selecting only one account per lot.

The category summary deduplicates accounts within each period and category. The control result separately counts distinct accounts across categories and distinct lots. Two qualifying accounts on one lot can contribute two accounts but one lot. Several meters on one lot do not multiply an account count.

The report reconstructs eligibility from dates. It does not prove historical active status where closure dates are missing, nor does it independently identify water service through an account-specific service table.

## How the code works

1. Validate `@ReportingPeriods` and `@DetailPeriodID`.
2. `YearEnds` supplies each cutoff and heading; `LotData` reads current lot categories and assembled addresses.
3. Join `ub_master` to each period using account start and end date conditions, then join its lot.
4. Use `EXISTS` to require a date-qualified meter on that lot without multiplying account rows.
5. Use `OUTER APPLY TOP (1)` to select a meter size for display. This does not determine account eligibility.
6. Store the qualifying master/lot records in `#EligibleAccountDetails`.
7. Build `#EligibleAccounts` from distinct period/category/customer/sequence combinations.
8. Produce the category matrix, selected-period control totals, and selected-period details; then drop both temporary tables.

## Account and meter date checks

```sql
um.connect_date < DATEADD(DAY, 1, AsOfDate)
AND (um.final_date IS NULL OR CONVERT(DATE, um.final_date) > AsOfDate)
```

Meter installation/removal checks use the same pattern. Starts and installations anywhere on the cutoff day qualify. Finalizations and removals on the cutoff calendar day are excluded, regardless of time. Missing connection or installation dates are excluded. NULL end/removal dates are treated as still open/not removed.

For a June 30, 2026 cutoff:

| Account dates | Qualifies by account dates? |
|---|---|
| Started June 30 at noon; no end date | Yes. |
| Started earlier; ended July 1 | Yes. |
| Started earlier; ended June 30 | No. |
| Starts July 1 | No. |
| No connection date | No. |

A qualifying account also needs a qualifying lot and meter. Current `acct_status` does not filter the account; a currently Final or Delete account can have dates that covered a past cutoff. A missing final date can also incorrectly retain an obsolete record, so inspect overlapping accounts rather than automatically excluding every currently non-active account.

## Meter size in the details

`MeterSize` comes from `ub_device_type.device_size` for one selected meter on the account's lot. Selection prefers current Active meter status, then the highest connection record ID, among date-qualified meters. The highest ID does not guarantee the most recent installation.

The size is returned as stored, without conversion or assumed units. Missing device type/size remains NULL. Several accounts on the same lot can display the same meter size because the link is through the lot, not an account-specific meter relationship.

## Results

| Result | Contents |
|---|---|
| 1 — Category summary | ST_Category rows and one column per entered reporting period. |
| 2 — Selected-period controls | PeriodID, PeriodLabel, ReportingEndDate, SumOfCategoryCounts, DistinctAccountCount, DistinctLotCount. |
| 3 — Account details | Selected-period qualifying account/master records with dates and meter size. |

Detail fields: PeriodID, PeriodLabel, ReportingEndDate, AccountNumber, cust_no, cust_sequence, LotNo, ub_master_id, ST_Category, OriginalSTCategory, ConnectionType, ServiceAddress, AccountStartDate, AccountEndDate, CurrentAccountStatus, and MeterSize.

AccountNumber is displayed with six customer digits and three sequence digits, such as `009755-005`. Counts use the original customer and sequence values rather than the formatted string. Keep account numbers as text when importing into Excel.

## Source tables

| Table in Springbrook0.dbo | Use |
|---|---|
| ub_master | Account identity, connection/final dates, lot, current status. |
| lot | Categories, connection type, and address. |
| ub_meter_con | Meter-to-lot connection and installation/removal dates. |
| ub_device | Serial exclusion and device type link. |
| ub_device_type | Selected meter size for details. |

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

## Reconcile the totals

Compare `SumOfCategoryCounts` with `DistinctAccountCount`. A difference means an account qualifies under more than one category. Inspect the account's lot/master records rather than adding the category totals and assuming they count unique accounts across categories.

The third result retains distinct master/lot details. Different master records for the same account can produce more detail rows than distinct accounts. For comparison with another export, match customer/sequence or AccountNumber, then inspect LotNo and dates.

## Checks and common issues

- Detail ID not found: choose an existing ID. The default ID 10 must change when the replacement list uses different IDs.
- Blank/missing end dates: review old Delete records and overlapping accounts before using official totals.
- Duplicate customer accounts on a lot: may be legitimate services or incomplete closure records; review the source evidence.
- Count differs from meter inventory: account rules exclude lots without qualifying accounts; multiple accounts can also exceed one-per-lot counts. Cutoff-day timestamp treatment differs between the scripts.
- Category split: only Multi Family variations and Irrigation are normalized explicitly; other spelling variations can remain.
- Cutoff `9999-12-31`: rejected because the next-day comparison would overflow.
- No qualifying accounts: summary may be empty; selected-period controls show zero.

## Revision history

All revisions below are dated October 13, 2026 and credited to Teo Espero in the supplied SQL.

| Version | Change |
|---|---|
| 1.0 | Account selection for multiple year-end dates. |
| 1.1 | Period columns and Irrigation-to-Landscape mapping. |
| 1.2 | Reconciliation totals and account detail output. |
| 1.3 | Multi Family capitalization standardized. |
| 1.4 | Individual period labels and cutoff dates. |
| 1.5 | Meter size added to account details. |
| 1.6 | Authorship, reporting documentation, and inline comments. |
