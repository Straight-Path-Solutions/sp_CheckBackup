IF OBJECT_ID('dbo.sp_CheckBackup') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_CheckBackup AS RETURN 0;');
GO


ALTER PROCEDURE dbo.sp_CheckBackup
    @Mode TINYINT = 99 
    , @ShowCopyOnly BIT = 0
    , @DatabaseName NVARCHAR(128) = NULL
	, @BackupType CHAR(1) = NULL
	, @StartDate DATETIME = NULL
	, @EndDate DATETIME = NULL
	, @Help BIT = 0

WITH RECOMPILE
AS
SET NOCOUNT ON;

DECLARE 
    @Version VARCHAR(10) = NULL
	, @VersionDate DATETIME = NULL

SELECT
    @Version = '1.0'
    , @VersionDate = '20240727';

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
    that means SQL Server 2014 or later.
    - sp_CheckBackup will work with some earlier versions of SQL Server, but it 
    will skip a few checks. The results should still be valid and helpful, but you
    should really consider upgrading to a newer version.
    
    Parameters:

    @Mode  0=Show only problematic issues, unfiltered
           1=Summary one fact-filled row per database(DEFAULT), may be filtered
		   2=Detail, all backup history, may be filtered
		   3=Backup chain check, may be filtered, look for any number > 1
		   4=Shows results of 1, 2, and 3, and may be filtered

    @ShowCopyOnly 0=Hide Copy Only backups(DEFAULT), 1=Show Copy Only backups

    @DatabaseName for filtering on one specific database

	@BackupType for filtering, F = Full, D = Differential, L = Log

	@StartDate for filtering

	@EndDate for filtering

    MIT License
    
    Copyright for portions of sp_CheckBackup are also held by Brent Ozar Unlimited
    as part of sp_Blitz and are provided under the MIT license:
    https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
    	
    All other copyrights for sp_CheckBackup are held by Straight Path Solutions.
    
    Copyright 2024 Straight Path IT Solutions, LLC
    
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

/* set some defaults */

/* Default @StartDate of 7 days before now */
IF @StartDate IS NULL
    SET @StartDate = DATEADD(dd, -30, GETDATE());

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
	, ('2022', 16);

/* SQL Server version */
SELECT @SQLVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));

SELECT 
	@SQLVersionMajor = SUBSTRING(@SQLVersion, 1,CHARINDEX('.', @SQLVersion) + 1 )
	, @SQLVersionMinor = PARSENAME(CONVERT(varchar(32), @SQLVersion), 2);


/* grab the backup history */
IF OBJECT_ID('tempdb..#BackupHistory') IS NOT NULL
	DROP TABLE #BackupHistory;

CREATE TABLE #BackupHistory (
	BackupSetID INT
	, InstanceName NVARCHAR(255)
	, DatabaseID INT
	, DatabaseName NVARCHAR(255)
	, RecoveryModel CHAR(1)
    , BackupType CHAR(1)
	, IsCopyOnly BIT
	, IsSnapshot BIT
	, IsPasswordProtected BIT
	, BackupChecksum BIT
	, BackupStartDate DATETIME
	, BackupFinishDate DATETIME
	, BackupSize NUMERIC(20,0)
	, MediaSetID INT
	, FamilySequenceNumber TINYINT
	, PhysicalDevice NVARCHAR(260)
	, LogicalDevice NVARCHAR(128)
	, DeviceType VARCHAR(30)
	, UserName NVARCHAR(255)
	);

CREATE CLUSTERED INDEX PK_BackupHistory
ON #BackupHistory (BackupSetID);

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
	, s.has_backup_checksums
	, s.backup_start_date
	, s.backup_finish_date
    , s.backup_size
	, m.media_set_id
	, m.family_sequence_number
	, m.physical_device_name AS PhysicalDevice
	, m.logical_device_name AS LogicalDevice
	, CASE m.device_type
		WHEN 2 THEN 'Disk'
		WHEN 5 THEN 'Tape'
		WHEN 7 THEN 'Virtual Device'
		WHEN 9 THEN 'Azure Storage'
		WHEN 2 THEN 'A permanent Backup Device'
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
	AND s.backup_start_date >= @StartDate
	AND s.backup_start_date <= @EndDate;

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
WHERE bh.FamilySequenceNumber = 1



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


/* Get Availability Group info for SQL Server 2016 and later */
IF SERVERPROPERTY('EngineEdition') <> 8 /* Azure Managed Instances */ BEGIN
	IF @SQLVersionMajor >= 11 BEGIN
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
        LEFT JOIN sys.availability_groups  ag
            ON adc.group_id = ag.group_id
        WHERE d.database_id <> 2 
        	AND d.state NOT IN (1, 6, 10) 
        	AND d.is_in_standby = 0 
        	AND d.source_database_id IS NULL;'

