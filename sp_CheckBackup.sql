IF OBJECT_ID('dbo.sp_CheckBackup') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_CheckBackup AS RETURN 0;');
GO


ALTER PROCEDURE dbo.sp_CheckBackup
    @Mode TINYINT = 99 
    , @ShowCopyOnly BIT = NULL
    , @DatabaseName NVARCHAR(128) = NULL
	, @BackupType CHAR(1) = NULL
	, @DeviceType VARCHAR(30) = NULL
	, @StartDate DATETIME = NULL
	, @EndDate DATETIME = NULL
	, @RPO INT = NULL
	, @Override BIT = 0
	, @Help BIT = 0
	, @VersionCheck BIT = 0

WITH RECOMPILE
AS
SET NOCOUNT ON;

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE 
    @Version VARCHAR(10) = NULL
	, @VersionDate DATETIME = NULL

SELECT
    @Version = '2026.6.1'
    , @VersionDate = '20260612';

/* Version check */
IF @VersionCheck = 1 BEGIN

	SELECT
		@Version AS VersionNumber
		, @VersionDate AS VersionDate

	RETURN;
	END; 

/* @Help = 1 */
IF @Help = 1 BEGIN
	PRINT '
/*
    sp_CheckBackup from https://straightpathsql.com/

	Version: ' + @Version + ' updated ' + CONVERT(VARCHAR(10), @VersionDate, 101) + '
    	
    This stored procedure checks your SQL Server backup history for issues and 
    provides a list of findings with action items, or if you prefer, allows you 
    to review the backup history in a few different ways.
    
    Known limitations of this version:
    - sp_CheckBackup only works Microsoft-supported versions of SQL Server, so 
    that means SQL Server 2016 or later.
    - sp_CheckBackup will work with some earlier versions of SQL Server, but it 
    will skip a few checks. The results should still be valid and helpful, but you
    should really consider upgrading to a newer version.
    
    Parameters:

    @Mode  0=Show only problematic issues, unfiltered
           1=Summary one fact-filled row per database, may be filtered
		   2=Detail, all backup history, may be filtered
		   3=Backup chain check, may be filtered, look for any number > 1
		   4=Shows results of 1, 2, and 3, and may be filtered
		   5=Shows restore history, and may be filtered
		   99=Shows result sets for both @Mode = 1 and @Mode = 0 (DEFAULT)

    @ShowCopyOnly:	0=Hide Copy Only backups
					1=Show ONLY Copy Only backups
					NULL=Show all backups (DEFAULT)

    @DatabaseName for filtering on one specific database

	@BackupType for filtering: ''F'' = Full, ''D'' = Differential, ''L'' = Log

	@DeviceType for filtering: ''Disk'', ''Tape'', ''Virtual Device'', ''Azure Storage''

	@StartDate for filtering

	@EndDate for filtering
	
	@RPO for confirming backups within an expected Recovery Point Objective (minutes)
		
	@Override for allowing checks on instances of over 50 databases

    MIT License
    
    Copyright for portions of sp_CheckBackup are also held by Brent Ozar Unlimited
    as part of sp_Blitz and are provided under the MIT license:
    https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
    	
    All other copyrights for sp_CheckBackup are held by Straight Path Solutions.
    
    Copyright 2026 Straight Path IT Solutions, LLC
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
    
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

*/';
	RETURN;
	END;  


/* Check if @Override needed for too many databases */
IF @Override = 0 AND ((SELECT COUNT(database_id) from sys.databases) > 50) AND @DatabaseName IS NULL BEGIN
	PRINT '
	You have over 50 databases, so you could have a lot of backup history.

	If you want to proceed, and you understand this procedure could use
	substantial resources to get your backup history, use @Override = 1.

	Godspeed, my friend.
'
	RETURN;
	END;  

/* set some defaults */

/* Default @StartDate of 7 days before now */
IF @StartDate IS NULL
    SET @StartDate = DATEADD(dd, -7, GETDATE());

IF @EndDate IS NULL
	SET @EndDate = GETDATE();

/* Change @BackType so SQL Server understands */
IF @BackupType = 'D'
    SET @BackupType = 'I'

IF @BackupType = 'F'
    SET @BackupType = 'D'


/* SQL Server version check */	
DECLARE 
	@SQL NVARCHAR(4000)
	, @SQLVersion NVARCHAR(128)
	, @SQLVersionMajor DECIMAL(10,2)
	, @SQLVersionMinor DECIMAL(10,2);

IF OBJECT_ID('tempdb..#SQLVersions') IS NOT NULL
	DROP TABLE #SQLVersions;

CREATE TABLE #SQLVersions (
	VersionName VARCHAR(10)
	, VersionNumber DECIMAL(10,2)
	);

INSERT #SQLVersions
VALUES
	('2008', 10)
	, ('2008 R2', 10.5)
	, ('2012', 11)
	, ('2014', 12)
	, ('2016', 13)
	, ('2017', 14)
	, ('2019', 15)
	, ('2022', 16)
	, ('2025', 17);

/* SQL Server version */
SELECT @SQLVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));

SELECT 
	@SQLVersionMajor = SUBSTRING(@SQLVersion, 1,CHARINDEX('.', @SQLVersion) + 1 )
	, @SQLVersionMinor = PARSENAME(CONVERT(VARCHAR(32), @SQLVersion), 2);

/* DeviceType */
DECLARE @DeviceTypeTinyint TINYINT = NULL

IF @DeviceType IS NOT NULL
	SELECT @DeviceTypeTinyint = CASE @DeviceType
		WHEN 'Disk' THEN 2
		WHEN 'Tape' THEN 5
		WHEN 'Virtual Device' THEN 7
		WHEN 'Azure Storage' THEN 9
		END

/* grab the backup history */
IF OBJECT_ID('tempdb..#LastBackup') IS NOT NULL
	DROP TABLE #LastBackup;

CREATE TABLE #LastBackup (
	DatabaseName NVARCHAR(128)
	, InstanceName NVARCHAR(128)
    , BackupType CHAR(1)
	, LastBackupDate DATETIME
	);

INSERT #LastBackup
SELECT
	[database_name]
	, COALESCE(server_name, CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'))) 
	, [type]
	, max(backup_start_date)
FROM msdb.dbo.backupset
WHERE backup_finish_date is not null
	AND database_name = COALESCE(@DatabaseName, database_name)
GROUP BY [database_name], server_name, [type];

CREATE CLUSTERED INDEX PK_LastBackup
ON #LastBackup (DatabaseName, InstanceName, BackupType);


IF OBJECT_ID('tempdb..#BackupHistory') IS NOT NULL
	DROP TABLE #BackupHistory;

CREATE TABLE #BackupHistory (
	BackupSetID INT
	, InstanceName NVARCHAR(128)
	, DatabaseID INT
	, DatabaseName NVARCHAR(128)
	, RecoveryModel CHAR(1)
    , BackupType CHAR(1)
	, IsCopyOnly BIT
	, IsSnapshot BIT
	, IsPasswordProtected BIT
	, EncryptionType NVARCHAR(32)
	, BackupChecksum BIT
	, BackupStartDate DATETIME
	, BackupFinishDate DATETIME
	, BackupSize NUMERIC(20,0)
	, CompressedBackupSize NUMERIC(20,0)
	, MediaSetID INT
	, FamilySequenceNumber TINYINT
	, PhysicalDevice NVARCHAR(260)
	, LogicalDevice NVARCHAR(128)
	, DeviceType VARCHAR(30)
	, UserName NVARCHAR(255)
	);

CREATE CLUSTERED INDEX PK_BackupHistory
ON #BackupHistory (BackupSetID);


