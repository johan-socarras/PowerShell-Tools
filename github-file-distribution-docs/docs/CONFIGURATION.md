# Configuration Guide

This document explains the main configuration values used by the PowerShell scripts.

## Repository Settings

Update these values to match your GitHub repository:

```powershell
$RepoOwner = "your-github-username"
$RepoName  = "your-repository-name"
$Branch    = "main"
```

## Update File

Define the file that will be downloaded by each location:

```powershell
$FileName = "UpdatePackage.txt"
```

The script also requires a SHA-256 checksum URL. Publish a file next to the update, such as `UpdatePackage.txt.sha256`, containing the 64-character SHA-256 value of the update file.

```powershell
$ChecksumUrl = "$DownloadUrl.sha256"
```

Generate and upload the checksum whenever the update file changes:

```powershell
(Get-FileHash .\UpdatePackage.txt -Algorithm SHA256).Hash | Set-Content .\UpdatePackage.txt.sha256 -Encoding ascii
```

Example file types:

- `.txt`
- `.csv`
- `.json`
- `.xml`
- database export files
- configuration files

## Location ID

Each location must use a unique ID:

```powershell
$SiteID = "SITE-001"
```

Examples:

```text
SITE-001
SITE-002
SITE-003
SITE-004
```

The `SiteID` is used to create the daily report file in GitHub.

## Local Destination

The download script stores the update file locally.

Example:

```powershell
$Destination = "$env:ProgramData\FileDistribution\$FileName"
```

This can be changed to another local folder depending on the system where the file needs to be used.

## Pending Reports

If the script cannot send a report to GitHub, it stores the report locally and tries again later.

Example:

```powershell
$PendingQueue = "$env:ProgramData\FileDistribution\PendingReports.json"
```

This helps avoid losing status reports when a location temporarily loses internet access.

## GitHub Token

The token should be read from an environment variable:

```powershell
$GitHubToken = $env:GITHUB_TOKEN
```

Do not write the token directly inside the script.

Both `Download-Update.ps1` and `Generate-DailyReport.ps1` must be configured with the actual report repository owner and name. The placeholder values deliberately stop the script instead of silently failing to report.

