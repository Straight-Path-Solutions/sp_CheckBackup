# sp_CheckBackup
Hello, and welcome to the GitHub repository for sp_CheckBackup! This is a free tool from [Straight Path Solutions](https://straightpathsql.com/) for SQL Server Database Administrators (or people who play DBA at their organization) to use for detecting recoverability vulnerabilities and discrepancies in their SQL Server instances.

# Why would you use sp_CheckBackup?

Here at Straight Path Solutions, we're big fans of community tools like [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive/releases), [Brent Ozar's First Responder's Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/releases), and [Erik Darling's suite of helpful stored procedures](https://github.com/erikdarlingdata/DarlingData).  As database administrators who are constantly looking at new clients and new servers, we wished there was a tool to quickly give an overview of potential recoverability issues. We didn't find one, so we made one.

# What does sp_CheckBackup do?

This tool will allow you to review your SQL Server backup history quickly and easily, and also to identify potential issues with your backups like missing backups, failed backups, and split backup chains.
This tool has several modes that present a different set of data, depending on what you want to examine.<p>

**Mode 0: A check for problems like…** <br>
• Backup compression configuration disabled<br>
• Backup checksum configuration disabled<br>
• Backups made without using checksum<br>
• Databases missing full or log backups<br>
• Databases that haven’t had any full backups in over a week<br>
• Databases that haven’t had any log backups in over an hour<br>
• Split backup chains that could complicate recoverability<br>
• TDE certificates that haven’t been backed up recently<br>
• TDE certificates that have expired<br>
• Databases backup certificates that haven’t been backed up recently<br>
• Databases backup certificates that have expired<br>
• Recent failed backups<br>
<br>
**Mode 1: A summary of backups for all databases including…** <br>
• Current recovery model<br>
• Minutes since last backup (Recovery point)<br>
• Last full backup start, finish, and duration<br>
• Last full backup number of files and size<br>
• Last full backup type (Disk, Virtual disk, etc.) and location<br>
• Last differential backup start, finish, and duration<br>
• Last differential backup number of files and size<br>
• Last differential backup type (Disk, Virtual disk, etc.) and location<br>
• Last log backup start, finish, and duration<br>
• Last log backup number of files and size<br>
• Last log backup type (Disk, Virtual disk, etc.) and location<br>
<br>
**Mode 2: A detailed look at every backup file most info from Mode 1 as well as…** <br>
• Is copy only<br>
• Is snapshot backup<br>
• Is password protected<br>
• Backup completed using checksum<br>
• Physical device name for backups<br>
• User name used for backup<br>
• Availability group name, if applicable<br>
<br>
**Mode 3: A check for split backups that could complicate recovery including…** <br>
• Backup type<br>
• Number of different locations (file paths) used for backups<br>
• Location (file path) used for backups<br>
<br>
**Mode 4: A check for all results from Mode 1-3, returning 3 result sets** <br>
<br>
Using each of these Modes, you should be able to quickly identify recoverability issues with your backups and focus on facts about them to help you resolve any issue. <br>
<br>
**Mode 5: A check for restores** <br>
<br>
Provide information on recent database restores that have occurred on this instance. <br>
<br>
# How do I use it?
Execute the script to create sp_CheckBackup in the database of your choice, although we would recommend the master so you can call it from the context of any database.
<p>
Executing it without using parameters will return two results sets:<p>
• The results of Mode 1, ordered by database name<br>
• The results of Mode 0, ordered by Importance
<p>
Although you can simply execute it as is, there are several parameters you cna use.<p>

**@Help** - the default is 0, but setting this to 1 will return some helpful information about sp_CheckBackup and its usage in case you aren't able to read this web page.<p>

**@Mode** – see the previous few paragraphs to decide which Mode you want to use.<p>

**@ShowCopyOnly** - the default is 1, which includes copy only backups from the results. If you want to exclude copy only backups from the results, set this to 0.<p>

**@DatabaseName** - the default results include information for all databases, but use this parameter if you have a specific database that you are reviewing. Using this parameter can greatly reduce the results.<p>

**@BackupType** - the default results include information for all three kinds of backups, but use this parameter if you have a specific type of backup that you are reviewing. Use “F” for full backups, “D” for differential backups, and “T” for transaction log backups. Using this parameter can also greatly reduce the results.<p>

**@StartDate** - the default is to return results from backups completed in the last 7 days, but use this to filter results from a different time period.<p>

**@EndDate** - the default is to return results from the last 7 days, but use this as well to filter results from a different time period.<p>

**@RPO** - the default is NULL, but you can use this to check to see if your backups are within your Recovery Point Objective (RPO). If not, they will show up in the Mode 0 issues results.<p>

**@Override** - by default the stored procedure will quit and notify you if you run it on a database with 50 or more databases. Use this parameter to override that and run the full check.<p>

# What do the Importance levels in Mode 0 mean?

**1 - High**. This is stuff that prevents recoverability, including databases without backups or that have not had recent backups, or encryption certificates that have not been backed up.

**2 - Medium**. This is the stuff that can complicate recovery, like split backup chains or backups without checksum checks.

**3 - Low**. This is stuff that could be affecting backup or restore performance, like having backup compression disabled.

# What are the requirements to use sp_CheckBackup?

There are two requirements.<p>

**1. You need to have VIEW SERVER STATE permissions**. This tool uses several system tables and DMVs to collect information about your SQL Server backups, but VIEW SERVER STATE permissions will allow you to read all necessary information.<p>

**2. Your SQL Server instance should be using SQL Server 2014 or higher**. If you are using an earlier version, execution of the stored procedure will skip some checks because some of the DMVs used don't exist in earlier versions.<p>