INSERT #BackupHistory WITH (TABLOCK)
SELECT
	s.backup_set_id
	, s.server_name
	, d.database_id
	, s.database_name
	, LEFT(s.recovery_model, 1)
    , s.[type]
	, s.is_copy_only
	, s.is_snapshot
	, s.is_password_protected
	, s.encryptor_type
	, s.has_backup_checksums
	, s.backup_start_date
	, s.backup_finish_date
    , s.backup_size
	, s.compressed_backup_size
	, m.media_set_id
	, m.family_sequence_number
	, m.physical_device_name AS PhysicalDevice
	, m.logical_device_name AS LogicalDevice
	, CASE m.device_type
		WHEN 2 THEN 'Disk'
		WHEN 5 THEN 'Tape'
		WHEN 7 THEN 'Virtual Device'
		WHEN 9 THEN 'Azure Storage'
		WHEN 105 THEN 'A permanent Backup Device'
		ELSE 'UNKNOWN'
		END
	, s.[user_name] AS UserName
FROM msdb.dbo.backupset s
INNER JOIN msdb.dbo.backupmediafamily m
	ON s.media_set_id = m.media_set_id
LEFT JOIN master.sys.databases d
    ON s.database_name COLLATE SQL_Latin1_General_CP1_CI_AS = d.name COLLATE SQL_Latin1_General_CP1_CI_AS
WHERE s.server_name = SERVERPROPERTY('ServerName') /* backup run on current server  */
	AND d.database_id <> 2  /* exclude tempdb */
	AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
	AND d.is_in_standby = 0 /* not a log shipping target database */
	AND d.source_database_id IS NULL /* exclude database snapshots */
	AND s.database_name = COALESCE(@DatabaseName, s.database_name)
	AND m.device_type = COALESCE(@DeviceTypeTinyint, m.device_type)
	AND s.is_copy_only = COALESCE(@ShowCopyOnly, s.is_copy_only)
	AND s.backup_start_date >= @StartDate
	AND s.backup_start_date <= @EndDate;

CREATE INDEX IX_LastBackup
ON #BackupHistory (IsCopyOnly, BackupType, FamilySequenceNumber)
INCLUDE (DatabaseName);

CREATE INDEX IX_BackupHistory_BackupPathCount
ON #BackupHistory (IsCopyOnly, BackupStartDate)
INCLUDE (InstanceName, DatabaseName, BackupType);

CREATE INDEX IX_BackupHistory_BackupMissingChecksum
ON #BackupHistory (BackupChecksum, IsCopyOnly, BackupStartDate, DatabaseName);

CREATE INDEX IX_BackupHistory_BackupCheck
ON #BackupHistory (InstanceName, DatabaseName, BackupType, BackupStartDate);


/* grab backup paths for split backup checks */
IF OBJECT_ID('tempdb..#BackupPath') IS NOT NULL
	DROP TABLE #BackupPath;

CREATE TABLE #BackupPath (
	BackupSetID INT
	, BackupPath NVARCHAR(260)
	);

INSERT #BackupPath WITH (TABLOCK)
SELECT
	bh.BackupSetID
	, CASE
	WHEN LEFT(bh.PhysicalDevice,1) = '{' THEN '{' + COALESCE(bh.DeviceType, 'UNKNOWN') + '}'
	WHEN CHARINDEX('\',REVERSE(bh.PhysicalDevice)) > 1 THEN SUBSTRING(bh.PhysicalDevice, 1, LEN(bh.PhysicalDevice)-CHARINDEX('\',REVERSE(bh.PhysicalDevice))+1)
	WHEN CHARINDEX('/',REVERSE(bh.PhysicalDevice)) > 1 THEN SUBSTRING(bh.PhysicalDevice, 1, LEN(bh.PhysicalDevice)-CHARINDEX('/',REVERSE(bh.PhysicalDevice))+1)
	END
FROM #BackupHistory bh
WHERE bh.FamilySequenceNumber = 1;

/* grab databases and availability group info */
IF OBJECT_ID('tempdb..#AvailabilityGroup') IS NOT NULL
	DROP TABLE #AvailabilityGroup;

CREATE TABLE #AvailabilityGroup (
    DatabaseID INT
	, DatabaseName NVARCHAR(255)
	, GroupID UNIQUEIDENTIFIER
	, GroupName NVARCHAR(255)
	, IsPreferredBackupReplica BIT
	);

/* Get database and Availability Group info */
/* AGs only apply to SQL Server 2012+ on boxed instances, not Azure SQL MI */
IF @SQLVersionMajor >= 11 AND SERVERPROPERTY('EngineEdition') <> 8 BEGIN
	SET @SQL = '
        SELECT
            d.database_id
            , d.[name]
            , ag.group_id
            , ag.[name]
        	, CASE COALESCE(ag.[name],'''')
        	    WHEN '''' THEN NULL
        		ELSE sys.fn_hadr_backup_is_preferred_replica (adc.database_name)
        		END
        FROM sys.databases d
        LEFT JOIN sys.availability_databases_cluster adc
            ON d.[name] = adc.database_name
        LEFT JOIN sys.availability_groups ag
            ON adc.group_id = ag.group_id
        WHERE d.database_id <> 2
        	AND d.state NOT IN (1, 6, 10)
        	AND d.is_in_standby = 0
        	AND d.source_database_id IS NULL;'
	END

/* Azure SQL MI, or any version before availability groups: no AG columns */
IF @SQLVersionMajor < 11 OR SERVERPROPERTY('EngineEdition') = 8 BEGIN
	SET @SQL = '
        SELECT
            d.database_id
            , d.[name]
            , NULL
            , NULL
        	, NULL
        FROM sys.databases d
        WHERE d.database_id > 4
        	AND d.state NOT IN (1, 6, 10)
        	AND d.is_in_standby = 0
        	AND d.source_database_id IS NULL;'
	END

INSERT #AvailabilityGroup
EXEC sp_executesql @SQL;



/* @Mode = 1 Summary Only */
IF @Mode IN (1,4,99) BEGIN

	IF OBJECT_ID('tempdb..#BackupSummary') IS NOT NULL
		DROP TABLE #BackupSummary;

	CREATE TABLE #BackupSummary (
		InstanceName NVARCHAR(255)
		, DatabaseName NVARCHAR(255)
		, AvailabilityGroupName NVARCHAR(255)
        , AvailabilityGroupPreferredBackup BIT
		, CurrentRecoveryModel NVARCHAR(20)
		, MinutesSinceLastBackup INT
		, LastFullCopyOnly VARCHAR(3)
		, LastFullStart DATETIME
		, LastFullFinish DATETIME
		, LastFullDuration NVARCHAR(30)
		, LastFullSizeInMB NVARCHAR(30)
		, LastFullPath NVARCHAR(1000)
		, LastFullNumberOfFiles TINYINT
		, LastFullDeviceType VARCHAR(30)
		, LastDiffStart DATETIME
		, LastDiffFinish DATETIME
		, LastDiffDuration NVARCHAR(30)
		, LastDiffSizeInMB NVARCHAR(30)
		, LastDiffPath NVARCHAR(1000)
		, LastDiffNumberOfFiles TINYINT
		, LastDiffDeviceType VARCHAR(30)
		, LastLogStart DATETIME
		, LastLogFinish DATETIME
		, LastLogDuration NVARCHAR(30)
		, LastLogSizeInMB NVARCHAR(30)
		, LastLogPath NVARCHAR(1000)
	    , LastLogNumberOfFiles TINYINT
		, LastLogDeviceType VARCHAR(30)
		);

	INSERT #BackupSummary (
		InstanceName
		, DatabaseName
		, CurrentRecoveryModel
		, AvailabilityGroupName
        , AvailabilityGroupPreferredBackup
		)
	SELECT 
		@@SERVERNAME
		, d.[name]
		, d.recovery_model_desc
        , ag.GroupName
        , ag.IsPreferredBackupReplica
	FROM sys.databases d
	INNER JOIN #AvailabilityGroup ag
        ON d.database_id = ag.DatabaseID
	WHERE d.[name] <> 'tempdb'
	AND d.[name] = COALESCE(@DatabaseName, [name])

