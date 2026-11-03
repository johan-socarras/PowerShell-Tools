# Configuration Guide

This document explains the main configuration values used by the PowerShell scripts.

## Update File

`Download-Update.ps1` downloads the update from `$DownloadUrl`, a raw file URL in the update repository. That repository must be public, because the download does not send a token. `$FileName` is the name of the local copy.

```powershell
$DownloadUrl = "https://raw.githubusercontent.com/example-owner/example-update-repository/main/UpdatePackage.txt"
$FileName    = "UpdatePackage.txt"
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
- configuration files

## Report Repository

Each location writes its daily report to a separate repository. Set `$RepoOwner` and `$RepoName` in both scripts; `$Branch` is only used by `Download-Update.ps1`:

```powershell
$RepoOwner = "your-github-username"
$RepoName  = "your-repository-name"
$Branch    = "main"
```

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

Both scripts must be configured with the actual report repository owner and name, and `Download-Update.ps1` with the actual `$DownloadUrl`. The example values deliberately stop the scripts instead of letting them fail later.

