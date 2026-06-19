# sp_CheckBackup

`sp_CheckBackup` inspects your SQL Server backup history and surfaces recoverability problems, as well as review the raw backup and restore history in several different ways. It is part of the free [Straight Path IT Solutions](https://straightpathsql.com/) `sp_Check*` suite.

## Features

- Flags databases with **missing or stale backups** (no full backup ever, no full in the last 7 days, no log backup ever, no log in the last 24 hours).
- Confirms backups against a user-supplied **Recovery Point Objective (RPO)** in minutes.
- Detects **split backup chains** (a database's backups landing in more than one location), which complicate restores.
- Surfaces **encryption / certificate risks**: TDE certificates and database-backup certificates that have never been backed up, haven't been backed up in 90 days, or are set to expire.
- Catches **failed backups** and **log backups written to the `NUL` device** by parsing the SQL Server error log and backup history.
- Reports operational hygiene issues: **backup compression / checksum** not enabled by default, recent backups taken without checksum, **msdb backup history not purged**, **high VLF counts**, **missing integrity checks (DBCC CHECKDB)**, **SQL Server Agent offline**, and **I/O freezes** (often caused by VSS / VM backups).
- Provides review modes for a per-database **summary**, full backup **detail**, **backup-chain** location counts, and **restore history**.
- Supports filtering by database, backup type, device type, copy-only status, and date range.

## Requirements

- **SQL Server version:** Designed for Microsoft-supported versions, **SQL Server 2016 (13.x) or later**. It will also run on earlier versions (back to 2008), but some checks are skipped based on version:
  - Backup checksum config / "backups without checksum" checks require **SQL Server 2014 (12.x)+** (`@SQLVersionMajor > 11`).
  - Database-backup-certificate checks require **SQL Server 2014 (12.x)+** (`>= 12`).
  - High VLF count check requires **SQL Server 2016 (13.x)+** (`>= 13`).
  - Availability Group columns require **SQL Server 2012 (11.x)+** and a boxed instance (not Azure SQL Managed Instance).
  - Password-protected-backup check applies only to **SQL Server 2008 / 2008 R2** (the feature was discontinued in 2012).
- **Permissions:** Effectively **sysadmin**. The procedure reads `msdb` backup/restore history, queries `sys.dm_server_services`, reads the SQL Server error log (`sp_readerrorlog` / `xp_readerrorlog`), and runs `DBCC DBINFO` across all databases via `sp_MSforeachdb`.
- **Database count guard:** Instances with **more than 50 databases** require `@Override = 1` (unless `@DatabaseName` is supplied), since gathering backup history can be resource-intensive.

## Parameters

| Name | Data Type | Default | Description |
|------|-----------|---------|-------------|
| `@Mode` | `TINYINT` | `99` | Output mode. `0` = problem findings only (unfiltered); `1` = one summary row per database; `2` = full backup detail; `3` = backup-chain check (look for any path count > 1); `4` = modes 1, 2, and 3 combined; `5` = restore history; `99` = modes 1 and 0 combined (default). |
| `@ShowCopyOnly` | `BIT` | `NULL` | `0` = hide copy-only backups; `1` = show only copy-only backups; `NULL` = show all (default). |
| `@DatabaseName` | `NVARCHAR(128)` | `NULL` | Restrict output to a single database. Also bypasses the >50-database override. |
| `@BackupType` | `CHAR(1)` | `NULL` | Filter by backup type: `'F'` = Full, `'D'` = Differential, `'L'` = Log. (Internally remapped to SQL Server's codes.) |
| `@DeviceType` | `VARCHAR(30)` | `NULL` | Filter by device: `'Disk'`, `'Tape'`, `'Virtual Device'`, or `'Azure Storage'`. |
| `@StartDate` | `DATETIME` | `NULL` | Start of the date range to consider. Defaults to **7 days ago** when `NULL`. |
| `@EndDate` | `DATETIME` | `NULL` | End of the date range to consider. Defaults to **now** when `NULL`. |
| `@RPO` | `INT` | `NULL` | Recovery Point Objective in **minutes**. When set, flags databases not backed up within this window (CheckID 214). |
| `@Override` | `BIT` | `0` | Set to `1` to proceed on instances with more than 50 databases. |
| `@Help` | `BIT` | `0` | Print help text (purpose, parameters, license) and exit. |
| `@VersionCheck` | `BIT` | `0` | Return the procedure's version number and date, then exit. |

This procedure has no `OUTPUT` parameters.

## Usage

```sql
-- Default run: per-database summary plus a list of backup problems
EXEC dbo.sp_CheckBackup;

-- Problem findings only, and require backups within a 15-minute RPO
EXEC dbo.sp_CheckBackup
      @Mode = 0
    , @RPO = 15;

-- Review full backup detail for one database over a custom date range
EXEC dbo.sp_CheckBackup
      @Mode = 2
    , @DatabaseName = N'Sales'
    , @StartDate = '2026-06-01'
    , @EndDate   = '2026-06-17';
```

## Priority System

Every finding is assigned a priority (the `Importance` column):

| Priority | Meaning |
|----------|---------|
| 0 | Informational |
| 1 | High |
| 2 | Medium |
| 3 | Low |

## Checks

Findings are returned in modes `0` and `99`. CheckIDs are grouped into series by category (`2xx` = Recoverability, `5xx` = Integrity, `6xx` = Reliability, `7xx` = Performance).

### 2xx - Recoverability

| CheckID | Finding | Priority | Description |
|---------|---------|----------|-------------|
| 201 | Split backup chain | 1 (High) | A database has backups of a given type written to more than one location, which makes restores difficult. |
| 202 | Backups without checksum | 2 (Medium) | A database has recent backups created without a checksum (SQL Server 2014+). |
| 203 | Missing full backup | 1 (High) | A database has never had a full backup. |
| 204 | Missing log backup | 1 (High) | A database in Full or Bulk-Logged recovery has never had a transaction log backup. |
| 205 | No recent full backup | 1 (High) | A database has had no full backup in the last 7 days. |
| 206 | No recent log backup | 1 (High) | A database in Full or Bulk-Logged recovery has had no log backup in the last 24 hours. |
| 207 | Failed database backups | 1 (High) | The SQL Server error log shows one or more `BACKUP failed to complete` messages in the date range. |
| 208 | Backup compression | 2 (Medium) | The `backup compression` / `backup compression default` configuration is not enabled. |
| 209 | Backup checksum | 2 (Medium) | The `backup checksum` / `backup checksum default` configuration is not enabled (SQL Server 2014+). |
| 210 | Database backup certificate (never / not recently backed up) | 1 (High) | A certificate used to encrypt database backups has never been backed up, or has not been backed up in the last 90 days (SQL Server 2014+). |
| 211 | TDE certificate (never / not recently backed up) | 1 (High) | A TDE certificate required for restoring has never been backed up, or has not been backed up in the last 90 days. |
| 212 | Database backup certificate set to expire | 1 (High) | A certificate used to encrypt database backups is set to expire (SQL Server 2014+). |
| 213 | TDE certificate set to expire | 2 (Medium) | A TDE certificate required for restoring is set to expire. |
| 214 | Missed RPO | 1 (High) | With `@RPO` supplied, a database has not been backed up within the RPO window (or has never been backed up). |
| 215 | Password protected backups | 2 (Medium) | A database has had password-protected backups recently (SQL Server 2008 / 2008 R2 only). |
| 216 | Backup history not purged | 2 (Medium) | `msdb` backup history is retained beyond 90 days, which can bloat `msdb`. |
| 217 | High VLF count | 2 (Medium) | A database's transaction log has more than 200 virtual log files (SQL Server 2016+). |
| 218 | Log backup to NUL | 1 (High) | Transaction log backups have been written to the `NUL` device, discarding log records and breaking the log chain. |

### 5xx - Integrity

| CheckID | Finding | Priority | Description |
|---------|---------|----------|-------------|
| 503 | Missing integrity checks | 1 (High) | A database has not had a successful `DBCC CHECKDB` in the last 2 weeks. |

### 6xx - Reliability

| CheckID | Finding | Priority | Description |
|---------|---------|----------|-------------|
| 628 | SQL Server Agent offline | 1 (High) | The SQL Server Agent service is not running (excluding Express Edition), so scheduled backups and maintenance will not run. |

### 7xx - Performance

| CheckID | Finding | Priority | Description |
|---------|---------|----------|-------------|
| 739 | I/O freeze detected | 2 (Medium) | The error log shows I/O freeze/resume events against a database, usually caused by VSS-based VM or volume backups. |

## Results Organization

CheckID series map to categories: **2xx Recoverability**, **5xx Integrity**, **6xx Reliability**, **7xx Performance**. The result set(s) returned depend on `@Mode`:

- **Summary** (modes `1`, `4`, `99`): one row per database with current recovery model, Availability Group / preferred-backup-replica info, minutes since last backup, and the start/finish/duration/size/path/file-count/device-type of the most recent Full, Differential, and Log backups.
- **Detail** (modes `2`, `4`): every backup in the date range with type, recovery model, copy-only / snapshot / password / checksum / encryption flags, sizes and compression percentage, physical/logical device, user, and family sequence number.
- **Backup-chain check** (modes `3`, `4`): per database and backup type, the number of distinct backup paths (`NumberOfPaths > 1` indicates a split chain) and the paths themselves.
- **Restore history** (mode `5`): two result sets, the most recent restore per database, and the detailed restore history (restore type, replace/recovery flags, stop-at time) within the date range.
- **Issues** (modes `0`, `99`): the findings from the Checks tables above, ordered by Importance, then category, CheckID, issue, and database. Columns: `Importance`, `CheckName`, `Issue`, `DatabaseName`, `Details`, `ActionStep`, `ReadMoreURL`, `CheckID`.

## Documentation

Full documentation: <https://straightpathsql.com/sp_check/sp_checkbackup/>

## Credits

Provided by **Straight Path IT Solutions, LLC**, <https://straightpathsql.com/>

Portions are derived from `sp_Blitz` (Brent Ozar Unlimited) and are used under the MIT License. Licensed under the MIT License. Copyright © 2026 Straight Path IT Solutions, LLC.