--SELECT * from #AvailabilityGroup

	/* Most recent Full backup */
	;WITH LastBackupFull AS (
        SELECT
			lb.DatabaseName
			, lb.BackupSetID
			, COUNT(bh.FamilySequenceNumber) AS NumberOfFiles
		FROM (
			SELECT
				DatabaseName
				, MAX(BackupSetID) AS BackupSetID
			FROM #BackupHistory
			WHERE IsCopyOnly = COALESCE(@ShowCopyOnly, IsCopyOnly)
				AND FamilySequenceNumber = 1
				AND BackupType = 'D'
			GROUP BY
				DatabaseName
    		) lb
		INNER JOIN #BackupHistory bh
		 ON lb.BackupSetID = bh.BackupSetID
		GROUP BY
			lb.DatabaseName
			, lb.BackupSetID
    	)

	UPDATE bs
	SET 
		bs.LastFullStart = bh.BackupStartDate
		, bs.LastFullFinish = bh.BackupFinishDate
		, bs.LastFullDuration = CAST(DATEDIFF(second, bh.BackupStartDate, bh.BackupFinishDate) AS VARCHAR(10)) + ' ' + 'Seconds'
		, bs.LastFullPath = bp.BackupPath
		, bs.LastFullDeviceType = bh.DeviceType
		, bs.LastFullSizeInMB = CAST(bh.BackupSize / 1048576 AS INT)
		, bs.LastFullNumberOfFiles = lb.NumberOfFiles
		, bs.LastFullCopyOnly = CASE bh.IsCopyOnly
			WHEN 1 THEN 'Yes'
			ELSE 'No'
			END
	FROM #BackupSummary bs
	LEFT JOIN LastBackupFull lb
	    ON bs.DatabaseName = lb.DatabaseName
	LEFT JOIN #BackupHistory bh
	    ON lb.BackupSetID = bh.BackupSetID
		AND bh.FamilySequenceNumber = 1
	LEFT JOIN #BackupPath bp
	    ON bh.BackupSetID = bp.BackupSetID
		AND bh.FamilySequenceNumber = 1

	/* Most recent Differential backup */
 	;WITH LastBackupDiff AS (
        SELECT
			lb.DatabaseName
			, lb.BackupSetID
			, COUNT(bh.FamilySequenceNumber) AS NumberOfFiles
		FROM (
			SELECT
				DatabaseName
				, MAX(BackupSetID) AS BackupSetID
			FROM #BackupHistory
			WHERE IsCopyOnly = COALESCE(@ShowCopyOnly, IsCopyOnly)
				AND FamilySequenceNumber = 1
				AND BackupType = 'I'
			GROUP BY
				DatabaseName
    		) lb
		INNER JOIN #BackupHistory bh
		 ON lb.BackupSetID = bh.BackupSetID
		GROUP BY
			lb.DatabaseName
			, lb.BackupSetID
    	)

	UPDATE bs
	SET 
		bs.LastDiffStart = bh.BackupStartDate
		, bs.LastDiffFinish = bh.BackupFinishDate
		, bs.LastDiffDuration = CAST(DATEDIFF(second, bh.BackupStartDate, bh.BackupFinishDate) AS VARCHAR(10)) + ' ' + 'Seconds'
		, bs.LastDiffPath = bp.BackupPath
		, bs.LastDiffDeviceType = bh.DeviceType
		, bs.LastDiffSizeInMB = CAST(bh.BackupSize / 1048576 AS INT)
		, bs.LastDiffNumberOfFiles = lb.NumberOfFiles
	FROM #BackupSummary bs
	LEFT JOIN LastBackupDiff lb
	    ON bs.DatabaseName = lb.DatabaseName
	LEFT JOIN #BackupHistory bh
	    ON lb.BackupSetID = bh.BackupSetID
		AND bh.FamilySequenceNumber = 1
	LEFT JOIN #BackupPath bp
	    ON bh.BackupSetID = bp.BackupSetID
		AND bh.FamilySequenceNumber = 1

	/* Most recent Log backup */
 	;WITH LastBackupLog AS (
        SELECT
			lb.DatabaseName
			, lb.BackupSetID
			, COUNT(bh.FamilySequenceNumber) AS NumberOfFiles
		FROM (
			SELECT
				DatabaseName
				, MAX(BackupSetID) AS BackupSetID
			FROM #BackupHistory
			WHERE IsCopyOnly = COALESCE(@ShowCopyOnly, IsCopyOnly)
				AND FamilySequenceNumber = 1
				AND BackupType = 'L'
			GROUP BY
				DatabaseName
    		) lb
		INNER JOIN #BackupHistory bh
		 ON lb.BackupSetID = bh.BackupSetID
		GROUP BY
			lb.DatabaseName
			, lb.BackupSetID
    	)

	UPDATE bs
	SET 
		bs.LastLogStart = bh.BackupStartDate
		, bs.LastLogFinish = bh.BackupFinishDate
		, bs.LastLogDuration = CAST(DATEDIFF(second, bh.BackupStartDate, bh.BackupFinishDate) AS VARCHAR(10)) + ' ' + 'Seconds'
		, bs.LastLogPath = bp.BackupPath
		, bs.LastLogDeviceType = bh.DeviceType
		, bs.LastLogSizeInMB = CAST(bh.BackupSize / 1048576 AS INT)
		, bs.LastLogNumberOfFiles = lb.NumberOfFiles
	FROM #BackupSummary bs
	LEFT JOIN LastBackupLog lb
	    ON bs.DatabaseName = lb.DatabaseName
	LEFT JOIN #BackupHistory bh
	    ON lb.BackupSetID = bh.BackupSetID
		AND bh.FamilySequenceNumber = 1
	LEFT JOIN #BackupPath bp
	    ON bh.BackupSetID = bp.BackupSetID
		AND bh.FamilySequenceNumber = 1

    /* Update MinutesSinceLastBackup */
	;WITH LatestBackup AS (
        SELECT
		    bh.InstanceName
			, bh.DatabaseName
			, DATEDIFF(mi, MAX(bh.BackupStartDate), GETDATE()) AS LatestBackup
		FROM #BackupHistory bh
		GROUP BY
		    bh.InstanceName
			, bh.DatabaseName
    	)
	UPDATE bs
	SET bs.MinutesSinceLastBackup = lb.LatestBackup
	FROM #BackupSummary bs 
	INNER JOIN LatestBackup lb
	    ON bs.InstanceName = lb.InstanceName
	    AND bs.DatabaseName = lb.DatabaseName


/* Summary results */
	SELECT
		InstanceName
		, DatabaseName
		, AvailabilityGroupName
		, CASE AvailabilityGroupPreferredBackup
			WHEN 1 THEN 'Yes'
			WHEN 0 THEN 'No'
			ELSE NULL
			END AS AvailabilityGroupPreferredBackup
		, CurrentRecoveryModel
		, MinutesSinceLastBackup
		, LastFullCopyOnly
		, LastFullStart
		, LastFullFinish
		, LastFullDuration
		, LastFullSizeInMB
		, LastFullPath
		, LastFullNumberOfFiles
		, LastFullDeviceType
		, LastDiffStart
		, LastDiffFinish
		, LastDiffDuration
		, LastDiffSizeInMB
		, LastDiffPath
		, LastDiffNumberOfFiles
		, LastDiffDeviceType
		, LastLogStart
		, LastLogFinish
		, LastLogDuration
		, LastLogSizeInMB
		, LastLogPath
	    , LastLogNumberOfFiles
		, LastLogDeviceType
	FROM #BackupSummary
	ORDER BY
		InstanceName
		, DatabaseName
		, CurrentRecoveryModel

	END


