# GitHub File Distribution and Location Reporting System

## Overview

This project provides a PowerShell-based system for distributing a centralized update file from GitHub to multiple remote locations.

Each location downloads the latest file, compares it against the existing local copy, updates it only when needed, and sends a daily status report back to GitHub.

This can be used to distribute files such as:

- price lists
- product catalogs
- configuration files
- CSV, TXT, JSON, or other operational files

The update file is downloaded without a token, so it must live in a public repository. Do not distribute confidential data this way.

The project also includes a reporting script that helps an administrator confirm which locations completed the update and which ones did not report.

## Main Use Case

The system is designed for environments where one central file needs to be distributed to many locations.

Example workflow:

1. An administrator publishes the file and its `.sha256` checksum in the update repository.
2. Each remote location runs the download script.
3. The script downloads the file and its published SHA256 checksum from GitHub.
4. The script verifies the downloaded file against that checksum before touching the local copy.
5. If the verified file is different, the local file is replaced atomically.
6. The location writes a status report to a separate report repository.
7. The administrator runs the report script to verify which locations reported successfully.

## Scripts

### `scripts/Download-Update.ps1`

This script should run at each remote location.

It performs the following actions:

- downloads the update file from GitHub
- verifies the downloaded file against a required `.sha256` checksum file
- stores the file temporarily
- compares the downloaded file with the local version
- replaces the local file only when a newer or different file is detected
- sends a status report to GitHub
- saves pending reports locally if the report cannot be sent
- is safe to run from Windows Task Scheduler (no interactive pause by default)

Possible reported statuses:

```text
File Updated Successfully
File Already Updated
Download Failed
Remote File Missing
Checksum Validation Failed
Local File Update Failed
```

### `scripts/Generate-DailyReport.ps1`

This script is used by the administrator to check reporting status.

It performs the following actions:

- reads the master list of expected locations
- checks the daily log folder in GitHub
- validates each report's `SiteID` and `Status`
- distinguishes successful locations, reported failures, and locations that did not report
- confirms success only when every expected location has a successful status

## GitHub Log Structure

Each location creates one report file per day.

Recommended log structure:

```text
Log/
└── 2026-06-30/
    ├── SITE-001.txt
    ├── SITE-002.txt
    └── SITE-003.txt
```

Example report file:

```text
SiteID: SITE-001
Status: File Updated Successfully
Timestamp: 2026-06-30T17:30:00.0000000-05:00
```

## Requirements

- Windows
- PowerShell 5.1 or newer
- Internet access from each remote location
- Two GitHub repositories: a public one for the update file and a separate one for the reports
- A GitHub token that can only write to the report repository (for example, a fine-grained token with Contents: Read and write on that repository alone)

## Configuration

Each location should have its own unique `SiteID`.

Example:

```powershell
$SiteID = "SITE-001"
```

Where each location downloads the update from (the public update repository):

```powershell
$DownloadUrl = "https://raw.githubusercontent.com/example-owner/example-update-repository/main/UpdatePackage.txt"
$ChecksumUrl = "$DownloadUrl.sha256"
$FileName    = "UpdatePackage.txt"
```

Where each location writes its daily report (the report repository):

```powershell
$RepoOwner = "your-github-username"
$RepoName  = "your-repository-name"
$Branch    = "main"
```

The script stops if any of these still has its example value. Every setting is explained in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

The GitHub token should be configured as an environment variable:

```powershell
$GitHubToken = $env:GITHUB_TOKEN
```

Do not hardcode GitHub tokens directly inside the scripts.

## Example Usage

Run this script at each remote location:

```powershell
.\scripts\Download-Update.ps1
```

By default the script does not pause at the end, so it can run unattended from Windows Task Scheduler. To pause for review when running it manually:

```powershell
.\scripts\Download-Update.ps1 -PauseAtEnd
```

Run this script from the administrator machine to check daily reporting:

```powershell
.\scripts\Generate-DailyReport.ps1
```

To check a previous day instead of today:

```powershell
.\scripts\Generate-DailyReport.ps1 -ReportDate "2026-06-30"
```

## Recommended Improvements

Future improvements could include:

- move the master location list to a CSV or JSON file
- convert fixed script values into parameters
- generate CSV or HTML reports
- send alerts through email or Microsoft Teams
- automate execution with Windows Task Scheduler
- support multiple update files
- validate downloaded files with a digital signature in addition to the required checksum
- add local log files for troubleshooting

## Security Notice

Never commit GitHub tokens, passwords, internal server paths, or confidential business data to the repository.

Protect the branch that hosts the update file and restrict who can change it. A checksum protects against a corrupted or incomplete download; it does not protect against an attacker who can change both the update file and its checksum. That is why the locations never get write access to the update repository.

If a token was ever committed to GitHub, revoke it immediately and generate a new one.

See [SECURITY.md](SECURITY.md) for more details.