--SELECT @SQL

        INSERT #AvailabilityGroup
        EXEC sp_executesql @SQL
        END;
    END;



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
			WHERE IsCopyOnly = 0
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
			WHERE IsCopyOnly = 0
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
			WHERE IsCopyOnly = 0
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
		--, CASE ag.IsPreferredBackupReplica
		--	WHEN 1 THEN 'Yes'
		--	WHEN 0 THEN 'No'
		--	ELSE NULL
		--	END AS AvailabilityGroupPreferredBackup
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
		--, s.is_password_Protected
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
		, bh.BackupStartDate
		, bh.BackupFinishDate
		, DATEDIFF(second, bh.BackupStartDate, bh.BackupFinishDate) AS DurationSeconds
		, CAST((bh.BackupSize/bc.NumberOfFiles) / 1048576 AS INT)  AS SizeInMB
		, bh.PhysicalDevice
		, bh.LogicalDevice
		, bh.DeviceType
		, bh.UserName
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
		AND bh.IsCopyOnly = CASE
			WHEN @ShowCopyOnly = 1 THEN bh.IsCopyOnly
			ELSE 0
			END
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
--	, bp.BackupPath
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


/* @Mode = 0 Backup issues */
IF @Mode IN (0,99) BEGIN

	IF OBJECT_ID('tempdb..#Checks') IS NOT NULL
		DROP TABLE #Checks;

	CREATE TABLE #Checks (
		Importance TINYINT
		, DatabaseName VARCHAR(255)
		, Issue VARCHAR(255)
		, Details VARCHAR(1000)
		, ActionStep VARCHAR(1000)
		, ReadMoreURL XML
		);

	/* Backup Compression not enabled */
	INSERT #Checks WITH (TABLOCK)
	SELECT 
		3
		, NULL
		, 'Configuration ' + [name] + ' not enabled'
		, 'Backup compression allows for smaller and faster backup files.'
		, 'Unless there is blob, image, or XML data in your database, we recommend enabling ' + [name] + ' to get the benefits of compression.'
		, 'https://straightpathsql.com/cb/backup-compression'
	FROM sys.configurations
	WHERE [name] IN (
		'backup compression'
		, 'backup compression default'
		)
		AND value_in_use = 0;

	/* Backup Checksum not enabled */
	INSERT #Checks WITH (TABLOCK)
	SELECT 
		2
		, NULL
		, 'Configuration ' + [name] + ' not enabled'
		, 'Backup checksum helps validate the consistency of backup files.'
		, 'We recommend enabling ' + [name] + ' to complete checksum verification by default and reduce the likelihood of any corrupted backup files.'
		, 'https://straightpathsql.com/cb/backup-checksum'
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

	INSERT #Checks WITH (TABLOCK)
	SELECT
		2
		, DatabaseName
		, 'Backups without checksum'
		, 'The database ' + bmc.DatabaseName + ' has had ' + CAST(bmc.NumberOfBackups AS VARCHAR(9)) + ' recent backups without a checksum.'
		, 'We recommend verifying all backups with checksum to reduce the likelihood of any corrupted backup files.'
		, 'https://straightpathsql.com/cb/backup-compression'
    FROM BackupMissingChecksum bmc


    /* Missing Full backups */
	INSERT #Checks WITH (TABLOCK)
	SELECT
		1
		, d.[name]
		, 'Missing Full backup'
		, 'That database ' + d.[name] + ' has not had any full backups.'
		, 'If the data in this database is important, you need to make a full backup to recover the data.'
		, 'https://straightpathsql.com/cb/missing-backups'
	FROM master.sys.databases d
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	LEFT JOIN #BackupHistory bh 
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = bh.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND bh.BackupType = 'D'
		AND bh.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
	WHERE d.database_id <> 2  /* exclude tempdb */
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
		AND d.source_database_id IS NULL /* Excludes database snapshots */
		AND bh.BackupStartDate IS NULL
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1;

    /* Missing log backups */
	INSERT #Checks WITH (TABLOCK)
	SELECT
		1
		, d.[name]
		, 'Missing Log backup'
		, 'That database ' + d.[name] + ' is in Full or Bulk Logged recovery model but has not had any transaction log backups.'
		, 'If point in time recovery is important to you, you need to take regular log backups.'
		, 'https://straightpathsql.com/cb/missing-backups'
	FROM master.sys.databases d
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	LEFT JOIN #BackupHistory bh 
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = bh.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND bh.BackupType = 'L'
		AND bh.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
	WHERE d.database_id <> 2  /* exclude tempdb */
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
		AND d.source_database_id IS NULL /* Excludes database snapshots */
		AND bh.BackupStartDate IS NULL
		AND d.recovery_model_desc <> 'SIMPLE'
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1;

    /* No recent Full backups */
	INSERT #Checks WITH (TABLOCK)
	SELECT
		1
        , d.[name]
		, 'No recent Full backup'
		, 'That database ' + d.[name] + ' has not had any full backups in over a week.'
		, 'If the data in this database is important, you need to make regular full backups to recover the data.'
		, 'https://straightpathsql.com/cb/recovery-point-objective'
	FROM master.sys.databases d
	INNER JOIN #BackupHistory bh 
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = bh.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND bh.BackupType = 'D'
		AND bh.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	WHERE d.database_id <> 2  /* exclude tempdb */
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1
	GROUP BY d.name
	HAVING MAX(bh.BackupStartDate) <= DATEADD(dd, -7, GETDATE());

    /* No recent log backups */
	INSERT #Checks WITH (TABLOCK)
	SELECT
		1
        , d.[name]
		, 'No recent Log backup'
		, 'That database ' + d.[name] + ' is in Full or Bulk Logged recovery model but has not had any transaction log backups in the last hour.'
		, 'If point in time recovery is important to you, you need to take regular log backups.'
		, 'https://straightpathsql.com/cb/recovery-point-objective'
	FROM master.sys.databases d
    INNER JOIN #AvailabilityGroup ag
	    ON d.database_id = ag.DatabaseID
	LEFT JOIN #BackupHistory bh 
		ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = bh.DatabaseName COLLATE SQL_Latin1_General_CP1_CI_AS
		AND bh.BackupType = 'L'
		AND bh.InstanceName = SERVERPROPERTY('ServerName') /*Backupset ran on current server  */
	WHERE d.database_id <> 2  /* exclude tempdb */
		AND d.state NOT IN (1, 6, 10) /* not currently offline or restoring, like log shipping databases */
		AND d.is_in_standby = 0 /* Not a log shipping target database */
		AND d.source_database_id IS NULL /* Excludes database snapshots */
		AND d.recovery_model_desc <> 'SIMPLE'
        AND COALESCE(ag.IsPreferredBackupReplica, 1) = 1
	GROUP BY d.name
	HAVING MAX(bh.BackupStartDate) <= DATEADD(hh, -1, GETDATE());

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
	WHERE bh.IsCopyOnly = 0
	    AND bh.BackupStartDate >= @StartDate
		AND bh.BackupStartDate <= @EndDate
	GROUP BY
		bh.InstanceName
		, bh.DatabaseName
		, bh.BackupType
    )

	INSERT #Checks WITH (TABLOCK)
	SELECT
		2
        , bpc.DatabaseName
		, 'Split backup chain'
		, 'That database ' + bpc.DatabaseName + ' appears to have a split backup chain for ' 
		    + CASE bpc.BackupType
			    WHEN 'D' THEN 'Full'
			    WHEN 'I' THEN 'Differential'
			    WHEN 'L' THEN 'Transaction Log'
			    END
			+ ' backups.'
		, 'We recommend having your backups in a single location, because split backup chains can create a headache when you need to restore.'
		, 'https://straightpathsql.com/cb/split-backup-chain'
	FROM BackupPathCount bpc
	WHERE bpc.NumberOfPaths > 1


	/* check for TDE certificate backup */
	INSERT #Checks WITH (TABLOCK)
	SELECT
		1
		, db_name(d.database_id)
		, 'TDE certificate never backed up'
		, 'The certificate ' + c.name + ' used to encrypt database ' + db_name(d.database_id) + ' has never been backed up'
		, 'Make a backup of your current certificate and store it in a secure location in case you need to restore this encrypted database.'
		, 'https://straightpathsql.com/cb/tde-certificate-no-backup'
	FROM sys.certificates c 
	INNER JOIN sys.dm_database_encryption_keys d 
		ON c.thumbprint = d.encryptor_thumbprint
	WHERE c.pvt_key_last_backup_date IS NULL;

	INSERT #Checks WITH (TABLOCK)
	SELECT
		2
		, db_name(d.database_id)
		, 'TDE certificate not backed up recently'
		, 'The certificate ' + c.name + ' used to encrypt database ' + db_name(d.database_id) + ' has not been backed up since: ' + CAST(c.pvt_key_last_backup_date AS VARCHAR(100))
		, 'Make sure you have a recent backup of your certificate in a secure location in case you need to restore your encrypted database.'
		, 'https://straightpathsql.com/cb/tde-certificate-no-backup'
	FROM sys.certificates c 
	INNER JOIN sys.dm_database_encryption_keys d 
		ON c.thumbprint = d.encryptor_thumbprint
	WHERE c.pvt_key_last_backup_date <= DATEADD(dd, -90, GETDATE());


	/* check TDE certificate expiration dates */
	INSERT #Checks WITH (TABLOCK)
	SELECT
		2
		, db_name(d.database_id)
		, 'TDE certificate set to expire'
		, 'The certificate ' + c.name + ' used to encrypt database ' + db_name(d.database_id) + ' is set to expire on: ' + CAST(c.expiry_date AS VARCHAR(100))
		, 'Although you will still be able to backup or restore your encrypted database with an expired certificate, these should be changed regularly like passwords.'
		, 'https://straightpathsql.com/cb/tde-certificate-expiring'
	FROM sys.certificates c 
	INNER JOIN sys.dm_database_encryption_keys d 
		ON c.thumbprint = d.encryptor_thumbprint;


	/* check for database backup certificate backup */
	IF @SQLVersionMajor >= 12 BEGIN

		SET @SQL = '
		SELECT DISTINCT
			1
			, b.[database_name]
			, ''Database backup certificate never been backed up.''
			, ''The certificate '' + c.name + '' used to encrypt database backups for '' + b.[database_name] + '' has never been backed up.''
			, ''Make sure you have a recent backup of your certificate in a secure location in case you need to restore encrypted database backups.''
			, ''https://straightpathsql.com/cb/database-backup-certificate-no-backup''
		FROM sys.certificates c 
		INNER JOIN msdb.dbo.backupset b
			ON c.thumbprint = b.encryptor_thumbprint
		WHERE c.pvt_key_last_backup_date IS NULL';

		INSERT #Checks WITH (TABLOCK)
		EXEC sp_executesql @SQL


		SET @SQL = '
		SELECT DISTINCT
			1
			, b.[database_name]
			, ''Database backup certificate not backed up recently.''
			, ''The certificate '' + c.name + '' used to encrypt database backups for '' + b.[database_name] + '' has not been backed up since: '' + CAST(c.pvt_key_last_backup_date AS VARCHAR(100))
			, ''Make sure you have a recent backup of your certificate in a secure location in case you need to restore encrypted database backups.''
			, ''https://straightpathsql.com/cb/database-backup-certificate-no-backup''
		FROM sys.certificates c 
		INNER JOIN msdb.dbo.backupset b
			ON c.thumbprint = b.encryptor_thumbprint
		WHERE c.pvt_key_last_backup_date <= DATEADD(dd, -90, GETDATE());';

		INSERT #Checks WITH (TABLOCK)
		EXEC sp_executesql @SQL


	/* check for database backup certificate expiration dates */
		SET @SQL = '
		SELECT DISTINCT
			1
			, b.[database_name]
			, ''Database backup certificate set to expire.''
			, ''The certificate '' + c.name + '' used to encrypt database '' + b.[database_name] + '' is set to expire on: '' + CAST(c.expiry_date AS VARCHAR(100))
			, ''You will not be able to backup or restore your encrypted database backups with an expired certificate, so these should be changed regularly like passwords.''
			, ''https://straightpathsql.com/cb/database-backup-expire''
		FROM sys.certificates c 
		INNER JOIN msdb.dbo.backupset b
			ON c.thumbprint = b.encryptor_thumbprint';

		INSERT #Checks WITH (TABLOCK)
		EXEC sp_executesql @SQL

		END

	/*Check for failed backups */
	IF OBJECT_ID('tempdb..#FailedBackups') IS NOT NULL
		DROP TABLE #FailedBackups;

	CREATE TABLE #FailedBackups (
		LogDate DATETIME
		, Processinfo VARCHAR(255)
        , LogText VARCHAR(1000)
		);

    SET @SQL = 'EXEC master.sys.sp_readerrorlog 0, 1, N''Backup Failed'''

	INSERT #FailedBackups
	EXEC sp_MSforeachdb @SQL

	;WITH FailedBackups AS (
	SELECT DISTINCT
		fb.LogDate
		, LEFT(fb.LogText, CHARINDEX('.', fb.LogText)) AS Issue
		, SUBSTRING (fb.LogText, 55, CHARINDEX('.', fb.LogText)-55) AS DatabaseName
	FROM #FailedBackups fb
	WHERE fb.LogDate >= @StartDate
	    AND fb.LogDate <= @EndDate
    )
	INSERT #Checks WITH (TABLOCK)
	SELECT
		2
		, NULL
		, 'Failed backups'
		, fb.Issue
		, 'Review the SQL Server Log to find out more about any failed backups.'
		, 'https://straightpathsql.com/cb/failed-backup'
	FROM FailedBackups fb

	SELECT
		CASE c.Importance
			WHEN 1 THEN 'High'
			WHEN 2 THEN 'Medium'
			WHEN 3 THEN 'Low'
			END AS Importance
        , c.DatabaseName
		, c.Issue
		, c.Details
		, c.ActionStep
		, c.ReadMoreURL
	FROM #Checks c
	ORDER BY
	    c.Importance
		, c.DatabaseName
		, c.Issue
		, c.Details

	END
GO