/* @Mode = 2 Detail */
IF @Mode IN (2,4) BEGIN

	;WITH BackupFileCount AS (
        SELECT
			bh.DatabaseName
			, bh.BackupSetID
			, COUNT(bh.FamilySequenceNumber) AS NumberOfFiles
		FROM #BackupHistory bh
		GROUP BY
			bh.DatabaseName
			, bh.BackupSetID
    	)

	SELECT
		bh.InstanceName
		, bh.DatabaseName
		, ag.GroupName AS AvailabilityGroupName
		, CASE bh.RecoveryModel 
			WHEN 'S' THEN 'Simple'
			WHEN 'B' THEN 'Bulk Logged'
			WHEN 'F' THEN 'Full'
		    END AS RecoveryModel
		, CASE bh.BackupType
			WHEN 'D' THEN 'Full'
			WHEN 'I' THEN 'Differential'
			WHEN 'L' THEN 'Transaction Log'
			END AS BackupType
        , bh.BackupSetID
		, CASE bh.IsCopyOnly
			WHEN 1 THEN 'Yes'
			ELSE 'No'
			END AS IsCopyOnly
		, CASE bh.IsSnapshot
			WHEN 1 THEN 'Yes'
			ELSE 'No'
			END AS IsSnapshot
		, CASE bh.IsPasswordProtected
			WHEN 1 THEN 'Yes'
			ELSE 'No'
			END AS IsPasswordProtected
		, CASE bh.BackupChecksum
			WHEN 1 THEN 'Yes'
			ELSE 'No'
			END AS HasBackupChecksum
		, COALESCE(bh.EncryptionType, 'None') AS EncryptionType
		, bh.BackupStartDate
		, bh.BackupFinishDate
		, DATEDIFF(second, bh.BackupStartDate, bh.BackupFinishDate) AS DurationSeconds
		, CAST((bh.BackupSize/bc.NumberOfFiles) / 1048576 AS INT)  AS BackupSizeInMB
		, CAST((bh.CompressedBackupSize/bc.NumberOfFiles) / 1048576 AS INT)  AS CompressedBackupSizeInMB
		, CAST((1 - bh.CompressedBackupSize * 1.0 / NULLIF(bh.BackupSize, 0)) * 100 AS DECIMAL(5,2)) AS CompressionPercentage
		, bh.PhysicalDevice
		, bh.LogicalDevice
		, bh.DeviceType
		, bh.UserName
		, bh.FamilySequenceNumber
	FROM #BackupHistory bh
	INNER JOIN BackupFileCount bc
	    ON bh.BackupSetID = bc.BackupSetID
	INNER JOIN #AvailabilityGroup ag
        ON bh.DatabaseID = ag.DatabaseID
	WHERE 1=1
		AND bh.DatabaseName = COALESCE(@DatabaseName, bh.DatabaseName)
		AND bh.BackupType = COALESCE(@BackupType, bh.BackupType)
		AND bh.BackupStartDate >= COALESCE(@StartDate, bh.BackupStartDate)
		AND bh.BackupStartDate <= COALESCE(@EndDate, bh.BackupStartDate)
		AND bh.IsCopyOnly = COALESCE(@ShowCopyOnly, bh.IsCopyOnly)
	ORDER BY 
		bh.BackupStartDate DESC;

	END;


/* @Mode = 3 Backup Chain check */
If @Mode IN (3,4) BEGIN

	;WITH BackupPathCount AS (
        SELECT
		    bh.InstanceName
			, bh.DatabaseName
			, bh.BackupType
			, COUNT(DISTINCT(COALESCE(bp.BackupPath, bh.DeviceType))) AS NumberOfPaths
		FROM #BackupPath bp
		INNER JOIN #BackupHistory bh
		    ON bp.BackupSetID = bh.BackupSetID
		WHERE bh.DatabaseName = COALESCE(@DatabaseName, bh.DatabaseName)
		    AND bh.IsCopyOnly = 0
	        AND bh.BackupStartDate >= @StartDate
		    AND bh.BackupStartDate <= @EndDate
		GROUP BY
		    bh.InstanceName
			, bh.DatabaseName
			, bh.BackupType
    	)

SELECT
	bh.InstanceName
	, bh.DatabaseName
	, ag.GroupName AS AvailabilityGroupName
	, CASE bh.BackupType
		WHEN 'D' THEN 'Full'
		WHEN 'I' THEN 'Differential'
		WHEN 'L' THEN 'Transaction Log'
		END AS BackupType
    , bpc.NumberOfPaths
    , COALESCE(bp.BackupPath, bh.DeviceType) AS BackupPath
	FROM #BackupHistory bh
	INNER JOIN #BackupPath bp
	    ON bh.BackupSetID = bp.BackupSetID
		AND bh.FamilySequenceNumber = 1
	INNER JOIN BackupPathCount bpc
	    ON bh.DatabaseName = bpc.DatabaseName
		AND bh.BackupType = bpc.BackupType
	INNER JOIN #AvailabilityGroup ag
        ON bh.DatabaseID = ag.DatabaseID
	WHERE bh.IsCopyOnly = 0
		AND bh.BackupType = COALESCE(@BackupType, bh.BackupType)
	    AND bh.BackupStartDate >= @StartDate
		AND bh.BackupStartDate <= @EndDate
    GROUP BY
		bh.InstanceName
	    , bh.DatabaseName
	    , ag.GroupName
	    , bh.BackupType
        , bpc.NumberOfPaths
		, bp.BackupPath
		, bh.DeviceType
    ORDER BY
		bh.InstanceName
	    , bh.DatabaseName
	    , ag.GroupName
	    , bh.BackupType
		, bp.BackupPath
		, bh.DeviceType;

	END;

/* @Mode = 5 Restore history */
IF @Mode IN (5) BEGIN
	;WITH LastRestore AS (
		SELECT
			[d].[name] AS DatabaseName
			, r.restore_date AS RestoreDate
			, r.user_name AS UserName
			, ROW_NUMBER() OVER (PARTITION BY d.Name ORDER BY r.[restore_date] DESC) AS RowNumber
	FROM master.sys.databases d
	LEFT OUTER JOIN msdb.dbo.[restorehistory] r ON r.[destination_database_name] = d.[name]
	)
	SELECT
		DatabaseName
		, RestoreDate
		, UserName
	FROM LastRestore
	WHERE RowNumber = 1
	AND DatabaseName = COALESCE(@DatabaseName, DatabaseName);

	SELECT
		d.[name] AS DatabaseName
		, rh.restore_date AS RestoreDate
		, rh.[user_name] AS UserName
		, CASE rh.restore_type
			WHEN 'D' THEN 'Database'
			WHEN 'F' THEN 'File'
			WHEN 'G' THEN 'Filegroup'
			WHEN 'I' THEN 'Differential'
			WHEN 'L' THEN 'Log'
			WHEN 'V' THEN 'Verify Only'
			ELSE 'Unknown' END AS RestoreType
		, CASE rh.[replace]
			WHEN 1 THEN 'Yes'
			WHEN 0 THEN 'No'
			ELSE 'Unknown' END AS [Replace]
		, CASE rh.[recovery]
			WHEN 1 THEN 'Recovery'
			WHEN 0 THEN 'No Recovery'
			ELSE 'Unknown' END AS [Recovery]
		, rh.stop_at AS StopAtTime
	FROM master.sys.databases d
	INNER JOIN msdb.dbo.[restorehistory] rh
		ON rh.[destination_database_name] = d.[name]
	WHERE d.[name] = COALESCE(@DatabaseName, d.[name])
		AND rh.restore_date >= COALESCE(@StartDate, rh.restore_date)
		AND rh.restore_date <= COALESCE(@EndDate, rh.restore_date)
	ORDER BY RestoreDate DESC;

	END;

