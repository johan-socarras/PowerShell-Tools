# Configuration

Every setting is in the CONFIGURATION section at the top of each script. The scripts stop while the example values are still there, instead of failing later.

## Download-Update.ps1

| Setting | What it is |
| --- | --- |
| `$DownloadUrl` | Raw URL of the update file in the public update repository, for example `https://raw.githubusercontent.com/example-owner/example-update-repository/main/UpdatePackage.txt`. |
| `$ChecksumUrl` | URL of its checksum file. By default the same URL with `.sha256` added. |
| `$FileName` | Name of the local copy. |
| `$Destination` | Where the local copy is kept. Default: `$env:ProgramData\FileDistribution\<FileName>`. |
| `$SiteID` | This location's ID, unique per location (`SITE-001`). It names the daily report file. |
| `$RepoOwner`, `$RepoName`, `$Branch` | The report repository and its branch. |
| `$PendingQueue` | Where reports that could not be sent wait for the next run. Default: `$env:ProgramData\FileDistribution\PendingReports.json`. |

The token is read from the `GITHUB_TOKEN` environment variable. To set it for every new session of the account that runs the script:

```powershell
setx GITHUB_TOKEN "<token>"
```

Close and reopen PowerShell, or restart the scheduled task, so it sees the new value.

## Get-DailyReport.ps1

| Setting | What it is |
| --- | --- |
| `$MasterLocations` | The `SiteID` of every location expected to report. |
| `$RepoOwner`, `$RepoName` | The report repository, the same as in `Download-Update.ps1`. |

`GITHUB_TOKEN` is needed here only when the report repository is private.

## Publishing an update

Publish the file and, next to it, a checksum file with the same name plus `.sha256` that contains its 64-character SHA-256 value. Generate the checksum every time the file changes:

```powershell
(Get-FileHash .\UpdatePackage.txt -Algorithm SHA256).Hash | Set-Content .\UpdatePackage.txt.sha256 -Encoding ascii
```

Keep the file in place until every location reports a successful status in `Get-DailyReport.ps1`.
