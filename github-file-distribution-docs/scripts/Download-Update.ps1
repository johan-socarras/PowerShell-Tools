param(
    [switch]$PauseAtEnd
)

# ==========================================
# CONFIGURATION
# ==========================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# The administrator publishes both files. The checksum file must contain the SHA-256 hash
# of the update file (for example: "ABCD... UpdatePackage.txt").
$DownloadUrl   = "https://raw.githubusercontent.com/example-owner/example-update-repository/main/UpdatePackage.txt"
$ChecksumUrl   = "$DownloadUrl.sha256"
$FileName      = "UpdatePackage.txt"

$Destination   = "$env:ProgramData\FileDistribution\$FileName"
$SiteID        = "SITE-001"

# Repository used only for location reports.
$GitHubToken   = $env:GITHUB_TOKEN
$RepoOwner     = "your-github-username"
$RepoName      = "your-repository-name"
$Branch        = "main"

$PendingQueue  = "$env:ProgramData\FileDistribution\PendingReports.json"

function Write-CompletionPause {
    if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
}

function Test-Configuration {
    if ([string]::IsNullOrWhiteSpace($SiteID)) { throw 'SiteID must be configured.' }
    if ($RepoOwner -eq 'your-github-username' -or $RepoName -eq 'your-repository-name') {
        throw 'Configure RepoOwner and RepoName before running this script.'
    }
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        throw 'GITHUB_TOKEN is not set. A token is required to write location reports.'
    }
}

function Get-GitHubHeaders {
    return @{
        Authorization = "Bearer $GitHubToken"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Get-PendingReports {
    if (-not (Test-Path -LiteralPath $PendingQueue)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $PendingQueue -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "Unable to read the pending report queue: $($_.Exception.Message)"
        return @()
    }
}

function Save-PendingReport {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [datetime]$Timestamp = (Get-Date)
    )

    try {
        $queueDirectory = Split-Path -Parent $PendingQueue
        if (-not (Test-Path -LiteralPath $queueDirectory)) {
            New-Item -ItemType Directory -Path $queueDirectory -Force -ErrorAction Stop | Out-Null
        }

        $queue = @(Get-PendingReports)
        $queue += [pscustomobject]@{
            SiteID = $SiteID
            Status = $Status
            Timestamp = $Timestamp.ToString('o')
        }

        $temporaryQueue = "$PendingQueue.new"
        $queue | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporaryQueue -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporaryQueue -Destination $PendingQueue -Force -ErrorAction Stop
    } catch {
        Write-Warning "Unable to save the pending report queue: $($_.Exception.Message)"
    }
}

function Send-Report {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [datetime]$Timestamp = (Get-Date),
        [bool]$QueueOnFailure = $true
    )

    try {
        $reportDate = $Timestamp.ToString('yyyy-MM-dd')
        $textContent = "SiteID: $SiteID`nStatus: $Status`nTimestamp: $($Timestamp.ToString('o'))`n"
        $base64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($textContent))
        $uri = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/Log/$reportDate/$SiteID.txt"
        $headers = Get-GitHubHeaders

        $sha = $null
        try {
            $existingFile = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
            $sha = $existingFile.sha
        } catch {
            # A missing report is expected. A failed PUT below is handled and queued.
        }

        $body = @{
            message = "Daily report from $SiteID for $reportDate"
            content = $base64Content
            branch = $Branch
        }
        if ($sha) { $body.sha = $sha }

        Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body ($body | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-Host "Report sent: $Status" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "Unable to send report: $($_.Exception.Message)"
        if ($QueueOnFailure) { Save-PendingReport -Status $Status -Timestamp $Timestamp }
        return $false
    }
}

function Process-PendingReports {
    foreach ($report in @(Get-PendingReports)) {
        $timestamp = [datetime]$report.Timestamp
        if (-not (Send-Report -Status $report.Status -Timestamp $timestamp -QueueOnFailure $false)) {
            return
        }
    }

    if (Test-Path -LiteralPath $PendingQueue) {
        Remove-Item -LiteralPath $PendingQueue -Force
        Write-Host 'Pending reports processed.' -ForegroundColor Cyan
    }
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    return $null
}

function Get-DownloadedSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

try {
    Test-Configuration
    Process-PendingReports
} catch {
    Write-Error $_.Exception.Message
    Write-CompletionPause
    exit 1
}

$runId = [guid]::NewGuid().ToString('N')
$tempDirectory = [System.IO.Path]::GetTempPath()
$tempFile = Join-Path $tempDirectory "$FileName.$runId.download"
$checksumFile = Join-Path $tempDirectory "$FileName.$runId.sha256"
$destinationDirectory = Split-Path -Parent $Destination
$stagedFile = Join-Path $destinationDirectory ".$FileName.$runId.new"
$backupFile = Join-Path $destinationDirectory ".$FileName.$runId.backup"

try {
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force -ErrorAction Stop | Out-Null
    }

    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } catch {
        $statusCode = Get-HttpStatusCode $_
        $status = if ($statusCode -eq 404) { 'Remote File Missing' } else { 'Download Failed' }
        Write-Warning $status
        $null = Send-Report -Status $status
        Write-CompletionPause
        exit 1
    }

    try {
        Invoke-WebRequest -Uri $ChecksumUrl -OutFile $checksumFile -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $checksumText = Get-Content -LiteralPath $checksumFile -Raw -ErrorAction Stop
        $expectedHash = ([regex]::Match($checksumText, '(?i)\b[a-f0-9]{64}\b')).Value.ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($expectedHash)) { throw 'The checksum file does not contain a SHA-256 hash.' }

        $downloadedHash = Get-DownloadedSha256 -Path $tempFile
        if ($downloadedHash -ne $expectedHash) { throw 'Downloaded file hash does not match the published checksum.' }
    } catch {
        Write-Warning "Checksum validation failed: $($_.Exception.Message)"
        $null = Send-Report -Status 'Checksum Validation Failed'
        Write-CompletionPause
        exit 1
    }

    if (Test-Path -LiteralPath $Destination) {
        if ((Get-DownloadedSha256 -Path $Destination) -eq $downloadedHash) {
            Write-Host 'File already up to date.' -ForegroundColor Yellow
            $null = Send-Report -Status 'File Already Updated'
            Write-CompletionPause
            exit 0
        }
    }

    # Stage beside the destination so the final replace is atomic on the local volume.
    Copy-Item -LiteralPath $tempFile -Destination $stagedFile -Force -ErrorAction Stop
    if ((Get-DownloadedSha256 -Path $stagedFile) -ne $downloadedHash) {
        throw 'The staged file hash does not match the downloaded file.'
    }

    if (Test-Path -LiteralPath $Destination) {
        [System.IO.File]::Replace($stagedFile, $Destination, $backupFile, $true)
        Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
    } else {
        [System.IO.File]::Move($stagedFile, $Destination)
    }

    Write-Host 'File updated successfully.' -ForegroundColor Cyan
    $null = Send-Report -Status 'File Updated Successfully'
    Write-CompletionPause
    exit 0
} catch {
    Write-Warning "Unable to update local file: $($_.Exception.Message)"
    $null = Send-Report -Status 'Local File Update Failed'
    Write-CompletionPause
    exit 1
} finally {
    foreach ($path in @($tempFile, $checksumFile, $stagedFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}