/* @Mode = 0 Backup issues */
IF @Mode IN (0,99) BEGIN

IF OBJECT_ID('tempdb..#Category') IS NOT NULL
	DROP TABLE #Category;

CREATE TABLE #Category (
    CategoryID TINYINT
	, CategoryName VARCHAR(50)
	);

INSERT #Category (CategoryID, CategoryName)
VALUES
    (0, '')
	, (1, 'Discovery')
    , (2, 'Recoverability')
    , (3, 'Security')
    , (4, 'Availability')
    , (5, 'Integrity')
    , (6, 'Reliability')
    , (7, 'Performance')
    , (8, 'Troubleshooting');

	IF OBJECT_ID('tempdb..#Results') IS NOT NULL
		DROP TABLE #Results;

	CREATE TABLE #Results (
		CategoryID TINYINT
		, CheckID INT
		, [Importance] TINYINT
		, CheckName VARCHAR(50)
		, Issue NVARCHAR(MAX)
		, DatabaseName NVARCHAR(255)
		, Details NVARCHAR(MAX)
		, ActionStep NVARCHAR(MAX)
		, ReadMoreURL XML
		);

	INSERT #Results
	SELECT
		0
		, 0
		, 0
		, 'sp_CheckBackup'
		, 'Provided by Straight Path IT Solutions, LLC'
		, NULL
		, '(Information captured on ' + CONVERT(VARCHAR(100), GETDATE(), 101) + ' using version ' + @Version + ')'
		, 'Use this FREE tool to check your backups for recovery issues!'
		, 'https://straightpathsql.com/tool/sp_checkbackup/'


	/* Backup Compression not enabled */
	INSERT #Results
	SELECT 
		2
		, 208
		, 2
		, 'Backup compression'
		, 'Configuration ' + [name] + ' not enabled'
		, NULL
		, 'Backup compression allows for smaller and faster backup files.'
		, 'Unless there is blob, image, or XML data in your database, we recommend enabling ' + [name] + ' to get the benefits of compression.'
		, 'https://straightpathsql.com/check/backup-compression'
	FROM sys.configurations
	WHERE [name] IN (
		'backup compression'
		, 'backup compression default'
		)
		AND value_in_use = 0;

	IF @SQLVersionMajor > 11 BEGIN
		/* Backup Checksum not enabled */
		INSERT #Results
		SELECT 
			2
			, 209
			, 2
			, 'Backup checksum'
			, 'Configuration ' + [name] + ' not enabled'
			, NULL
			, 'Backup checksum helps validate the consistency of backup files.'
			, 'We recommend enabling ' + [name] + ' to complete checksum verification by default and reduce the likelihood of any corrupted backup files.'
			, 'https://straightpathsql.com/check/backup-checksum'
		FROM sys.configurations
		WHERE [name] IN (
			'backup checksum'
			, 'backup checksum default'
			)
			AND value_in_use = 0;

		/* Backups without checksum */
		;WITH BackupMissingChecksum AS (
			SELECT
				bh.DatabaseName
				, COUNT(bh.BackupSetID) AS NumberOfBackups
			FROM #BackupHistory bh
			WHERE bh.BackupChecksum = 0
				AND bh.IsCopyOnly = 0
				AND bh.BackupStartDate >= @StartDate
				AND bh.BackupStartDate <= @EndDate
			GROUP BY bh.DatabaseName
			)

		INSERT #Results
		SELECT
			2
			, 202
			, 2
			, 'Backups without checksum'
			, 'Recent backups created without using checksum'
			, DatabaseName
			, 'The database ' + bmc.DatabaseName + ' has had ' + CAST(bmc.NumberOfBackups AS VARCHAR(9)) + ' recent backups without a checksum.'
			, 'We recommend verifying all backups with checksum to reduce the likelihood of any corrupted backup files.'
			, 'https://straightpathsql.com/check/backup-checksum'
		FROM BackupMissingChecksum bmc
		WHERE DatabaseName = COALESCE(@DatabaseName, DatabaseName);

		END

    /* Missing Full backups */
	INSERT #Results
	SELECT
		2
		, 203
		, 1
		, 'Missing full backup'
		, 'Database missing full backups'
		, d.[name]
		, 'The database ' + d.[name] + ' has not had any full backups.'
		, 'If the data in this database is important, you need to make a full backup to recover the data.'
		, 'https://straightpathsql.com/check/missing-backups'
	FROM master.sys.databases d
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	LEFT JOIN #LastBackup lb 
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = lb.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND lb.BackupType = 'D'
		AND lb.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
	WHERE d.database_id <> 2  /* exclude tempdb */
	    AND d.[name] = COALESCE(@DatabaseName, d.[name])
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
		AND d.source_database_id IS NULL /* Excludes database snapshots */
		AND lb.LastBackupDate IS NULL
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1;

    /* Missing log backups */
	INSERT #Results
	SELECT
		2
		, 204
		, 1
		, 'Missing log backup'
		, 'Database missing log backups'
		, d.[name]
		, 'The database ' + d.[name] + ' is in Full or Bulk Logged recovery model but has not had any transaction log backups.'
		, 'If point in time recovery is important to you, you need to take regular log backups.'
		, 'https://straightpathsql.com/check/missing-backups'
	FROM master.sys.databases d
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	LEFT JOIN #LastBackup lb 
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = lb.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND lb.BackupType = 'L'
		AND lb.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
	WHERE d.database_id <> 2  /* exclude tempdb */
	    AND d.[name] = COALESCE(@DatabaseName, d.[name])
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
		AND d.source_database_id IS NULL /* Excludes database snapshots */
		AND lb.LastBackupDate IS NULL
		AND d.recovery_model_desc <> 'SIMPLE'
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1;

    /* No recent Full backups */
	INSERT #Results
	SELECT
		2
		, 205
		, 1
		, 'No recent full backup'
		, 'No full backup in the last 7 days'
        , d.[name]
		, 'The database ' + d.[name] + ' has not had any full backups in over a week.'
		, 'If the data in this database is important, you need to make regular full backups to recover the data.'
		, 'https://straightpathsql.com/check/recovery-point-objective'
	FROM master.sys.databases d
	INNER JOIN #LastBackup lb
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = lb.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND lb.BackupType = 'D'
		AND lb.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	WHERE d.database_id <> 2  /* exclude tempdb */
	    AND d.[name] = COALESCE(@DatabaseName, d.[name])
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1
		AND lb.LastBackupDate <= DATEADD(dd, -7, GETDATE());

    /* No recent log backups */
	INSERT #Results
	SELECT
		2
		, 206
		, 1
		, 'No recent log backup'
		, 'No log backup in the last day'
		, d.[name]
		, 'The database ' + d.[name] + ' is in Full or Bulk Logged recovery model but has not had any transaction log backups in the last 24 hours.'
		, 'If point in time recovery is important to you, you need to take regular log backups.'
		, 'https://straightpathsql.com/check/recovery-point-objective'
	FROM master.sys.databases d
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	INNER JOIN #LastBackup lb
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = lb.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND lb.BackupType = 'L'
		AND lb.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
	WHERE d.database_id <> 2  /* exclude tempdb */
	    AND lb.DatabaseName = COALESCE(@DatabaseName, lb.DatabaseName)
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
		AND d.source_database_id IS NULL /* Excludes database snapshots */
		AND d.recovery_model_desc <> 'SIMPLE'
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1
		AND lb.LastBackupDate <= DATEADD(hh, -24, GETDATE());

    /* Split backup chain */
	;WITH BackupPathCount AS (
	SELECT
		bh.InstanceName
		, bh.DatabaseName
		, bh.BackupType
		, COUNT(DISTINCT(COALESCE(bp.BackupPath, bh.DeviceType))) AS NumberOfPaths
	FROM #BackupPath bp
	INNER JOIN #BackupHistory bh
		ON bp.BackupSetID = bh.BackupSetID
	    AND bh.DatabaseName = COALESCE(@DatabaseName, bh.DatabaseName)
	WHERE bh.IsCopyOnly = 0
	    AND bh.BackupStartDate >= @StartDate
		AND bh.BackupStartDate <= @EndDate
	GROUP BY
		bh.InstanceName
		, bh.DatabaseName
		, bh.BackupType
    )

	INSERT #Results
	SELECT
		2
		, 201
		, 1
		, 'Split backup chain'
		, 'Databases with backups in more than one location will be difficult to restore.'
		, bpc.DatabaseName
		, 'The database ' + bpc.DatabaseName + ' appears to have a split backup chain for ' 
		    + CASE bpc.BackupType
			    WHEN 'D' THEN 'Full'
			    WHEN 'I' THEN 'Differential'
			    WHEN 'L' THEN 'Transaction Log'
			    END
			+ ' backups.'
		, 'We recommend having your backups in a single location, because split backup chains can create a headache when you need to restore.'
		, 'https://straightpathsql.com/check/split-backup-chain'
	FROM BackupPathCount bpc
	WHERE bpc.NumberOfPaths > 1;


	/* check for TDE certificate backup */
	INSERT #Results
	SELECT
		2
		, 211
		, 1
		, 'TDE certificate never backed up'
		, 'The transparent data encryption (TDE) certificate required for restoring has never been backed up.'
		, db_name(d.database_id)
		, 'The certificate ' + c.name + ' used to encrypt database ' + db_name(d.database_id) + ' has never been backed up'
		, 'Make a backup of your current certificate and store it in a secure location in case you need to restore this encrypted database.'
		, 'https://straightpathsql.com/check/no-recent-tde-certificate-backup/'
	FROM sys.certificates c 
	INNER JOIN sys.dm_database_encryption_keys d 
		ON c.thumbprint = d.encryptor_thumbprint
	WHERE c.pvt_key_last_backup_date IS NULL;

	INSERT #Results
	SELECT
		2
		, 211
		, 1
		, 'TDE certificate not backed up recently'
		, 'The transparent data encryption (TDE) certificate required for restoring has not been backed up in the last 90 days.'
		, db_name(d.database_id)
		, 'The certificate ' + c.name + ' used to encrypt database ' + db_name(d.database_id) + ' has not been backed up since: ' + CAST(c.pvt_key_last_backup_date AS VARCHAR(100))
		, 'Make sure you have a recent backup of your certificate in a secure location in case you need to restore your encrypted database.'
		, 'https://straightpathsql.com/check/no-recent-tde-certificate-backup/'
	FROM sys.certificates c 
	INNER JOIN sys.dm_database_encryption_keys d 
		ON c.thumbprint = d.encryptor_thumbprint
	WHERE c.pvt_key_last_backup_date <= DATEADD(dd, -90, GETDATE());


	/* check TDE certificate expiration dates */
	INSERT #Results
	SELECT
		2
		, 213
		, 2
		, 'TDE certificate set to expire'
		, 'The trasparent data encryption (TDE) certificate required for restoring is set to expire.'
		, db_name(d.database_id)
		, 'The certificate ' + c.name + ' used to encrypt database ' + db_name(d.database_id) + ' is set to expire on: ' + CAST(c.expiry_date AS VARCHAR(100))
		, 'Although you will still be able to backup or restore your encrypted database with an expired certificate, these should be changed regularly like passwords.'
		, 'https://straightpathsql.com/check/tde-certificate-expiration-date/'
	FROM sys.certificates c 
	INNER JOIN sys.dm_database_encryption_keys d 
		ON c.thumbprint = d.encryptor_thumbprint;


	/* check for database backup certificate backup */
	IF @SQLVersionMajor >= 12 BEGIN

		SET @SQL = '
		SELECT DISTINCT
			2
			, 210
			, 1
			, ''Database backup certificate never been backed up.''
			, ''A certificate used for backups has never been backed up.''
			, b.[database_name]
			, ''The certificate '' + c.name + '' used to encrypt database backups for '' + b.[database_name] + '' has never been backed up.''
			, ''Make sure you have a recent backup of your certificate in a secure location in case you need to restore encrypted database backups.''
			, ''https://straightpathsql.com/check/missing-database-backup-certificate-backup/''
		FROM sys.certificates c 
		INNER JOIN msdb.dbo.backupset b
			ON c.thumbprint = b.encryptor_thumbprint
		WHERE c.pvt_key_last_backup_date IS NULL
			AND b.encryptor_thumbprint IS NOT NULL;';

		INSERT #Results
		EXEC sp_executesql @SQL


		SET @SQL = '
		SELECT DISTINCT
			2
			, 210
			, 1
			, ''Database backup certificate not backed up recently.''
			, ''A certificate used for backups has not been backed up in the last 90 days.''
			, b.[database_name]
			, ''The certificate '' + c.name + '' used to encrypt database backups for '' + b.[database_name] + '' has not been backed up since: '' + CAST(c.pvt_key_last_backup_date AS VARCHAR(100))
			, ''Make sure you have a recent backup of your certificate in a secure location in case you need to restore encrypted database backups.''
			, ''https://straightpathsql.com/check/missing-database-backup-certificate-backup/''
		FROM sys.certificates c 
		INNER JOIN msdb.dbo.backupset b
			ON c.thumbprint = b.encryptor_thumbprint
		WHERE c.pvt_key_last_backup_date <= DATEADD(dd, -90, GETDATE())
			AND b.encryptor_thumbprint IS NOT NULL;';

		INSERT #Results
		EXEC sp_executesql @SQL


	/* check for database backup certificate expiration dates */
		SET @SQL = '
		SELECT DISTINCT
			2
			, 212
			, 1
			, ''Database backup certificate set to expire.''
			, ''A certificate used for backups is set to expire.''
			, b.[database_name]
			, ''The certificate '' + c.name + '' used to encrypt database '' + b.[database_name] + '' is set to expire on: '' + CAST(c.expiry_date AS VARCHAR(100))
			, ''You will not be able to backup or restore your encrypted database backups with an expired certificate, so these should be changed regularly like passwords.''
			, ''https://straightpathsql.com/check/database-backup-certificate-expiration-date/''
		FROM sys.certificates c 
		INNER JOIN msdb.dbo.backupset b
			ON c.thumbprint = b.encryptor_thumbprint
		WHERE b.encryptor_thumbprint IS NOT NULL;';

		INSERT #Results
		EXEC sp_executesql @SQL

		END

	/* check for failed backups */
	IF OBJECT_ID('tempdb..#FailedBackups') IS NOT NULL
		DROP TABLE #FailedBackups;

	CREATE TABLE #FailedBackups (
		LogDate DATETIME
		, Processinfo VARCHAR(255)
        , LogText VARCHAR(1000)
		);

    SET @SQL = 'EXEC master.sys.sp_readerrorlog 0, 1, N''BACKUP failed to complete the command BACKUP'''

	INSERT #FailedBackups
	EXEC sp_executesql @SQL

