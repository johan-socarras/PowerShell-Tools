param(
    [string]$ReportDate = (Get-Date -Format 'yyyy-MM-dd')
)

# ==========================================
# CONFIGURATION
# ==========================================

$MasterLocations = @(
    'SITE-001',
    'SITE-002',
    'SITE-003',
    'SITE-004',
    'SITE-005'
)

$RepoOwner = 'your-github-username'
$RepoName  = 'your-repository-name'
$GitHubToken = $env:GITHUB_TOKEN # Required only when the report repository is private.

function Get-GitHubHeader {
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) { return @{} }
    return @{
        Authorization = "Bearer $GitHubToken"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Get-ReportValue {
    param([string]$Content, [string]$Name)
    $match = [regex]::Match($Content, "(?m)^$([regex]::Escape($Name)):\s*(.+?)\s*$")
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

if ($RepoOwner -eq 'your-github-username' -or $RepoName -eq 'your-repository-name') {
    Write-Error 'Configure RepoOwner and RepoName before running this script.'
    exit 1
}

$headers = Get-GitHubHeader
$folderUri = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/Log/$ReportDate"

try {
    # Invoke-RestMethod returns a JSON array as one object; ForEach-Object unrolls it so each file is read on its own.
    $filesInGitHub = @(Invoke-RestMethod -Uri $folderUri -Headers $headers -Method Get -ErrorAction Stop | ForEach-Object { $_ })
} catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
        $filesInGitHub = @()
    } else {
        Write-Error "Could not read the report folder: $($_.Exception.Message)"
        exit 1
    }
}

$reportsByLocation = @{}
foreach ($file in @($filesInGitHub | Where-Object { $_.type -eq 'file' -and $_.name -like '*.txt' })) {
    try {
        $reportFile = Invoke-RestMethod -Uri $file.url -Headers $headers -Method Get -ErrorAction Stop
        $content = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($reportFile.content -replace '\s', '')))
        $siteId = Get-ReportValue -Content $content -Name 'SiteID'
        $status = Get-ReportValue -Content $content -Name 'Status'
        $timestamp = Get-ReportValue -Content $content -Name 'Timestamp'
        $fileSiteId = [System.IO.Path]::GetFileNameWithoutExtension($file.name)

        if ([string]::IsNullOrWhiteSpace($siteId) -or $siteId -ne $fileSiteId -or [string]::IsNullOrWhiteSpace($status)) {
            $reportsByLocation[$fileSiteId] = [pscustomobject]@{ Status = 'Invalid report'; Timestamp = $timestamp }
        } else {
            $reportsByLocation[$siteId] = [pscustomobject]@{ Status = $status; Timestamp = $timestamp }
        }
    } catch {
        $fileSiteId = [System.IO.Path]::GetFileNameWithoutExtension($file.name)
        $reportsByLocation[$fileSiteId] = [pscustomobject]@{ Status = 'Unreadable report'; Timestamp = $null }
    }
}

$successfulStatuses = @('File Updated Successfully', 'File Already Updated')
$confirmed = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[object]

foreach ($location in $MasterLocations) {
    if (-not $reportsByLocation.ContainsKey($location)) {
        $missing.Add($location)
        continue
    }

    $report = $reportsByLocation[$location]
    if ($successfulStatuses -contains $report.Status) {
        $confirmed.Add($location)
    } else {
        $failed.Add([pscustomobject]@{ SiteID = $location; Status = $report.Status; Timestamp = $report.Timestamp })
    }
}

Write-Host "Daily report: $ReportDate" -ForegroundColor Cyan
Write-Host "Successful locations: $($confirmed.Count)/$($MasterLocations.Count)" -ForegroundColor Cyan

if ($missing.Count -gt 0) {
    Write-Host "`nNO REPORT RECEIVED:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
}

if ($failed.Count -gt 0) {
    Write-Host "`nREPORTED FAILURE:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host " - $($_.SiteID): $($_.Status) [$($_.Timestamp)]" -ForegroundColor Yellow }
}

if ($missing.Count -eq 0 -and $failed.Count -eq 0) {
    Write-Host "`nTOTAL SUCCESS! All locations downloaded or already had the verified file." -ForegroundColor Green
    exit 0
}

Write-Host "`nDo not remove the update file until all locations report a successful status." -ForegroundColor Magenta
exit 1
