<#
.SYNOPSIS
Checks the health of a list of Windows computers and writes an HTML report.

.DESCRIPTION
For each computer it reads free space on every fixed disk, days since the last restart, whether a restart
is pending and which automatic services are not running, and gives the computer a status: OK, Warning,
Critical or Unreachable. The report lists the computers with problems first.

It connects with CIM, over WinRM when the computer answers on port 5985 and over DCOM (RPC, port 135)
otherwise, so nothing has to be installed on the computers checked. Pending restarts are read from the
registry through the StdRegProv class, which works over both.

A service that stopped with an error always counts. A service that stopped cleanly is ignored when
Windows starts it on demand (trigger start), when it is a delayed start service or when it matches
-ExcludeService (by default, software updaters, which stop on their own).

The script only reads: it restarts or starts nothing. It exits with code 1 when any computer is
Critical or Unreachable, so a scheduled run can raise an alert.

.PARAMETER ComputerName
Computers to check. Default: this computer.

.PARAMETER ComputerListPath
Text file with one computer name per line. Empty lines and lines starting with # are skipped.

.PARAMETER Credential
Account to connect with. Default: the current user. Not used for this computer.

.PARAMETER DiskWarningPercent
Free space, in percent, below which a disk is a warning. Default: 15.

.PARAMETER DiskCriticalPercent
Free space, in percent, below which a disk is critical. Default: 5.

.PARAMETER UptimeWarningDays
Days without a restart after which the computer is a warning. Default: 30.

.PARAMETER ExcludeService
Services to ignore when they are stopped, by name, with wildcards. Default: software updaters
(*update*, gupdate*, MozillaMaintenance). Pass @() to report every stopped automatic service.

.PARAMETER ReportPath
Where to write the HTML report. Default: computer-health-<date>-<time>.html in the current folder.

.EXAMPLE
.\Get-ComputerHealth.ps1

.EXAMPLE
.\Get-ComputerHealth.ps1 -ComputerName PC01, PC02, FS01