;WITH FailedBackupRaw AS (
		SELECT
			fb.LogDate
			, fb.LogText
			, CASE
				WHEN fb.LogText LIKE '%BACKUP DATABASE %'
					THEN CHARINDEX('BACKUP DATABASE ', fb.LogText) + 16   /* length of 'BACKUP DATABASE ' */
				WHEN fb.LogText LIKE '%BACKUP LOG %'
					THEN CHARINDEX('BACKUP LOG ', fb.LogText) + 11        /* length of 'BACKUP LOG ' */
				END AS NameStart
		FROM #FailedBackups fb
		WHERE fb.LogDate >= @StartDate
			AND fb.LogDate <= @EndDate
			AND (fb.LogText LIKE '%BACKUP DATABASE %' OR fb.LogText LIKE '%BACKUP LOG %')
	),
	FailedBackupParsed AS (
		SELECT
			LogDate
			, LogText
			, NameStart
			, NULLIF(CHARINDEX('.', LogText, NameStart), 0) AS NameEnd   /* first period after the name begins */
		FROM FailedBackupRaw
		WHERE NameStart IS NOT NULL
	),
	FailedBackup AS (
		SELECT DISTINCT
			LogDate
			, LEFT(LogText, NameEnd) AS Issue
			, REPLACE(REPLACE(LTRIM(RTRIM(SUBSTRING(LogText, NameStart, NameEnd - NameStart))), '[', ''), ']', '') AS DatabaseName
		FROM FailedBackupParsed
		WHERE NameEnd IS NOT NULL
			AND NameEnd > NameStart   /* guarantees a positive SUBSTRING length */
	)

	INSERT #Results
	SELECT
		2
		, 207
		, 1
		, 'Failed database backups'
		, 'Failed backup occurred on ' + CONVERT(VARCHAR(10), fb.LogDate, 101)
		, fb.DatabaseName
		, fb.Issue
		, 'Review the SQL Server Log to find out more about any failed backups.'
		, 'https://straightpathsql.com/check/failed-backup'
	FROM FailedBackup fb
	WHERE fb.DatabaseName = COALESCE(@DatabaseName, fb.DatabaseName);

	/* find databases not meeting Recovery Point Objective (RPO) */
	IF @RPO IS NOT NULL BEGIN
		;WITH MostRecentBackup AS (
		SELECT
			 d.[name] AS DatabaseName
			, COALESCE(MAX(lb.LastBackupDate), '1/1/1900 00:00:00') AS LastBackupDate
		FROM master.sys.databases d
		LEFT JOIN #LastBackup lb
			ON d.[name] = lb.DatabaseName
		WHERE d.[name] = COALESCE(@DatabaseName, d.[name]) 
		GROUP BY
			d.[name]
		)

		INSERT #Results
		SELECT
			2
			, 214
			, 1
			, 'Missed RPO'
			, 'Database not meeting the Recovery Point Objective(RPO).'
			, DatabaseName
			, 'The database [' + DatabaseName + '] has an RPO of ' + CONVERT(VARCHAR(10), @RPO) + ' minutes, but it has not been backed up in the last '
				+ CONVERT(VARCHAR(10), DATEDIFF(mi, LastBackupDate, GETDATE())) + ' minutes.'
			, 'Check the backup schedule for this database to make sure you are meeting the RPO.'
			, 'https://straightpathsql.com/check/recovery-point-objective'
		FROM MostRecentBackup
		WHERE LastBackupDate <> '1/1/1900 00:00:00'
			AND DATEDIFF(mi, LastBackupDate, GETDATE()) > @RPO

		UNION

		SELECT
			2
			, 214
			, 1
			, 'Missed RPO'
			, 'Database not meeting the Recovery Point Objective(RPO).'
			, DatabaseName
			, 'The database [' + DatabaseName + '] has an RPO of ' + CONVERT(VARCHAR(10), @RPO) + ' minutes, but it has never been backed up.'
			, 'Check the backup schedule for this database to make sure you are meeting the RPO.'
			, 'https://straightpathsql.com/check/recovery-point-objective'
		FROM MostRecentBackup
		WHERE LastBackupDate = '1/1/1900 00:00:00';
		
		END

	/* backup history not purged */
	INSERT #Results
	SELECT TOP 1
		2
		, 216
		, 2
		, 'Backup history not purged'
		, 'The backup history in msdb is retained back to ['
			+ CAST(backup_start_date AS VARCHAR(20)) + '].'
		, 'msdb'
		, 'Not purging the backup history can cause the msdb database to grow significantly over time, and can make it difficult to find recent backup and restore history.'
		, 'Schedule a process like a SQL Agent job to purge your backup history periodically using [sp_delete_backuphistory].'
		, 'https://straightpathsql.com/check/backup-history-not-purged'
	FROM msdb.dbo.backupset
	WHERE backup_start_date <= DATEADD(dd, -90, GETDATE())
	ORDER BY backup_start_date ASC;

	/* check for high VLF count */
	IF @SQLVersionMajor >= 13 BEGIN

		/* Build the safe list first so dm_db_log_stats is never called against
		   an inaccessible database (offline, restoring, recovery pending, a
		   snapshot, or a non-readable AG secondary), which would error and
		   abort the INSERT. */
		IF OBJECT_ID('tempdb..#VLFDatabases') IS NOT NULL
			DROP TABLE #VLFDatabases;

		CREATE TABLE #VLFDatabases (
			DatabaseID INT
			, DatabaseName NVARCHAR(128)
			);

		INSERT #VLFDatabases (DatabaseID, DatabaseName)
		SELECT d.database_id, d.[name]
		FROM sys.databases d
		WHERE d.state = 0                                                    /* ONLINE only */
			AND d.source_database_id IS NULL                                 /* exclude snapshots */
			AND d.is_in_standby = 0                                          /* exclude log shipping standby */
			AND DATABASEPROPERTYEX(d.[name], 'Updateability') = 'READ_WRITE' /* skip read-only and non-readable secondaries */
			AND d.[name] = COALESCE(@DatabaseName, d.[name]);

		INSERT #Results
		SELECT
			2
			, 217
			, 2
			, 'High VLF count'
			, 'The database ' + vd.DatabaseName + ' has ' + CONVERT(VARCHAR(10), ls.total_vlf_count) + ' virtual log files.'
			, vd.DatabaseName
			, 'A high number of VLFs can cause performance issues, especially for backup/restore operations and failovers.'
			, 'Consider resizing the log file to reduce the number of VLFs, and then grow it back out to an appropriate size with less VLFs.'
			, 'https://straightpathsql.com/check/virtual-log-files/'
		FROM #VLFDatabases vd
		CROSS APPLY sys.dm_db_log_stats(vd.DatabaseID) ls
		WHERE ls.total_vlf_count > 200;

		END;

	/* Log backups to NUL */
	;WITH LogBackupsToNul AS (
		SELECT
			bh.DatabaseName
			, COUNT(bh.BackupSetID) AS NumberOfBackups
			, MAX(bh.BackupStartDate) AS LastNulBackup
		FROM #BackupHistory bh
		WHERE bh.BackupType = 'L'
			AND bh.IsCopyOnly = 0
			AND bh.BackupStartDate >= @StartDate
			AND bh.BackupStartDate <= @EndDate
			AND (
				UPPER(LTRIM(RTRIM(bh.PhysicalDevice))) = 'NUL'
				OR UPPER(LTRIM(RTRIM(bh.PhysicalDevice))) = 'NUL:'
			)
		GROUP BY bh.DatabaseName
	)

	INSERT #Results
	SELECT
		2
		, 218
		, 1
		, 'Log backup to NUL'
		, 'Log backups written to NUL device.'
		, lbn.DatabaseName
		, 'The database [' + lbn.DatabaseName + '] has had ' + CAST(lbn.NumberOfBackups AS VARCHAR(9)) + ' log backup(s) written to the NUL device. Most recent: ' + CONVERT(VARCHAR(20), lbn.LastNulBackup, 120) + '.'
		, 'Backing up the transaction log to NUL discards the log records and breaks the log backup chain, making point-in-time recovery impossible. Investigate who or what is running BACKUP LOG ... TO DISK = ''NUL'' and stop it immediately.'
		, 'https://straightpathsql.com/check/backup-to-nul'
	FROM LogBackupsToNul lbn
	WHERE lbn.DatabaseName = COALESCE(@DatabaseName, lbn.DatabaseName);

/* password protected databases - discontinued in SQL Server 2012 */
IF @SQLVersionMajor < 11 BEGIN
	INSERT #Results
	SELECT DISTINCT
		2
		, 215
		, 2
		, 'Password protected backups'
		, 'The database [' + DatabaseName + '] has had password protected backups recently.'
		, DatabaseName
		, 'If you do not have the password used to back up the database, you will not be able to restore it.'
		, 'Make sure the password used to back up this database is stored where administrators can access it if needed.'
		, 'https://straightpathsql.com/check/password-protected-backup'
	FROM #BackupHistory
	WHERE IsPasswordProtected = 1;
	END

/* Missing integrity checks */
IF OBJECT_ID('tempdb..#DBINFO') IS NOT NULL
	DROP TABLE #DBINFO;

CREATE TABLE #DBINFO (
	ID INT IDENTITY(1, 1) PRIMARY KEY 
	, ParentObject VARCHAR(255)
	, [Object] VARCHAR(255)
	, Field VARCHAR(255) 
	, [Value] VARCHAR(255) 
	, DatabaseName NVARCHAR(128) NULL
	);

EXEC sp_MSforeachdb N'USE [?];
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
	INSERT #DBINFO (ParentObject, Object, Field, Value)
	EXEC (''DBCC DBINFO() With TableResults, NO_INFOMSGS'');
	UPDATE #DBINFO SET DatabaseName = N''?'' WHERE DatabaseName IS NULL OPTION (RECOMPILE);';