.EXAMPLE
.\Get-ComputerHealth.ps1 -ComputerListPath .\computers.txt -Credential (Get-Credential) -UptimeWarningDays 14
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,

    [string]$ComputerListPath,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [ValidateRange(1, 99)]
    [int]$DiskWarningPercent = 15,

    [ValidateRange(0, 99)]
    [int]$DiskCriticalPercent = 5,

    [ValidateRange(1, 3650)]
    [int]$UptimeWarningDays = 30,

    [string[]]$ExcludeService = @('*update*', 'gupdate*', 'MozillaMaintenance'),

    [string]$ReportPath = (Join-Path (Get-Location) ('computer-health-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$HKLM = [uint32]2147483650
$severity = @{ Unreachable = 0; Critical = 1; Warning = 2; OK = 3 }

function Test-TcpPort {
    param([string]$Computer, [int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Computer, $Port)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while (-not $task.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        return ($task.Status -eq 'RanToCompletion' -and $client.Connected)
    } finally {
        $client.Dispose()
    }
}

function Test-LocalComputer {
    param([string]$Computer)
    $short = ($Computer -split '\.')[0]
    return ($Computer -in 'localhost', '.', '127.0.0.1', '::1') -or ($short -eq $env:COMPUTERNAME)
}

function Connect-Computer {
    # Returns a CIM session and how it connected, or throws with the reason.
    param([string]$Computer, [System.Management.Automation.PSCredential]$Credential)
    $timeout = @{ OperationTimeoutSec = 30; ErrorAction = 'Stop' }
    if (Test-LocalComputer -Computer $Computer) {
        $option = New-CimSessionOption -Protocol Dcom
        return @{ Session = (New-CimSession -SessionOption $option @timeout); Connection = 'Local' }
    }
    try {
        $null = [System.Net.Dns]::GetHostAddresses($Computer)
    } catch {
        throw 'The name was not found in DNS.'
    }
    $auth = @{}
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $auth.Credential = $Credential }
    $winrm = Test-TcpPort -Computer $Computer -Port 5985
    $rpc = Test-TcpPort -Computer $Computer -Port 135
    if (-not $winrm -and -not $rpc) { throw 'Neither WinRM (port 5985) nor RPC (port 135) answered: the computer is off, or a firewall blocks both.' }
    $failures = New-Object System.Collections.Generic.List[string]
    if ($winrm) {
        try {
            return @{ Session = (New-CimSession -ComputerName $Computer @auth @timeout); Connection = 'WinRM' }
        } catch {
            $failures.Add("WinRM: $($_.Exception.Message.Trim())")
        }
    }
    if ($rpc) {
        $option = New-CimSessionOption -Protocol Dcom
        try {
            return @{ Session = (New-CimSession -ComputerName $Computer -SessionOption $option @auth @timeout); Connection = 'DCOM' }
        } catch {
            $failures.Add("DCOM: $($_.Exception.Message.Trim())")
        }
    }
    throw ($failures -join ' ')
}

function Invoke-Registry {
    param($Session, [string]$Method, [string]$Key, [string]$Value)
    $arguments = @{ hDefKey = $HKLM; sSubKeyName = $Key }
    if ($Value) { $arguments.sValueName = $Value }
    return Invoke-CimMethod -CimSession $Session -Namespace root/cimv2 -ClassName StdRegProv -MethodName $Method -Arguments $arguments -ErrorAction Stop
}

function Get-PendingRebootReason {
    param($Session)
    $reasons = New-Object System.Collections.Generic.List[string]
    if ((Invoke-Registry -Session $Session -Method 'EnumKey' -Key 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired').ReturnValue -eq 0) {
        $reasons.Add('Windows Update')
    }
    if ((Invoke-Registry -Session $Session -Method 'EnumKey' -Key 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending').ReturnValue -eq 0) {
        $reasons.Add('Windows components')
    }
    $renames = Invoke-Registry -Session $Session -Method 'GetMultiStringValue' -Key 'SYSTEM\CurrentControlSet\Control\Session Manager' -Value 'PendingFileRenameOperations'
    if ($renames.ReturnValue -eq 0 -and @($renames.sValue | Where-Object { $_ }).Count -gt 0) {
        $reasons.Add('Files to replace')
    }
    $active = (Invoke-Registry -Session $Session -Method 'GetStringValue' -Key 'SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Value 'ComputerName').sValue
    $pending = (Invoke-Registry -Session $Session -Method 'GetStringValue' -Key 'SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Value 'ComputerName').sValue
    if ($active -and $pending -and $active -ne $pending) { $reasons.Add("Rename to $pending") }
    return , $reasons
}

function Get-StoppedService {
    param($Session, [string[]]$Exclude)
    $services = @(Get-CimInstance -CimSession $Session -ClassName Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction Stop)
    foreach ($service in $services) {
        $excluded = @($Exclude | Where-Object { $service.Name -like $_ }).Count -gt 0
        if ($excluded) { continue }
        $label = if ("$($service.DisplayName)".Contains($service.Name)) { $service.DisplayName } else { "$($service.DisplayName) ($($service.Name))" }
        if ($service.ExitCode -eq 0) {
            # Stopped cleanly: fine for services that Windows starts on demand or later on.
            if ($service.DelayedAutoStart) { continue }
            $trigger = Invoke-Registry -Session $Session -Method 'EnumKey' -Key "SYSTEM\CurrentControlSet\Services\$($service.Name)\TriggerInfo"
            if ($trigger.ReturnValue -eq 0) { continue }
            $label
        } else {
            "$label, exit code $($service.ExitCode)"
        }
    }
}

function Get-HealthResult {
    param([string]$Computer, [System.Management.Automation.PSCredential]$Credential, [string[]]$Exclude)
    $result = [ordered]@{
        ComputerName    = $Computer
        Status          = 'Unreachable'
        Problems        = ''
        OperatingSystem = ''
        LastBoot        = ''
        UptimeDays      = $null
        PendingReboot   = ''
        Disks           = ''
        StoppedServices = ''
        Connection      = ''
    }
    $session = $null
    try {
        $connection = Connect-Computer -Computer $Computer -Credential $Credential
        $session = $connection.Session
        $result.Connection = $connection.Connection

        $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop
        $result.ComputerName = $os.CSName
        $result.OperatingSystem = "$($os.Caption) ($($os.Version))"
        $result.LastBoot = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        $result.UptimeDays = [int][Math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)

        $problems = New-Object System.Collections.Generic.List[string]
        $level = 'OK'

        $disks = @(Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.Size -gt 0 })
        $diskText = foreach ($disk in $disks) {
            $percent = [int][Math]::Round($disk.FreeSpace * 100 / $disk.Size)
            if ($percent -lt $DiskCriticalPercent) {
                $problems.Add("$($disk.DeviceID) $percent% free")
                $level = 'Critical'
            } elseif ($percent -lt $DiskWarningPercent) {
                $problems.Add("$($disk.DeviceID) $percent% free")
                if ($level -eq 'OK') { $level = 'Warning' }
            }
            '{0} {1:N1} GB free of {2:N1} GB ({3}%)' -f $disk.DeviceID, ($disk.FreeSpace / 1GB), ($disk.Size / 1GB), $percent
        }
        $result.Disks = @($diskText) -join '; '

        if ($result.UptimeDays -ge $UptimeWarningDays) {
            $problems.Add("Up $($result.UptimeDays) days")
            if ($level -eq 'OK') { $level = 'Warning' }
        }

        $reasons = Get-PendingRebootReason -Session $session
        if ($reasons.Count -gt 0) {
            $result.PendingReboot = $reasons -join ', '
            $problems.Add('Restart pending')
            if ($level -eq 'OK') { $level = 'Warning' }
        }

        $stopped = @(Get-StoppedService -Session $session -Exclude $Exclude)
        if ($stopped.Count -gt 0) {
            $result.StoppedServices = $stopped -join '; '
            $problems.Add("$($stopped.Count) service(s) not running")
            if ($level -eq 'OK') { $level = 'Warning' }
        }

        $result.Status = $level
        $result.Problems = $problems -join '; '
    } catch {
        $result.Status = 'Unreachable'
        $result.Problems = $_.Exception.Message.Trim()
        if ($result.Connection -and $result.Problems -notlike "$($result.Connection):*") { $result.Problems = "$($result.Connection): $($result.Problems)" }
    } finally {
        if ($session) { Remove-CimSession -CimSession $session }
    }
    return [pscustomobject]$result
}

function ConvertTo-HtmlReport {
    param([object[]]$Result, [string]$Subtitle)
    $encode = { param($Text) [System.Net.WebUtility]::HtmlEncode("$Text") }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="en"><head><meta charset="utf-8"><title>Computer health</title>')
    $null = $sb.AppendLine(@'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; }
h1 { font-size: 22px; margin-bottom: 4px; }
.meta { color: #59636e; margin-top: 0; }
.cards { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; }
.card { border: 1px solid #d1d9e0; border-radius: 6px; padding: 10px 16px; min-width: 120px; }
.card b { display: block; font-size: 24px; }
table { border-collapse: collapse; font-size: 14px; }
th, td { border: 1px solid #d1d9e0; padding: 5px 10px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
td:first-child, td:nth-child(2) { white-space: nowrap; }
.badge { display: inline-block; border-radius: 10px; padding: 1px 9px; font-weight: 600; color: #fff; }
.OK { background: #1a7f37; }
.Warning { background: #9a6700; }
.Critical { background: #cf222e; }
.Unreachable { background: #59636e; }
.list { margin: 0; padding-left: 16px; }
</style></head><body>
'@)
    $null = $sb.AppendLine('<h1>Computer health</h1>')
    $null = $sb.AppendLine("<p class=""meta"">$(& $encode $Subtitle)</p>")
    $null = $sb.AppendLine('<div class="cards">')
    foreach ($status in 'OK', 'Warning', 'Critical', 'Unreachable') {
        $count = @($Result | Where-Object Status -eq $status).Count
        $null = $sb.AppendLine("<div class=""card""><b>$count</b><span class=""badge $status"">$status</span></div>")
    }
    $null = $sb.AppendLine('</div>')
    $null = $sb.AppendLine('<table><tr><th>Computer</th><th>Status</th><th>Problems</th><th>Uptime (days)</th><th>Pending restart</th><th>Disks</th><th>Services not running</th><th>Operating system</th></tr>')
    foreach ($r in $Result) {
        $toList = {
            param($Text)
            $items = @("$Text" -split '; ' | Where-Object { $_ })
            if ($items.Count -le 1) { return (& $encode $Text) }
            return '<ul class="list">' + (-join ($items | ForEach-Object { "<li>$(& $encode $_)</li>" })) + '</ul>'
        }
        $cells = @(
            (& $encode $r.ComputerName),
            "<span class=""badge $($r.Status)"">$($r.Status)</span>",
            (& $toList $r.Problems),
            (& $encode $r.UptimeDays),
            (& $encode $r.PendingReboot),
            (& $toList $r.Disks),
            (& $toList $r.StoppedServices),
            (& $encode $r.OperatingSystem)
        )
        $null = $sb.AppendLine("<tr>$(-join ($cells | ForEach-Object { "<td>$_</td>" }))</tr>")
    }
    $null = $sb.AppendLine('</table></body></html>')
    return $sb.ToString()
}

# The list of computers.
$computers = New-Object System.Collections.Generic.List[string]
if ($ComputerListPath) {
    if (-not (Test-Path -LiteralPath $ComputerListPath -PathType Leaf)) {
        Write-Error "The computer list does not exist: $ComputerListPath"
        exit 1
    }
    foreach ($line in Get-Content -LiteralPath $ComputerListPath) {
        $name = $line.Trim()
        if ($name -and -not $name.StartsWith('#')) { $computers.Add($name) }
    }
}
foreach ($name in $ComputerName) { if ("$name".Trim()) { $computers.Add("$name".Trim()) } }
if ($computers.Count -eq 0) {
    if ($ComputerListPath) {
        Write-Error "The computer list has no names: $ComputerListPath"
        exit 1
    }
    $computers.Add($env:COMPUTERNAME)
}
$computers = @($computers | Sort-Object -Unique)
if ($DiskCriticalPercent -ge $DiskWarningPercent) {
    Write-Error "-DiskCriticalPercent ($DiskCriticalPercent) must be lower than -DiskWarningPercent ($DiskWarningPercent)."
    exit 1
}
# .NET file methods resolve relative paths from the process folder, not from the PowerShell location.
$ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
$reportFolder = Split-Path -Parent $ReportPath
# Not Test-Path: in Windows PowerShell 5.1 it stops with an error on a share that cannot be reached.
if (-not [System.IO.Directory]::Exists($reportFolder)) {
    Write-Error "The report folder does not exist: $reportFolder"
    exit 1
}

$results = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $computers.Count; $i++) {
    Write-Progress -Activity 'Checking computers' -Status $computers[$i] -PercentComplete ($i * 100 / $computers.Count)
    $results.Add((Get-HealthResult -Computer $computers[$i] -Credential $Credential -Exclude $ExcludeService))
}
Write-Progress -Activity 'Checking computers' -Completed

$sorted = @($results | Sort-Object @{ Expression = { $severity[$_.Status] } }, ComputerName)
$subtitle = "Checked from $env:COMPUTERNAME on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Warning below $DiskWarningPercent% free disk space, critical below $DiskCriticalPercent%; warning after $UptimeWarningDays days without a restart."
$html = ConvertTo-HtmlReport -Result $sorted -Subtitle $subtitle
[System.IO.File]::WriteAllText($ReportPath, $html, (New-Object System.Text.UTF8Encoding $false))

$summary = ($sorted | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
Write-Host "$($sorted.Count) computer(s). $summary"
Write-Host "Report: $ReportPath"
$sorted
if ($sorted | Where-Object { $_.Status -in 'Critical', 'Unreachable' }) { exit 1 }