WITH CHECKDB AS (
	SELECT DISTINCT
		Field ,
		Value ,
		DatabaseName
	FROM #DBINFO x
	INNER JOIN master.sys.databases d ON x.DatabaseName = d.name
	WHERE Field = 'dbi_dbccLastKnownGood'
	)

INSERT #Results
SELECT
	5
	, 503
	, 1
	, 'Missing integrity checks'
	, 'Database missing recent integrity checks'
	, DatabaseName
	, 'The database ' + DatabaseName + ' has not had any integrity checks in the last 2 weeks.'
	, 'Regularly run DBCC CHECKDB to check for integrity issues that could indicate corruption.'
	, ''		
FROM CHECKDB
WHERE DatabaseName <> 'tempdb'
	AND DatabaseName NOT IN ( SELECT [name] FROM master.sys.databases WHERE is_read_only = 1)
	AND CONVERT(DATETIME, CHECKDB.[Value], 121) < DATEADD(DD, -14, CURRENT_TIMESTAMP)
	AND DatabaseName = COALESCE(@DatabaseName, DatabaseName);

/* stopped SQL Agent */
INSERT #Results
SELECT
	6
	, 628
	, 1
	, 'SQL Server Agent offline'
	, 'The [' + servicename + '] service is currently offline.' 
	, NULL
	, 'This service is often responsible for running scheduled jobs, including backups and maintenance tasks. If it is offline, these tasks will not run.'
	, 'Review the service status in Configuration Manager and start it if desired. The current startup type is [' + startup_type_desc + '].'
	, 'https://straightpathsql.com/check/sql-agent-offline'
FROM master.sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent%'
AND status_desc <> 'Running'
AND CAST(SERVERPROPERTY('Edition') AS VARCHAR(1000)) NOT LIKE '%xpress%'; /* exclude Express Edition, which doesn't have SQL Agent */

/* Check for I/O freezes */
IF OBJECT_ID('tempdb..#ErrorLog') IS NOT NULL DROP TABLE #ErrorLog;
CREATE TABLE #ErrorLog (
    LogDate DATETIME2(3),
    ProcessInfo NVARCHAR(4000),
    LogMessage NVARCHAR(4000)
);

/* read current SQL Server error log (0 = current, 1 = error log type) */
INSERT INTO #ErrorLog
EXEC sys.xp_readerrorlog 0, 1;

WITH Events AS (
    SELECT
        LogDate,
        LogMessage,
        /* normalize message and extract database name */
        CASE
            WHEN LogMessage LIKE 'I/O is frozen on database %' THEN
                LTRIM(RTRIM(SUBSTRING(LogMessage, CHARINDEX('I/O is frozen on database', LogMessage) + 26,
                    CHARINDEX('.', LogMessage, CHARINDEX('I/O is frozen on database', LogMessage)) 
                    - (CHARINDEX('I/O is frozen on database', LogMessage) + 26))))
            WHEN LogMessage LIKE 'I/O was resumed on database %' THEN
                LTRIM(RTRIM(SUBSTRING(LogMessage, CHARINDEX('I/O was resumed on database', LogMessage) + 28,
                    CHARINDEX('.', LogMessage, CHARINDEX('I/O was resumed on database', LogMessage)) 
                    - (CHARINDEX('I/O was resumed on database', LogMessage) + 28))))
            ELSE NULL
        END AS DatabaseName,
        CASE
            WHEN LogMessage LIKE 'I/O is frozen on database %' THEN 'Frozen'
            WHEN LogMessage LIKE 'I/O was resumed on database %' THEN 'Resumed'
            ELSE NULL
        END AS EventType
    FROM #ErrorLog
    WHERE LogMessage LIKE 'I/O is frozen on database %' OR LogMessage LIKE 'I/O was resumed on database %'
),
Paired AS (
    /* for each Frozen event find the next Resumed event for the same database */
    SELECT
        f.DatabaseName,
        f.LogDate AS FrozenAt,
        r.LogDate AS ResumedAt,
        DATEDIFF(MILLISECOND, f.LogDate, r.LogDate) AS DurationMs
    FROM Events f
    OUTER APPLY (
        SELECT TOP (1) r.LogDate
        FROM Events r
        WHERE r.EventType = 'Resumed'
          AND r.DatabaseName = f.DatabaseName
          AND r.LogDate > f.LogDate
        ORDER BY r.LogDate ASC
    ) r
    WHERE f.EventType = 'Frozen'
      AND r.LogDate IS NOT NULL
)
INSERT #Results
SELECT
    7
    , 739
    , 2
    , 'I/O freeze detected'
    , 'There have been at least ' + CAST(COUNT(1) AS VARCHAR(4)) + ' I/O freeze(s) against the [' + DatabaseName + '] database with an average duration of '+ CAST(AVG(CAST(DurationMs AS FLOAT)) AS VARCHAR(10)) + ' milliseconds.'
    , DatabaseName
    , 'I/O freezes can negatively impact your database performance. These are usually caused by VM backups or other backups that use Volume Shadowcopy Services (VSS).'
    , 'Ensure you understand how VSS backups are used in your environment.'
    , ''
FROM Paired
GROUP BY DatabaseName

	SELECT
		r.Importance
		, r.CheckName
		, r.Issue
		, r.DatabaseName
		, r.Details
		, r.ActionStep    
		, r.ReadMoreURL
		, r.CheckID
	FROM #Results r
	INNER JOIN #Category c
		ON r.CategoryID = c.CategoryID
	WHERE r.CategoryID <> 1
	ORDER BY
		r.Importance
		, c.CategoryID
		, r.CheckID
		, r.Issue
		, r.DatabaseName;

END
GO
