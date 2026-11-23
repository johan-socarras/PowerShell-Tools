<#
.SYNOPSIS
Finds out why a Windows PC is slow or unstable and runs the usual cleanup and repair steps, with an HTML
report for the ticket.

.DESCRIPTION
Run without parameters, it opens a window where a technician ticks what to do. With -Check or -Task it runs
without a window, for a remote session or a management tool that runs scripts on the PC.

-Check only reads: disk health and free space, memory, processor load, startup programs, blue screens and
crashes, Windows Update, security software, battery, power plan and network. Each finding gets a status
(Critical, Warning, OK, Info or Skipped) and what to do about it. Some checks need administrator rights and
say Skipped without them.

-Task runs cleanup and repair steps, always in this order:
  TempFiles         Deletes temporary files older than -TempFileAgeDays. As administrator, for every user
                    profile and Windows\Temp; otherwise, for the current user.
  RecycleBin        Empties the Recycle Bin on every fixed drive. As administrator, every user's.
  UpdateCache       Clears downloaded Windows Update files and the Delivery Optimization cache.
  DnsCache          Clears the DNS client cache.
  ComponentCleanup  Removes superseded Windows components (DISM /StartComponentCleanup).
  OptimizeDrive     Optimizes the system drive: TRIM on an SSD, defragmentation on a hard disk.
  RepairWindows     Repairs the Windows image with DISM /RestoreHealth, then system files with SFC.
  MemoryTest        Opens Windows Memory Diagnostic, which tests the memory at the next restart.

Deletions skip files in use and never follow junctions or symbolic links out of the folder being cleaned.
With -DryRun every task says what it would do and nothing is changed.

Every run writes an HTML report and a log. The script exits with code 1 when a check is Critical or a task
failed, with 2 when the parameters are wrong, and with 0 otherwise.

.PARAMETER Check
Checks the PC. Changes nothing.

.PARAMETER Task
Tasks to run, by name, as a list or separated by commas: TempFiles, RecycleBin, UpdateCache, DnsCache,
ComponentCleanup, OptimizeDrive, RepairWindows, MemoryTest.

.PARAMETER DryRun
Shows what each task would do, and changes nothing.

.PARAMETER TempFileAgeDays
TempFiles only deletes files that have not changed for this many days. Default: 7.

.PARAMETER UptimeWarningDays
Days without a restart after which the check gives a warning. Default: 30.

.PARAMETER EventDays
How many days back the check reads the event logs. Default: 30.

.PARAMETER ReportPath
Where to write the HTML report. Default: pc-maintenance-<computer>-<date>-<time>.html in the current folder.

.PARAMETER LogPath
Where to write the log. Default: next to the report, with the extension .log.

.PARAMETER JsonPath
Also writes the results as JSON to this file.

.PARAMETER PassThru
Returns the results as an object: System, Findings, Tasks and the paths of the report and the log.

.EXAMPLE
.\Invoke-PCMaintenance.ps1

Opens the window.

.EXAMPLE
.\Invoke-PCMaintenance.ps1 -Check

Checks this PC and writes the report in the current folder.

.EXAMPLE
.\Invoke-PCMaintenance.ps1 -Check -Task TempFiles, RecycleBin, UpdateCache -DryRun

Checks the PC and shows how much the three cleanups would free, without deleting anything.
#>
# The check and task functions read these three parameters from the script scope.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TempFileAgeDays', Justification = 'Read by Invoke-TempFilesTask.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UptimeWarningDays', Justification = 'Read by Invoke-RestartCheck.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EventDays', Justification = 'Read by the event log checks.')]
[CmdletBinding()]
param(
    [switch]$Check,

    [string[]]$Task,

    [switch]$DryRun,

    [ValidateRange(1, 365)]
    [int]$TempFileAgeDays = 7,

    [ValidateRange(1, 3650)]
    [int]$UptimeWarningDays = 30,

    [ValidateRange(1, 365)]
    [int]$EventDays = 30,

    [string]$ReportPath,

    [string]$LogPath,

    [string]$JsonPath,

    [switch]$PassThru
)

$script:ScriptPath = $PSCommandPath
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:TaskResults = New-Object System.Collections.Generic.List[object]
$script:LogFile = $null
$script:StatusRank = @{ Critical = 0; Warning = 1; OK = 2; Info = 3; Skipped = 4 }
$script:PowerSaverPlan = 'a1841308-3541-4fab-bc81-f71556f20b4a'

$script:TaskCatalog = @(
    [pscustomobject]@{ Name = 'TempFiles'; NeedsAdmin = $false; Changes = $true; Title = 'Delete old temporary files'; Detail = 'Unchanged for 7 days or more; files in use stay. As administrator: every user, and Windows\Temp.' }
    [pscustomobject]@{ Name = 'RecycleBin'; NeedsAdmin = $false; Changes = $true; Title = 'Empty the Recycle Bin'; Detail = 'Cannot be undone. As administrator: every user on this PC.' }
    [pscustomobject]@{ Name = 'UpdateCache'; NeedsAdmin = $true; Changes = $true; Title = 'Clear Windows Update downloads'; Detail = 'Update files already downloaded, and the Delivery Optimization cache.' }
    [pscustomobject]@{ Name = 'DnsCache'; NeedsAdmin = $false; Changes = $false; Title = 'Clear the DNS cache'; Detail = 'Fixes names that still resolve to an old address.' }
    [pscustomobject]@{ Name = 'ComponentCleanup'; NeedsAdmin = $true; Changes = $true; Title = 'Remove old Windows components'; Detail = 'DISM /StartComponentCleanup. Frees space in the component store; a few minutes.' }
    [pscustomobject]@{ Name = 'OptimizeDrive'; NeedsAdmin = $true; Changes = $true; Title = 'Optimize the system drive'; Detail = 'TRIM on an SSD, defragmentation on a hard disk. Windows also does this every week.' }
    [pscustomobject]@{ Name = 'RepairWindows'; NeedsAdmin = $true; Changes = $true; Title = 'Repair Windows files'; Detail = 'DISM /RestoreHealth, then SFC /scannow. 30 minutes to 2 hours.' }
    [pscustomobject]@{ Name = 'MemoryTest'; NeedsAdmin = $false; Changes = $false; Title = 'Test the memory at the next restart'; Detail = 'Opens Windows Memory Diagnostic; the PC restarts to run the test (about 15 minutes).' }
)

# --- Helpers -------------------------------------------------------------------------------------------

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-MaintenanceLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8)
        } catch {
            Write-Host "Could not write the log: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} bytes' -f $Bytes
}

function Add-Finding {
    param(
        [string]$Area,
        [ValidateSet('Critical', 'Warning', 'OK', 'Info', 'Skipped')]
        [string]$Status,
        [string]$Finding,
        [string]$Advice = '',
        [string[]]$Suggest = @()
    )
    $script:Findings.Add([pscustomobject]@{
        Area    = $Area
        Status  = $Status
        Finding = $Finding
        Advice  = $Advice
        Suggest = @($Suggest)
    })
    $level = @{ Critical = 'ERROR'; Warning = 'WARN'; OK = 'OK'; Info = 'INFO'; Skipped = 'INFO' }[$Status]
    Write-MaintenanceLog -Message "$Area - $($Status): $Finding" -Level $level
}

function Invoke-CheckStep {
    # Runs one check; if it throws, the area is reported as Skipped with the reason.
    param([string]$Area, [scriptblock]$Body)
    try {
        & $Body
    } catch {
        Add-Finding -Area $Area -Status Skipped -Finding "Could not be checked: $($_.Exception.Message.Trim())"
    }
}

function Get-RecentEvent {
    # Events from one log since a date. No matching events is an empty result, not an error.
    param([string]$LogName, [string]$ProviderName, [int[]]$Id, [Nullable[datetime]]$Since)
    $filter = @{ LogName = $LogName }
    if ($ProviderName) { $filter.ProviderName = $ProviderName }
    if ($Id) { $filter.Id = $Id }
    if ($null -ne $Since) { $filter.StartTime = $Since }
    try {
        return @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.FullyQualifiedErrorId -like 'NoMatchingProvidersFound*') { return @() }
        throw
    }
}

function Get-SystemToolPath {
    # A 32-bit PowerShell on 64-bit Windows sees the 32-bit System32; DISM and SFC must be the 64-bit ones.
    param([string]$FileName)
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return Join-Path $env:windir "Sysnative\$FileName"
    }
    return Join-Path $env:windir "System32\$FileName"
}

function Invoke-NativeTool {
    # Runs a command-line tool and logs its output. Progress lines are not kept: the log gets one
    # line every 10%, so a long DISM or SFC run shows it is still moving.
    param([string]$FilePath, [string[]]$ArgumentList)
    Write-MaintenanceLog -Message "Running $(Split-Path -Leaf $FilePath) $($ArgumentList -join ' ')"
    $lines = New-Object System.Collections.Generic.List[string]
    $logged = 0
    & $FilePath @ArgumentList 2>&1 | ForEach-Object {
        # SFC writes UTF-16, which arrives with a NUL between letters.
        $text = ("$_" -replace "`0", '').Trim()
        if (-not $text) { return }
        $progress = [regex]::Match($text, '(\d+)(?:[.,]\d+)?\s?%')
        if ($progress.Success) {
            $step = [math]::Floor([int]$progress.Groups[1].Value / 10) * 10
            # A tool with several phases starts again from 0.
            if ($step -lt $logged) { $logged = 0 }
            if ($step -gt $logged) {
                $logged = $step
                Write-MaintenanceLog -Message "  $step%"
            }
            return
        }
        $lines.Add($text)
        Write-MaintenanceLog -Message "  $text"
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines.ToArray() }
}

function Get-PendingRestartReason {
    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Windows components')
    }
    $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($session -and @($session.PendingFileRenameOperations | Where-Object { $_ }).Count -gt 0) {
        $reasons.Add('Files to replace')
    }
    $active = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $pending -and $active -ne $pending) { $reasons.Add("Rename to $pending") }
    return $reasons.ToArray()
}

function Get-SystemDriveFreeSpace {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    if ($disk) { return [long]$disk.FreeSpace }
    return $null
}

function Get-AccountName {
    param([string]$Sid)
    try {
        return (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value
    } catch {
        return $Sid
    }
}

function Get-ModelName {
    # HP and others repeat the manufacturer in the model name.
    param($ComputerSystem)
    $maker = "$($ComputerSystem.Manufacturer)".Trim()
    $model = "$($ComputerSystem.Model)".Trim()
    if ($maker -and $model -like "$maker*") { return $model }
    return "$maker $model".Trim()
}

function Get-SystemSummary {
    $script:Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $script:ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $script:Processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
    $nt = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $release = if ($nt.DisplayVersion) { $nt.DisplayVersion } else { $nt.ReleaseId }
    $build = if ($null -ne $nt.UBR) { "$($script:Os.BuildNumber).$($nt.UBR)" } else { $script:Os.BuildNumber }
    $installed = (Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
    if (-not $installed) { $installed = [double]$script:Os.TotalVisibleMemorySize * 1KB }
    $script:InstalledMemory = [double]$installed
    $cores = ($script:Processors | Measure-Object -Property NumberOfCores -Sum).Sum
    $threads = ($script:Processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $cpuName = if ($script:Processors.Count -gt 0) { "$($script:Processors[0].Name)".Trim() } else { 'Unknown' }
    $cs = $script:ComputerSystem
    return [ordered]@{
        'Computer'       = $env:COMPUTERNAME
        'Model'          = (Get-ModelName -ComputerSystem $cs)
        'Serial number'  = "$($bios.SerialNumber)".Trim()
        'Windows'        = ('{0} {1} (build {2})' -f "$($script:Os.Caption)".Replace('Microsoft ', '').Trim(), $release, $build)
        'Domain'         = $(if ($cs.PartOfDomain) { $cs.Domain } else { "Workgroup $($cs.Workgroup)" })
        'Signed-in user' = $(if ($cs.UserName) { $cs.UserName } else { 'Nobody at the console' })
        'Processor'      = ('{0} ({1} cores, {2} threads)' -f $cpuName, $cores, $threads)
        'Memory'         = "$(Format-Size $installed) installed"
        'Last restart'   = $script:Os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        'Run by'         = "$env:USERDOMAIN\$env:USERNAME, $(if ($script:IsAdmin) { 'as administrator' } else { 'without administrator rights' })"
        'Date'           = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
}

# --- Checks (read only) --------------------------------------------------------------------------------

function Invoke-RestartCheck {
    $days = [int][Math]::Floor(((Get-Date) - $script:Os.LastBootUpTime).TotalDays)
    $reasons = @(Get-PendingRestartReason)
    if ($reasons.Count -gt 0) {
        Add-Finding -Area 'Restart' -Status Warning -Finding "A restart is pending: $($reasons -join ', ')." -Advice 'Restart the PC before anything else; it finishes the updates and often clears the problem.'
    }
    if ($days -ge $UptimeWarningDays) {
        Add-Finding -Area 'Restart' -Status Warning -Finding "$days days without a restart (since $($script:Os.LastBootUpTime.ToString('yyyy-MM-dd')))." -Advice 'Restart it. With Fast Startup on, Shut down does not reset this: only Restart does.'
    } elseif ($reasons.Count -eq 0) {
        Add-Finding -Area 'Restart' -Status OK -Finding "Restarted $days day(s) ago; no restart pending."
    }
}

function Invoke-DiskSpaceCheck {
    $cleanup = @('TempFiles', 'RecycleBin', 'UpdateCache', 'ComponentCleanup')
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Where-Object { $_.Size -gt 0 })
    foreach ($disk in $disks) {
        $percent = [int][Math]::Round($disk.FreeSpace * 100 / $disk.Size)
        $isSystem = $disk.DeviceID -eq $env:SystemDrive
        $text = '{0} {1} free of {2} ({3}%).' -f $disk.DeviceID, (Format-Size $disk.FreeSpace), (Format-Size $disk.Size), $percent
        $suggest = if ($isSystem) { $cleanup } else { @('RecycleBin') }
        $advice = 'Run the cleanup tasks, then move or delete large files. Windows needs about 10 GB free to install updates.'
        if ($percent -lt 5 -or ($isSystem -and $disk.FreeSpace -lt 5GB)) {
            Add-Finding -Area 'Disk space' -Status Critical -Finding $text -Advice $advice -Suggest $suggest
        } elseif ($percent -lt 15 -or ($isSystem -and $disk.FreeSpace -lt 10GB)) {
            Add-Finding -Area 'Disk space' -Status Warning -Finding $text -Advice $advice -Suggest $suggest
        } else {
            Add-Finding -Area 'Disk space' -Status OK -Finding $text
        }
    }
}

function Invoke-DiskHealthCheck {
    $systemDisk = $null
    try {
        $systemDisk = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop | Select-Object -First 1).DiskNumber
    } catch {
        $systemDisk = $null
    }
    $disks = @(Get-PhysicalDisk -ErrorAction Stop)
    if ($disks.Count -eq 0) {
        Add-Finding -Area 'Disk health' -Status Skipped -Finding 'Windows lists no physical disks (a virtual machine shows none sometimes).'
        return
    }
    foreach ($disk in $disks) {
        $media = "$($disk.MediaType)"
        if ($media -in '', 'Unspecified', '0') { $media = 'disk' }
        $isSystem = ($null -ne $systemDisk) -and ("$($disk.DeviceId)" -eq "$systemDisk")
        $label = '{0} ({1}, {2}{3})' -f "$($disk.FriendlyName)".Trim(), $media, $disk.BusType, $(if ($isSystem) { ', system disk' } else { '' })
        $status = 'OK'
        $advice = ''
        $parts = New-Object System.Collections.Generic.List[string]
        $health = "$($disk.HealthStatus)"
        if ($health -and $health -ne 'Healthy') {
            $status = 'Critical'
            $parts.Add("Windows reports it as $health ($(@($disk.OperationalStatus) -join ', '))")
            $advice = 'Back up the data now and replace the disk.'
        } else {
            $parts.Add('Windows reports it healthy')
        }
        if ($script:IsAdmin) {
            $counters = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($counters) {
                if ($media -ne 'HDD' -and $null -ne $counters.Wear) {
                    $parts.Add("$($counters.Wear)% worn")
                    if ($counters.Wear -ge 90) {
                        $status = 'Critical'
                        $advice = 'The SSD is almost worn out: back up the data and replace it.'
                    } elseif ($counters.Wear -ge 70 -and $status -eq 'OK') {
                        $status = 'Warning'
                        $advice = 'The SSD is wearing out: plan to replace it.'
                    }
                }
                if ($counters.ReadErrorsUncorrected -gt 0) {
                    $status = 'Critical'
                    $parts.Add("$($counters.ReadErrorsUncorrected) read errors it could not correct")
                    $advice = 'Back up the data now and replace the disk.'
                }
                if ($counters.Temperature -gt 0) {
                    $parts.Add("$($counters.Temperature) C")
                    $limit = if ($media -eq 'HDD') { 55 } else { 70 }
                    if ($counters.Temperature -ge $limit -and $status -eq 'OK') {
                        $status = 'Warning'
                        $advice = 'The disk runs hot: check the fans and the airflow, and clean the dust.'
                    }
                }
                if ($counters.PowerOnHours -gt 0) { $parts.Add(('{0:N0} hours powered on' -f $counters.PowerOnHours)) }
            }
        } else {
            $parts.Add('wear and error counters need administrator rights')
        }
        if ($isSystem -and $media -eq 'HDD' -and $status -eq 'OK') {
            $status = 'Warning'
            $advice = 'Windows runs from a spinning hard disk, the most common reason an older PC feels slow. Replacing it with an SSD is the biggest speed-up.'
        }
        Add-Finding -Area 'Disk health' -Status $status -Finding "$($label): $($parts -join ', ')." -Advice $advice
    }
    if ($script:IsAdmin) {
        $predicted = @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue | Where-Object { $_.PredictFailure })
        if ($predicted.Count -gt 0) {
            Add-Finding -Area 'Disk health' -Status Critical -Finding "SMART predicts that $($predicted.Count) disk(s) will fail soon." -Advice 'Back up the data now and replace the disk.'
        }
    }
}

function Invoke-DiskEventCheck {
    $since = (Get-Date).AddDays(-$EventDays)
    $storage = @{ 129 = 'controller reset'; 11 = 'controller error' }
    $known = @{
        'disk'                   = @{ 7 = 'bad block'; 51 = 'paging error'; 52 = 'failure predicted'; 153 = 'read or write retried'; 154 = 'hardware error' }
        'Ntfs'                   = @{ 55 = 'file system damaged' }
        'Microsoft-Windows-Ntfs' = @{ 55 = 'file system damaged' }
        'stornvme'               = $storage
        'storahci'               = $storage
        'iaStorA'                = $storage
        'iaStorAC'               = $storage
        'iaStorAVC'              = $storage
        'iaStorV'                = $storage
    }
    $serious = @(7, 51, 52, 55, 154)
    $events = @(Get-RecentEvent -LogName System -Id 7, 11, 51, 52, 55, 129, 153, 154 -Since $since | Where-Object {
        $known.ContainsKey($_.ProviderName) -and $known[$_.ProviderName].ContainsKey($_.Id)
    })
    if ($events.Count -eq 0) {
        Add-Finding -Area 'Disk errors' -Status OK -Finding "No disk errors in the System log in the last $EventDays days."
        return
    }
    $groups = $events | Group-Object -Property { $known[$_.ProviderName][$_.Id] } | Sort-Object -Property Count -Descending
    $text = ($groups | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    $last = ($events | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $finding = "$($events.Count) disk error(s) in the last $EventDays days: $text. Last one: $last."
    if (@($events | Where-Object { $_.Id -in $serious }).Count -gt 0) {
        Add-Finding -Area 'Disk errors' -Status Critical -Finding $finding -Advice "The disk is failing or the file system is damaged: back up the data, run chkdsk $env:SystemDrive /scan, and plan to replace the disk."
    } else {
        Add-Finding -Area 'Disk errors' -Status Warning -Finding $finding -Advice 'The disk or its controller had to retry: check the cable on a desktop, update the storage driver and firmware, and see whether it keeps growing.'
    }
}

function Invoke-MemoryCheck {
    $total = [double]$script:Os.TotalVisibleMemorySize * 1KB
    $free = [double]$script:Os.FreePhysicalMemory * 1KB
    $usedPercent = [int][Math]::Round(($total - $free) * 100 / $total)
    $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    $committed = if ($perf) { [double]$perf.CommittedBytes } else { $null }
    $text = "$(Format-Size $script:InstalledMemory) installed, $usedPercent% in use now"
    if ($null -ne $committed) { $text += "; programs have reserved $(Format-Size $committed)" }
    if ($script:InstalledMemory -lt 7.5GB) {
        Add-Finding -Area 'Memory' -Status Warning -Finding "$text." -Advice 'Windows 10 and 11 with a browser, Teams and Office need 8 GB; 16 GB for heavier work. Add memory.'
    } elseif ($null -ne $committed -and $committed -ge 1.5 * $total) {
        Add-Finding -Area 'Memory' -Status Warning -Finding "$text, $([Math]::Round($committed / $total, 1)) times the memory Windows can use." -Advice 'Windows keeps moving memory to the page file, which is slow. Close what is not needed, or add memory.'
    } elseif ($usedPercent -ge 90) {
        Add-Finding -Area 'Memory' -Status Warning -Finding "$text." -Advice 'Memory is almost full. See below what uses it.'
    } else {
        Add-Finding -Area 'Memory' -Status OK -Finding "$text."
    }
    $top = Get-Process | Group-Object -Property ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Bytes = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum }
    } | Sort-Object -Property Bytes -Descending | Select-Object -First 5
    $list = ($top | ForEach-Object {
        if ($_.Count -gt 1) { '{0} {1} ({2} processes)' -f $_.Name, (Format-Size $_.Bytes), $_.Count } else { '{0} {1}' -f $_.Name, (Format-Size $_.Bytes) }
    }) -join ', '
    Add-Finding -Area 'Memory' -Status Info -Finding "Using the most memory: $list."
}

function Invoke-ProcessorCheck {
    $cores = [Math]::Max(1, [int]($script:Processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
    $before = @{}
    foreach ($process in Get-Process) {
        $time = $process.TotalProcessorTime
        if ($null -ne $time) { $before[$process.Id] = $time.TotalMilliseconds }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $loads = @(foreach ($i in 1..5) {
        (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average).Average
        Start-Sleep -Milliseconds 800
    })
    $elapsed = [Math]::Max(1, $watch.Elapsed.TotalMilliseconds)
    $usage = foreach ($process in Get-Process) {
        $time = $process.TotalProcessorTime
        if ($null -ne $time -and $before.ContainsKey($process.Id) -and $process.ProcessName -ne 'Idle') {
            [pscustomobject]@{ Name = $process.ProcessName; Percent = ($time.TotalMilliseconds - $before[$process.Id]) * 100 / ($elapsed * $cores) }
        }
    }
    $busiest = @($usage | Group-Object -Property Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Percent = ($_.Group | Measure-Object -Property Percent -Sum).Sum }
    } | Where-Object { $_.Percent -ge 5 } | Sort-Object -Property Percent -Descending | Select-Object -First 3)
    $measured = @($loads | Where-Object { $null -ne $_ })
    $average = if ($measured.Count -gt 0) { [int][Math]::Round(($measured | Measure-Object -Average).Average) } else { [int][Math]::Round(($usage | Measure-Object -Property Percent -Sum).Sum) }
    $text = "$average% busy on average over $([int][Math]::Round($elapsed / 1000)) seconds"
    if ($busiest.Count -gt 0) { $text += '; busiest: ' + (($busiest | ForEach-Object { '{0} {1:N0}%' -f $_.Name, $_.Percent }) -join ', ') }
    if ($average -ge 80) {
        Add-Finding -Area 'Processor' -Status Warning -Finding "$text." -Advice 'Something keeps the processor busy: check the programs above in Task Manager. A full scan or an update can do this for a while.'
    } else {
        Add-Finding -Area 'Processor' -Status OK -Finding "$text."
    }
}

function Test-StartupEnabled {
    # Task Manager marks a disabled startup entry with an odd first byte in StartupApproved.
    param($ApprovedKey, [string]$Name)
    if ($null -eq $ApprovedKey) { return $true }
    $value = $ApprovedKey.GetValue($Name)
    if ($value -is [byte[]] -and $value.Length -gt 0) { return (($value[0] -band 1) -eq 0) }
    return $true
}

function Get-StartupItem {
    $items = New-Object System.Collections.Generic.List[object]
    $runPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $approvedPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $hives = New-Object System.Collections.Generic.List[object]
    $hives.Add([pscustomobject]@{ Root = 'Registry::HKEY_LOCAL_MACHINE'; Who = 'All users'; Folder = [Environment]::GetFolderPath('CommonStartup') })
    foreach ($hive in Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue) {
        if ($hive.PSChildName -notmatch '^S-1-5-21-[\d-]+$') { continue }
        $profilePath = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($hive.PSChildName)" -ErrorAction SilentlyContinue).ProfileImagePath
        $folder = if ($profilePath) { Join-Path ([Environment]::ExpandEnvironmentVariables($profilePath)) 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' } else { $null }
        $hives.Add([pscustomobject]@{ Root = "Registry::HKEY_USERS\$($hive.PSChildName)"; Who = (Get-AccountName -Sid $hive.PSChildName); Folder = $folder })
    }
    foreach ($hive in $hives) {
        $sources = @(@{ Run = "$($hive.Root)\$runPath"; Approved = "$($hive.Root)\$approvedPath\Run" })
        if ($hive.Who -eq 'All users') {
            $sources += @{ Run = "$($hive.Root)\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Approved = "$($hive.Root)\$approvedPath\Run32" }
        }
        foreach ($source in $sources) {
            $key = Get-Item -LiteralPath $source.Run -ErrorAction SilentlyContinue
            if ($null -eq $key) { continue }
            $approved = Get-Item -LiteralPath $source.Approved -ErrorAction SilentlyContinue
            foreach ($name in $key.GetValueNames()) {
                if (-not $name) { continue }
                $items.Add([pscustomobject]@{ Name = $name; Who = $hive.Who; Enabled = (Test-StartupEnabled -ApprovedKey $approved -Name $name) })
            }
        }
        if ($hive.Folder -and (Test-Path -LiteralPath $hive.Folder)) {
            $approved = Get-Item -LiteralPath "$($hive.Root)\$approvedPath\StartupFolder" -ErrorAction SilentlyContinue
            foreach ($file in Get-ChildItem -LiteralPath $hive.Folder -File -Force -ErrorAction SilentlyContinue) {
                if ($file.Name -eq 'desktop.ini') { continue }
                $items.Add([pscustomobject]@{ Name = $file.BaseName; Who = $hive.Who; Enabled = (Test-StartupEnabled -ApprovedKey $approved -Name $file.Name) })
            }
        }
    }
    return $items.ToArray()
}

function Invoke-StartupCheck {
    $items = @(Get-StartupItem)
    $enabled = @($items | Where-Object { $_.Enabled })
    # Edge adds a 32-character code to its entry name.
    $names = @($enabled | ForEach-Object { $_.Name -replace '_[0-9A-Fa-f]{32}$', '' } | Select-Object -Unique | Sort-Object)
    $shown = if ($names.Count -gt 15) { ($names[0..14] -join ', ') + ", and $($names.Count - 15) more" } else { $names -join ', ' }
    $text = "$($names.Count) program(s) start with Windows"
    if ($names.Count -gt 0) { $text += ": $shown" }
    $disabled = $items.Count - $enabled.Count
    if ($disabled -gt 0) { $text += " ($disabled more are disabled)" }
    if ($names.Count -ge 15) {
        Add-Finding -Area 'Startup' -Status Warning -Finding "$text." -Advice 'Many programs start with Windows. Disable the ones the user does not need in Task Manager, Startup apps.'
    } else {
        Add-Finding -Area 'Startup' -Status OK -Finding "$text."
    }
    try {
        $boot = Get-RecentEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -Id 100 | Select-Object -First 1
    } catch {
        Add-Finding -Area 'Startup' -Status Skipped -Finding 'The startup time needs administrator rights.'
        return
    }
    if ($boot) {
        $data = @(([xml]$boot.ToXml()).Event.EventData.Data)
        $milliseconds = [double](($data | Where-Object { $_.Name -eq 'BootTime' }).'#text')
        $seconds = [int][Math]::Round($milliseconds / 1000)
        $text = "The last full startup took $seconds seconds ($($boot.TimeCreated.ToString('yyyy-MM-dd')))."
        if ($seconds -ge 120) {
            Add-Finding -Area 'Startup' -Status Warning -Finding $text -Advice 'A slow startup usually comes from a hard disk or from too many startup programs.'
        } else {
            Add-Finding -Area 'Startup' -Status OK -Finding $text
        }
    }
}

function Invoke-StabilityCheck {
    $since = (Get-Date).AddDays(-$EventDays)
    $bugchecks = @(Get-RecentEvent -LogName System -ProviderName 'Microsoft-Windows-WER-SystemErrorReporting' -Id 1001 -Since $since)
    if ($bugchecks.Count -gt 0) {
        $last = $bugchecks | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1
        $code = if ("$($last.Properties[0].Value)" -match '^0x[0-9a-fA-F]+') { $Matches[0] } else { 'unknown' }
        Add-Finding -Area 'Stability' -Status Critical -Finding "$($bugchecks.Count) blue screen(s) in the last $EventDays days. Last one: $($last.TimeCreated.ToString('yyyy-MM-dd HH:mm')), stop code $code." -Advice "Update the drivers and the BIOS, test the memory, and repair Windows. The crash dumps are in $env:windir\Minidump." -Suggest 'MemoryTest', 'RepairWindows'
    }
    $powerLoss = @(Get-RecentEvent -LogName System -ProviderName 'Microsoft-Windows-Kernel-Power' -Id 41 -Since $since | Where-Object { "$($_.Properties[0].Value)" -eq '0' })
    if ($powerLoss.Count -gt 0) {
        Add-Finding -Area 'Stability' -Status Warning -Finding "$($powerLoss.Count) time(s) in the last $EventDays days Windows stopped without shutting down (power cut, frozen PC switched off, or battery out)." -Advice 'If nobody pulled the plug, the PC is freezing: check temperatures, the power supply and the memory.' -Suggest 'MemoryTest'
    }
    $hardware = @(Get-RecentEvent -LogName System -ProviderName 'Microsoft-Windows-WHEA-Logger' -Since $since)
    if ($hardware.Count -gt 0) {
        $fatal = @($hardware | Where-Object { $_.Level -le 2 }).Count
        $status = if ($fatal -gt 0) { 'Critical' } else { 'Warning' }
        Add-Finding -Area 'Stability' -Status $status -Finding "The hardware reported $($hardware.Count) error(s) in the last $EventDays days ($fatal not corrected)." -Advice 'The processor, memory or a PCIe device is reporting errors. Test the memory and update the BIOS.' -Suggest 'MemoryTest'
    }
    if ($bugchecks.Count -eq 0 -and $powerLoss.Count -eq 0 -and $hardware.Count -eq 0) {
        Add-Finding -Area 'Stability' -Status OK -Finding "No blue screens, hardware errors or unexpected shutdowns in the last $EventDays days."
    }
    $memoryTest = Get-RecentEvent -LogName System -ProviderName 'Microsoft-Windows-MemoryDiagnostics-Results' | Select-Object -First 1
    if ($memoryTest) {
        $date = $memoryTest.TimeCreated.ToString('yyyy-MM-dd')
        if ($memoryTest.Id -in 1102, 1202 -or ($memoryTest.Level -gt 0 -and $memoryTest.Level -le 2)) {
            Add-Finding -Area 'Stability' -Status Critical -Finding "The last memory test ($date) found errors." -Advice 'Replace the faulty memory module; test the modules one by one to find it.'
        } else {
            Add-Finding -Area 'Stability' -Status Info -Finding "The last memory test ($date) found no errors."
        }
    }
    $crashes = @(Get-RecentEvent -LogName Application -ProviderName 'Application Error' -Id 1000 -Since $since)
    if ($crashes.Count -gt 0) {
        $apps = ($crashes | Group-Object -Property { "$($_.Properties[0].Value)" } | Sort-Object -Property Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
        $status = if ($crashes.Count -ge 10) { 'Warning' } else { 'Info' }
        Add-Finding -Area 'Stability' -Status $status -Finding "$($crashes.Count) program crash(es) in the last $EventDays days, most: $apps." -Advice $(if ($status -eq 'Warning') { 'Update or reinstall the program that crashes most. If they are Windows programs, repair Windows.' } else { '' })
    }
}

function Invoke-UpdateCheck {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue
    if ($service -and $service.StartMode -eq 'Disabled') {
        Add-Finding -Area 'Windows Update' -Status Warning -Finding 'The Windows Update service is disabled.' -Advice 'Unless another tool manages updates on purpose, set the service back to Manual.'
    }
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $count = $searcher.GetTotalHistoryCount()
    if ($count -eq 0) {
        Add-Finding -Area 'Windows Update' -Status Warning -Finding 'Windows Update has no install history on this PC.' -Advice 'Run Windows Update, or check the update policy (WSUS, Intune) for this PC.'
        return
    }
    $history = @($searcher.QueryHistory(0, [Math]::Min($count, 300)) | Where-Object { $_.Operation -eq 1 })
    # Only Windows updates (they carry a KB number). Store apps and the daily antivirus definitions would
    # hide a PC whose Windows updates are stuck.
    $updates = @($history | Where-Object { $_.Title -match 'KB\d{6,8}' -and $_.Title -notmatch 'KB2267602|KB4052623|KB2461484|Defender' })
    $installed = @($updates | Where-Object { $_.ResultCode -in 2, 3 } | Sort-Object -Property Date -Descending)
    if ($installed.Count -gt 0) {
        $last = $installed[0].Date.ToLocalTime()
        $days = [int][Math]::Floor(((Get-Date) - $last).TotalDays)
        $text = "The last Windows update was installed $days day(s) ago ($($last.ToString('yyyy-MM-dd'))): $($installed[0].Title)."
        if ($days -gt 45) {
            Add-Finding -Area 'Windows Update' -Status Warning -Finding $text -Advice 'Run Windows Update, or check the update policy (WSUS, Intune) for this PC.'
        } else {
            Add-Finding -Area 'Windows Update' -Status OK -Finding $text
        }
    } else {
        Add-Finding -Area 'Windows Update' -Status Warning -Finding 'No Windows update has installed successfully in the update history.' -Advice 'Run Windows Update, or check the update policy (WSUS, Intune) for this PC.'
    }
    $since = (Get-Date).AddDays(-$EventDays).ToUniversalTime()
    # A failure counts only while the same KB has not installed afterwards.
    $failed = @($updates | Where-Object { $_.ResultCode -eq 4 -and $_.Date -ge $since } | Where-Object {
        $attempt = $_
        $kb = [regex]::Match($attempt.Title, 'KB\d{6,8}').Value
        @($installed | Where-Object { $_.Title -match $kb -and $_.Date -gt $attempt.Date }).Count -eq 0
    } | Sort-Object -Property Date -Descending)
    if ($failed.Count -gt 0) {
        Add-Finding -Area 'Windows Update' -Status Warning -Finding "$($failed.Count) update(s) failed to install in the last $EventDays days. Last one: $($failed[0].Title)." -Advice 'Restart, clear the Windows Update downloads, repair Windows and try again.' -Suggest 'UpdateCache', 'RepairWindows'
    }
}

function Invoke-WindowsImageCheck {
    if (-not $script:IsAdmin) {
        Add-Finding -Area 'Windows image' -Status Skipped -Finding 'Checking the Windows image needs administrator rights.'
        return
    }
    $run = Invoke-NativeTool -FilePath (Get-SystemToolPath -FileName 'dism.exe') -ArgumentList '/Online', '/Cleanup-Image', '/CheckHealth'
    if ($run.ExitCode -ne 0) { throw ('DISM /CheckHealth ended with code 0x{0:X8}.' -f $run.ExitCode) }
    # The verdict is the line before "The operation completed successfully."
    $lines = @($run.Lines)
    $verdict = if ($lines.Count -ge 2) { $lines[$lines.Count - 2] } else { "$($lines[-1])" }
    if ($verdict -match 'cannot be repaired') {
        Add-Finding -Area 'Windows image' -Status Critical -Finding "DISM /CheckHealth: $verdict" -Advice 'DISM cannot repair it from Windows Update: use a Windows ISO of the same version as the repair source, or repair-install Windows.'
    } elseif ($verdict -match 'repairable') {
        Add-Finding -Area 'Windows image' -Status Warning -Finding "DISM /CheckHealth: $verdict" -Advice 'The Windows image is damaged and can be repaired: run Repair Windows files.' -Suggest 'RepairWindows'
    } elseif ($verdict -match 'No component store corruption') {
        Add-Finding -Area 'Windows image' -Status OK -Finding "DISM /CheckHealth: $verdict"
    } else {
        Add-Finding -Area 'Windows image' -Status Info -Finding "DISM /CheckHealth: $verdict"
    }
}

function Invoke-SecurityCheck {
    if ($script:Os.ProductType -ne 1) {
        Add-Finding -Area 'Security software' -Status Info -Finding 'Windows Server has no Security Center to read the antivirus from.'
        return
    }
    $products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop)
    $active = @($products | Where-Object { (($_.productState -shr 12) -band 0xF) -eq 1 })
    $outdated = @($active | Where-Object { (($_.productState -shr 4) -band 0xF) -ne 0 })
    $names = ($active | Select-Object -ExpandProperty displayName -Unique) -join ', '
    if ($active.Count -eq 0) {
        Add-Finding -Area 'Security software' -Status Warning -Finding 'No antivirus reports itself as on.' -Advice 'Check the antivirus or EDR agent the company uses. Some register in Security Center only partly.'
    } elseif (@($active | Select-Object -ExpandProperty displayName -Unique).Count -gt 1) {
        Add-Finding -Area 'Security software' -Status Warning -Finding "More than one antivirus is on: $names." -Advice 'Two antivirus programs scan every file twice and slow the PC down. Keep the one the company uses.'
    } elseif ($outdated.Count -gt 0) {
        Add-Finding -Area 'Security software' -Status Warning -Finding "$names is on, but its definitions are out of date." -Advice 'Update the antivirus definitions.'
    } else {
        Add-Finding -Area 'Security software' -Status OK -Finding "$names is on and up to date."
    }
}

function Invoke-BatteryCheck {
    $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($batteries.Count -eq 0) { return }
    $full = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
    $design = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop)
    foreach ($battery in $full) {
        $match = $design | Where-Object { $_.InstanceName -eq $battery.InstanceName } | Select-Object -First 1
        if (-not $match -or -not $match.DesignedCapacity) { continue }
        $percent = [int][Math]::Round($battery.FullChargedCapacity * 100 / $match.DesignedCapacity)
        $text = "The battery holds $percent% of the charge it held when new."
        if ($percent -lt 40) {
            Add-Finding -Area 'Battery' -Status Critical -Finding $text -Advice 'Replace the battery.'
        } elseif ($percent -lt 70) {
            Add-Finding -Area 'Battery' -Status Warning -Finding $text -Advice 'The battery is worn: plan to replace it.'
        } else {
            Add-Finding -Area 'Battery' -Status OK -Finding $text
        }
    }
}

function Invoke-PowerPlanCheck {
    $output = (& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()
    if ($output -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        throw "powercfg did not return the active plan: $output"
    }
    $guid = $Matches[1].ToLowerInvariant()
    $name = if ($output -match '\(([^)]+)\)\s*$') { $Matches[1] } else { $guid }
    if ($guid -eq $script:PowerSaverPlan) {
        Add-Finding -Area 'Power' -Status Warning -Finding "The power plan is $name." -Advice 'The Power saver plan slows the processor down. Switch to Balanced.'
    } else {
        Add-Finding -Area 'Power' -Status OK -Finding "The power plan is $name."
    }
}

function Invoke-NetworkCheck {
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
    if ($configs.Count -eq 0) {
        Add-Finding -Area 'Network' -Status Critical -Finding 'No network adapter is connected with a default gateway.' -Advice 'Check the cable or the Wi-Fi, then the IP settings (ipconfig /all).'
        return
    }
    $ping = New-Object System.Net.NetworkInformation.Ping
    foreach ($config in $configs) {
        $adapter = $config.NetAdapter
        $addresses = @($config.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '
        $gateway = @($config.IPv4DefaultGateway | ForEach-Object { $_.NextHop })[0]
        $dns = @($config.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
        $replies = @(foreach ($i in 1..2) {
            try {
                $reply = $ping.Send($gateway, 1000)
                if ($reply.Status -eq 'Success') { $reply.RoundtripTime }
            } catch {
                Write-Verbose "Ping to the gateway $gateway failed: $($_.Exception.Message)"
            }
        })
        $gatewayText = if ($replies.Count -gt 0) { "gateway $gateway (answered in $(($replies | Measure-Object -Maximum).Maximum) ms)" } else { "gateway $gateway (did not answer ping)" }
        $text = "$($config.InterfaceAlias): $addresses, $gatewayText, DNS $dns, link $($adapter.LinkSpeed)."
        $wired = "$($adapter.PhysicalMediaType)" -eq '802.3'
        if ($wired -and $adapter.Speed -gt 0 -and $adapter.Speed -le 100000000) {
            Add-Finding -Area 'Network' -Status Warning -Finding $text -Advice 'A wired link at 100 Mbps or less usually means a damaged cable, a bad wall port or an old switch port.'
        } elseif ($replies.Count -eq 0) {
            Add-Finding -Area 'Network' -Status Warning -Finding $text -Advice 'The gateway did not answer. Some block ping on purpose; if pages do not load either, check the connection.'
        } else {
            Add-Finding -Area 'Network' -Status OK -Finding $text
        }
    }
    $name = if ($script:ComputerSystem.PartOfDomain) { $script:ComputerSystem.Domain } else { 'www.microsoft.com' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Resolve-DnsName -Name $name -DnsOnly -ErrorAction Stop
        Add-Finding -Area 'Network' -Status OK -Finding "DNS resolved $name in $([int]$watch.Elapsed.TotalMilliseconds) ms."
    } catch {
        Add-Finding -Area 'Network' -Status Critical -Finding "DNS could not resolve $($name): $($_.Exception.Message.Trim())" -Advice 'Check the DNS servers above and clear the DNS cache.' -Suggest 'DnsCache'
    }
}

function Invoke-PCCheck {
    Write-MaintenanceLog -Message 'Checking the PC. Nothing is changed.'
    Invoke-CheckStep -Area 'Restart' -Body { Invoke-RestartCheck }
    Invoke-CheckStep -Area 'Disk space' -Body { Invoke-DiskSpaceCheck }
    Invoke-CheckStep -Area 'Disk health' -Body { Invoke-DiskHealthCheck }
    Invoke-CheckStep -Area 'Disk errors' -Body { Invoke-DiskEventCheck }
    Invoke-CheckStep -Area 'Memory' -Body { Invoke-MemoryCheck }
    Invoke-CheckStep -Area 'Processor' -Body { Invoke-ProcessorCheck }
    Invoke-CheckStep -Area 'Startup' -Body { Invoke-StartupCheck }
    Invoke-CheckStep -Area 'Stability' -Body { Invoke-StabilityCheck }
    Invoke-CheckStep -Area 'Windows Update' -Body { Invoke-UpdateCheck }
    Invoke-CheckStep -Area 'Windows image' -Body { Invoke-WindowsImageCheck }
    Invoke-CheckStep -Area 'Security software' -Body { Invoke-SecurityCheck }
    Invoke-CheckStep -Area 'Battery' -Body { Invoke-BatteryCheck }
    Invoke-CheckStep -Area 'Power' -Body { Invoke-PowerPlanCheck }
    Invoke-CheckStep -Area 'Network' -Body { Invoke-NetworkCheck }
}

# --- Tasks ---------------------------------------------------------------------------------------------

function Invoke-FolderCleanup {
    # Deletes the files under Path (only those older than Cutoff, when given), then the folders left empty.
    # Never enters a junction or symbolic link, so nothing outside Path can be reached. Path itself stays.
    param(
        [string]$Path,
        [Nullable[datetime]]$Cutoff,
        [string[]]$KeepRootFile = @(),
        [switch]$CountOnly
    )
    $result = [pscustomobject]@{ Files = 0; Bytes = [long]0; InUse = 0; Folders = 0; Unreadable = 0 }
    $root = New-Object System.IO.DirectoryInfo($Path)
    if (-not $root.Exists) { return $result }
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push($root)
    $folders = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    while ($stack.Count -gt 0) {
        $folder = $stack.Pop()
        try {
            $entries = $folder.GetFileSystemInfos()
        } catch {
            $result.Unreadable++
            continue
        }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry -is [System.IO.DirectoryInfo]) {
                $stack.Push($entry)
                $folders.Add($entry)
                continue
            }
            if ($folder.FullName -eq $root.FullName -and $KeepRootFile -contains $entry.Name) { continue }
            if ($null -ne $Cutoff -and $entry.LastWriteTime -ge $Cutoff) { continue }
            if ($CountOnly) {
                $result.Files++
                $result.Bytes += $entry.Length
                continue
            }
            try {
                $size = $entry.Length
                if ($entry.IsReadOnly) { $entry.IsReadOnly = $false }
                $entry.Delete()
                $result.Files++
                $result.Bytes += $size
            } catch {
                $result.InUse++
            }
        }
    }
    if (-not $CountOnly) {
        # A folder is found after its parent, so going backwards empties children before parents.
        for ($i = $folders.Count - 1; $i -ge 0; $i--) {
            $folder = $folders[$i]
            if ($null -ne $Cutoff -and $folder.CreationTime -ge $Cutoff) { continue }
            try {
                if (-not $folder.EnumerateFileSystemInfos().GetEnumerator().MoveNext()) {
                    $folder.Delete()
                    $result.Folders++
                }
            } catch {
                Write-Verbose "Folder left in place: $($folder.FullName): $($_.Exception.Message)"
            }
        }
    }
    return $result
}

function Format-CleanupResult {
    param([string]$Label, $Result, [bool]$CountOnly)
    $verb = if ($CountOnly) { 'would delete' } else { 'deleted' }
    $text = '{0}: {1} {2:N0} file(s), {3}' -f $Label, $verb, $Result.Files, (Format-Size $Result.Bytes)
    if ($Result.InUse -gt 0) { $text += "; $($Result.InUse) in use were left" }
    if ($Result.Unreadable -gt 0) { $text += "; $($Result.Unreadable) folder(s) could not be opened" }
    return $text
}

function Invoke-TempFilesTask {
    $cutoff = (Get-Date).AddDays(-$TempFileAgeDays)
    $folders = New-Object System.Collections.Generic.List[string]
    if ($script:IsAdmin) {
        $folders.Add((Join-Path $env:windir 'Temp'))
        foreach ($entry in Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue) {
            if ($entry.PSChildName -notmatch '^S-1-5-21-') { continue }
            $profilePath = $entry.GetValue('ProfileImagePath')
            if ($profilePath) { $folders.Add((Join-Path ([Environment]::ExpandEnvironmentVariables($profilePath)) 'AppData\Local\Temp')) }
        }
    } else {
        $folders.Add([IO.Path]::GetTempPath().TrimEnd('\'))
    }
    $details = New-Object System.Collections.Generic.List[string]
    $freed = [long]0
    foreach ($folder in @($folders | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $result = Invoke-FolderCleanup -Path $folder -Cutoff $cutoff -CountOnly:$DryRun
        if ($result.Files -eq 0 -and $result.InUse -eq 0 -and $result.Unreadable -eq 0) { continue }
        $freed += $result.Bytes
        $details.Add((Format-CleanupResult -Label $folder -Result $result -CountOnly $DryRun.IsPresent))
    }
    if ($details.Count -eq 0) { $details.Add("No temporary files older than $TempFileAgeDays days.") }
    if (-not $script:IsAdmin) { $details.Add('Without administrator rights, only the temporary folder of the current user.') }
    return @{ Freed = $freed; Details = $details }
}

function Invoke-RecycleBinTask {
    $mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $details = New-Object System.Collections.Generic.List[string]
    $freed = [long]0
    $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Select-Object -ExpandProperty DeviceID)
    foreach ($drive in $drives) {
        $root = "$drive\`$Recycle.Bin"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $bins = if ($script:IsAdmin) {
            @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'S-1-5-*' } | Select-Object -ExpandProperty FullName)
        } else {
            @(Join-Path $root $mySid)
        }
        foreach ($bin in $bins) {
            if (-not (Test-Path -LiteralPath $bin)) { continue }
            $result = Invoke-FolderCleanup -Path $bin -KeepRootFile 'desktop.ini' -CountOnly:$DryRun
            if ($result.Files -eq 0 -and $result.InUse -eq 0 -and $result.Unreadable -eq 0) { continue }
            $freed += $result.Bytes
            $details.Add((Format-CleanupResult -Label "$drive $(Get-AccountName -Sid (Split-Path -Leaf $bin))" -Result $result -CountOnly $DryRun.IsPresent))
        }
    }
    if ($details.Count -eq 0) { $details.Add('The Recycle Bin was already empty.') }
    if (-not $script:IsAdmin) { $details.Add('Without administrator rights, only the Recycle Bin of the current user.') }
    return @{ Freed = $freed; Details = $details }
}

function Invoke-UpdateCacheTask {
    $reasons = @(Get-PendingRestartReason)
    if ($reasons -contains 'Windows Update' -or $reasons -contains 'Windows components') {
        return @{ Status = 'Skipped'; Details = @('Windows Update is waiting for a restart. Restart the PC first, then run this task.') }
    }
    $download = Join-Path $env:windir 'SoftwareDistribution\Download'
    $details = New-Object System.Collections.Generic.List[string]
    if ($DryRun) {
        $result = Invoke-FolderCleanup -Path $download -CountOnly
        $details.Add((Format-CleanupResult -Label $download -Result $result -CountOnly $true))
        $details.Add('Would stop Windows Update and BITS while deleting, start them again, and clear the Delivery Optimization cache.')
        return @{ Freed = $result.Bytes; Details = $details }
    }
    $stopped = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($name in 'wuauserv', 'bits') {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Stop-Service -Name $name -Force -ErrorAction Stop
                $stopped.Add($name)
                Write-MaintenanceLog -Message "Stopped the $name service for a moment."
            }
        }
        $result = Invoke-FolderCleanup -Path $download
        $details.Add((Format-CleanupResult -Label $download -Result $result -CountOnly $false))
    } finally {
        foreach ($name in $stopped) {
            try {
                Start-Service -Name $name -ErrorAction Stop
                Write-MaintenanceLog -Message "Started the $name service again."
            } catch {
                $details.Add("The $name service could not be started again: $($_.Exception.Message.Trim())")
            }
        }
    }
    if (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            $details.Add('Delivery Optimization cache cleared.')
        } catch {
            $details.Add("Delivery Optimization cache not cleared: $($_.Exception.Message.Trim())")
        }
    }
    return @{ Freed = $result.Bytes; Details = $details }
}

function Invoke-DnsCacheTask {
    if ($DryRun) {
        $count = @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count
        $text = if ($count -gt 0) { "Would clear $count cached DNS entries." } else { 'The DNS cache is empty: nothing to clear.' }
        return @{ Details = @($text) }
    }
    try {
        Clear-DnsClientCache -ErrorAction Stop
    } catch {
        $output = (& ipconfig.exe /flushdns 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "ipconfig /flushdns failed: $output" }
    }
    return @{ Details = @('DNS cache cleared.') }
}

function Invoke-ComponentCleanupTask {
    $dism = Get-SystemToolPath -FileName 'dism.exe'
    if ($DryRun) {
        $run = Invoke-NativeTool -FilePath $dism -ArgumentList '/Online', '/Cleanup-Image', '/AnalyzeComponentStore'
        $summary = @($run.Lines | Where-Object { $_ -match 'Reclaimable|Recommended' })
        $details = @('Would run DISM /StartComponentCleanup.') + $(if ($summary.Count -gt 0) { $summary } else { @('The component store analysis is in the log.') })
        return @{ Details = $details }
    }
    $before = Get-SystemDriveFreeSpace
    $run = Invoke-NativeTool -FilePath $dism -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup'
    $after = Get-SystemDriveFreeSpace
    if ($run.ExitCode -ne 0) { throw ('DISM /StartComponentCleanup failed with code 0x{0:X8}. Details: {1}\Logs\DISM\dism.log' -f $run.ExitCode, $env:windir) }
    $freed = if ($null -ne $before -and $null -ne $after -and $after -gt $before) { $after - $before } else { [long]0 }
    return @{ Freed = $freed; Details = @('Old components removed.') }
}

function Invoke-OptimizeDriveTask {
    $letter = $env:SystemDrive.TrimEnd(':')
    $media = 'disk'
    try {
        $number = (Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1).DiskNumber
        $physical = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$number" } | Select-Object -First 1
        if ($physical -and "$($physical.MediaType)" -in 'SSD', 'HDD') { $media = "$($physical.MediaType)" }
    } catch {
        $media = 'disk'
    }
    $method = switch ($media) { 'SSD' { 'TRIM' } 'HDD' { 'defragmentation' } default { 'the method Windows picks for it' } }
    if ($DryRun) { return @{ Details = @("Would optimize $env:SystemDrive ($media) with $method.") } }
    Optimize-Volume -DriveLetter $letter -Verbose -ErrorAction Stop 4>&1 | ForEach-Object { Write-MaintenanceLog -Message "  $_" }
    return @{ Details = @("$env:SystemDrive ($media) optimized with $method.") }
}

function Invoke-RepairWindowsTask {
    $dism = Get-SystemToolPath -FileName 'dism.exe'
    $sfc = Get-SystemToolPath -FileName 'sfc.exe'
    $logs = "Details: $env:windir\Logs\DISM\dism.log and $env:windir\Logs\CBS\CBS.log."
    if ($DryRun) {
        $quick = Invoke-NativeTool -FilePath $dism -ArgumentList '/Online', '/Cleanup-Image', '/CheckHealth'
        $last = @($quick.Lines | Select-Object -Last 2)
        return @{ Details = @('Would run DISM /RestoreHealth, then SFC /scannow.', "Quick check (DISM /CheckHealth, code $($quick.ExitCode)): $($last -join ' ')") }
    }
    $details = New-Object System.Collections.Generic.List[string]
    $status = 'Done'
    # DISM first: SFC takes its good copies from the image DISM repairs.
    $image = Invoke-NativeTool -FilePath $dism -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth'
    if ($image.ExitCode -eq 0) {
        $details.Add('DISM /RestoreHealth finished without errors.')
    } else {
        $status = 'Attention'
        $details.Add(('DISM /RestoreHealth failed with code 0x{0:X8}.' -f $image.ExitCode))
        if ($image.ExitCode -eq -2146498529) {
            $details.Add('DISM found no repair source. On PCs that update from WSUS, mount a Windows ISO of the same version and run: DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:X:\sources\install.wim:1 /LimitAccess')
        }
    }
    Write-MaintenanceLog -Message 'SFC can wait half an hour for Windows before its first line, and then take an hour or more.'
    $files = Invoke-NativeTool -FilePath $sfc -ArgumentList '/scannow'
    # SFC opens with two "Beginning..." lines in every language; the verdict comes after them.
    $verdict = @($files.Lines | Select-Object -Skip 2)
    if ($verdict.Count -eq 0) { $verdict = @($files.Lines) }
    $result = @($verdict | Select-Object -Last 2) -join ' '
    if ($files.ExitCode -ne 0) { $status = 'Attention' }
    $details.Add("SFC /scannow (code $($files.ExitCode)): $result")
    if (@(Get-PendingRestartReason).Count -gt 0) { $details.Add('Restart the PC to finish the repair.') }
    $details.Add($logs)
    return @{ Status = $status; Details = $details }
}

function Invoke-MemoryTestTask {
    if (-not [Environment]::UserInteractive) {
        return @{ Status = 'Skipped'; Details = @('Windows Memory Diagnostic needs a desktop: run it from the window, or run mdsched.exe on the PC.') }
    }
    if ($DryRun) { return @{ Details = @('Would open Windows Memory Diagnostic.') } }
    Start-Process -FilePath (Get-SystemToolPath -FileName 'MdSched.exe') -ErrorAction Stop
    return @{ Details = @('Windows Memory Diagnostic is open: choose to restart now or at the next start. The next check shows the result under Stability.') }
}

function Invoke-MaintenanceTask {
    param($Definition)
    Write-MaintenanceLog -Message "Task: $($Definition.Title)$(if ($DryRun) { ' (dry run)' })"
    $result = [pscustomobject]@{ Task = $Definition.Name; Title = $Definition.Title; Status = ''; Freed = $null; Details = '' }
    if ($Definition.NeedsAdmin -and -not $script:IsAdmin) {
        $result.Status = 'Skipped'
        $result.Details = 'Needs administrator rights.'
    } else {
        try {
            $outcome = switch ($Definition.Name) {
                'TempFiles' { Invoke-TempFilesTask }
                'RecycleBin' { Invoke-RecycleBinTask }
                'UpdateCache' { Invoke-UpdateCacheTask }
                'DnsCache' { Invoke-DnsCacheTask }
                'ComponentCleanup' { Invoke-ComponentCleanupTask }
                'OptimizeDrive' { Invoke-OptimizeDriveTask }
                'RepairWindows' { Invoke-RepairWindowsTask }
                'MemoryTest' { Invoke-MemoryTestTask }
            }
            $result.Status = if ($outcome.Status) { $outcome.Status } elseif ($DryRun) { 'Dry run' } else { 'Done' }
            if ($null -ne $outcome.Freed) { $result.Freed = [long]$outcome.Freed }
            $result.Details = @($outcome.Details) -join "`n"
        } catch {
            $result.Status = 'Failed'
            $result.Details = $_.Exception.Message.Trim()
        }
    }
    $level = switch ($result.Status) { 'Failed' { 'ERROR' } 'Attention' { 'WARN' } 'Skipped' { 'WARN' } default { 'OK' } }
    $freedText = if ($null -ne $result.Freed) { " ($(Format-Size $result.Freed))" } else { '' }
    Write-MaintenanceLog -Message "$($Definition.Title) - $($result.Status)$($freedText): $($result.Details -replace "`n", ' | ')" -Level $level
    $script:TaskResults.Add($result)
}

# --- Report --------------------------------------------------------------------------------------------

function ConvertTo-MaintenanceReport {
    param($Summary, [object[]]$Findings, [object[]]$TaskResults, $FreeBefore, $FreeAfter, [bool]$IsDryRun, [bool]$Checked, [string]$LogFile)
    $encode = { param($Text) [System.Net.WebUtility]::HtmlEncode("$Text") -replace "`n", '<br>' }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine("<html lang=""en""><head><meta charset=""utf-8""><title>PC Maintenance - $(& $encode $Summary['Computer'])</title>")
    $null = $sb.AppendLine(@'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; max-width: 1200px; }
h1 { font-size: 22px; margin-bottom: 4px; }
h2 { font-size: 17px; margin-top: 28px; }
.meta { color: #59636e; margin-top: 0; }
.banner { background: #ddf4ff; border: 1px solid #54aeff; border-radius: 6px; padding: 8px 12px; }
.cards { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 14px; }
.card { border: 1px solid #d1d9e0; border-radius: 6px; padding: 8px 16px; min-width: 100px; }
.card b { display: block; font-size: 22px; }
table { border-collapse: collapse; font-size: 14px; width: 100%; }
th, td { border: 1px solid #d1d9e0; padding: 5px 10px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
.kv { width: auto; }
.kv th { white-space: nowrap; }
td.nowrap { white-space: nowrap; }
.badge { display: inline-block; border-radius: 10px; padding: 1px 9px; font-weight: 600; color: #fff; white-space: nowrap; }
.Critical, .Failed { background: #cf222e; }
.Warning, .Attention { background: #9a6700; }
.OK, .Done { background: #1a7f37; }
.Info, .DryRun { background: #0969da; }
.Skipped { background: #59636e; }
.foot { color: #59636e; font-size: 13px; margin-top: 24px; }
</style></head><body>
'@)
    $null = $sb.AppendLine("<h1>PC Maintenance: $(& $encode $Summary['Computer'])</h1>")
    $null = $sb.AppendLine("<p class=""meta"">$(& $encode $Summary['Date']), run by $(& $encode $Summary['Run by']).</p>")
    if ($IsDryRun -and $TaskResults.Count -gt 0) {
        $null = $sb.AppendLine('<p class="banner">Dry run: the tasks say what they would do. Nothing was changed.</p>')
    }
    $null = $sb.AppendLine('<h2>This PC</h2><table class="kv">')
    foreach ($key in $Summary.Keys) {
        if ($key -in 'Run by', 'Date') { continue }
        $null = $sb.AppendLine("<tr><th>$(& $encode $key)</th><td>$(& $encode $Summary[$key])</td></tr>")
    }
    $null = $sb.AppendLine('</table>')
    if ($Checked) {
        $null = $sb.AppendLine('<h2>Check</h2><div class="cards">')
        foreach ($status in 'Critical', 'Warning', 'OK', 'Info', 'Skipped') {
            $count = @($Findings | Where-Object { $_.Status -eq $status }).Count
            $null = $sb.AppendLine("<div class=""card""><b>$count</b><span class=""badge $status"">$status</span></div>")
        }
        $null = $sb.AppendLine('</div>')
        $null = $sb.AppendLine('<table><tr><th>Status</th><th>Area</th><th>Finding</th><th>What to do</th></tr>')
        foreach ($f in @(Get-OrderedFinding -Findings $Findings)) {
            $null = $sb.AppendLine("<tr><td><span class=""badge $($f.Status)"">$($f.Status)</span></td><td class=""nowrap"">$(& $encode $f.Area)</td><td>$(& $encode $f.Finding)</td><td>$(& $encode $f.Advice)</td></tr>")
        }
        $null = $sb.AppendLine('</table>')
        $suggested = @(Get-SuggestedTask -Findings $Findings)
        if ($suggested.Count -gt 0) {
            $titles = ($script:TaskCatalog | Where-Object { $_.Name -in $suggested } | ForEach-Object { "$($_.Title) ($($_.Name))" }) -join ', '
            $null = $sb.AppendLine("<p>Suggested tasks: $(& $encode $titles).</p>")
        }
    }
    if ($TaskResults.Count -gt 0) {
        $null = $sb.AppendLine('<h2>Tasks</h2>')
        $null = $sb.AppendLine('<table><tr><th>Task</th><th>Result</th><th>Space</th><th>Details</th></tr>')
        foreach ($t in $TaskResults) {
            $class = if ($t.Status -eq 'Dry run') { 'DryRun' } else { $t.Status }
            $space = if ($null -ne $t.Freed) { Format-Size $t.Freed } else { '' }
            $null = $sb.AppendLine("<tr><td class=""nowrap"">$(& $encode $t.Title)</td><td><span class=""badge $class"">$(& $encode $t.Status)</span></td><td class=""nowrap"">$space</td><td>$(& $encode $t.Details)</td></tr>")
        }
        $null = $sb.AppendLine('</table>')
        if (-not $IsDryRun -and $null -ne $FreeBefore -and $null -ne $FreeAfter) {
            $null = $sb.AppendLine("<p>Free space on $($env:SystemDrive) $(Format-Size $FreeBefore) before, $(Format-Size $FreeAfter) after.</p>")
        }
    }
    $null = $sb.AppendLine("<p class=""foot"">Log: $(& $encode $LogFile)</p>")
    $null = $sb.AppendLine('</body></html>')
    return $sb.ToString()
}

function Get-SuggestedTask {
    param([object[]]$Findings)
    $names = @($Findings | Where-Object { $_.Status -in 'Critical', 'Warning' } | ForEach-Object { $_.Suggest } | Where-Object { $_ } | Select-Object -Unique)
    return $script:TaskCatalog | Where-Object { $_.Name -in $names } | ForEach-Object { $_.Name }
}

function Get-OrderedFinding {
    # The worst first; within one status, in the order the checks found them. Used by the report and
    # by the window, which reads the findings back from the JSON file.
    param([object[]]$Findings)
    $i = 0
    $Findings | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Item = $_; Rank = $script:StatusRank["$($_.Status)"]; Order = $i }; $i++ } |
        Sort-Object -Property Rank, Order | ForEach-Object { $_.Item }
}

function Get-RunSummary {
    # One line, such as "Check: 1 critical, 5 warnings. Tasks: 3 run, 0 failed.", for the log and the window.
    param([object[]]$Findings, [object[]]$Tasks, [bool]$Checked)
    $counts = foreach ($status in 'Critical', 'Warning') {
        $n = @($Findings | Where-Object { $_.Status -eq $status }).Count
        if ($n -gt 0) { "$n $($status.ToLowerInvariant())$(if ($status -eq 'Warning' -and $n -gt 1) { 's' })" }
    }
    $line = if ($Checked) { "Check: $(if ($counts) { $counts -join ', ' } else { 'nothing critical or to watch' })." } else { '' }
    if (@($Tasks).Count -gt 0) { $line += " Tasks: $(@($Tasks).Count) run, $(@($Tasks | Where-Object { $_.Status -eq 'Failed' }).Count) failed." }
    return $line.Trim()
}

function Invoke-Run {
    # The run without a window: what the command line and the window's worker process both use.
    param([string[]]$TaskNames)
    Write-MaintenanceLog -Message "PC Maintenance on $env:COMPUTERNAME, run by $env:USERDOMAIN\$env:USERNAME $(if ($script:IsAdmin) { 'as administrator' } else { 'without administrator rights' })$(if ($DryRun) { ', dry run' })."
    $summary = Get-SystemSummary
    $freeBefore = Get-SystemDriveFreeSpace
    if ($Check) { Invoke-PCCheck }
    foreach ($definition in $script:TaskCatalog) {
        if ($TaskNames -contains $definition.Name) { Invoke-MaintenanceTask -Definition $definition }
    }
    $freeAfter = Get-SystemDriveFreeSpace
    $findings = $script:Findings.ToArray()
    $tasks = $script:TaskResults.ToArray()
    $html = ConvertTo-MaintenanceReport -Summary $summary -Findings $findings -TaskResults $tasks -FreeBefore $freeBefore -FreeAfter $freeAfter -IsDryRun $DryRun.IsPresent -Checked $Check.IsPresent -LogFile $script:LogFile
    [System.IO.File]::WriteAllText($script:ReportFile, $html, $script:Utf8)
    $output = [pscustomobject]@{
        System     = [pscustomobject]$summary
        Findings   = $findings
        Suggested  = @(Get-SuggestedTask -Findings $findings)
        Tasks      = $tasks
        FreeBefore = $freeBefore
        FreeAfter  = $freeAfter
        DryRun     = $DryRun.IsPresent
        ReportPath = $script:ReportFile
        LogPath    = $script:LogFile
    }
    if ($JsonPath) {
        [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $output -Depth 6), $script:Utf8)
    }
    $attention = @($findings | Where-Object { $_.Status -in 'Critical', 'Warning' }).Count + @($tasks | Where-Object { $_.Status -eq 'Failed' }).Count
    Write-MaintenanceLog -Message (Get-RunSummary -Findings $findings -Tasks $tasks -Checked $Check.IsPresent) -Level $(if ($attention -gt 0) { 'WARN' } else { 'OK' })
    Write-MaintenanceLog -Message "Report: $script:ReportFile"
    return $output
}

# --- Window --------------------------------------------------------------------------------------------

function Get-WindowSetting {
    $path = Join-Path $env:APPDATA 'PC-Maintenance\settings.json'
    $default = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PC Maintenance'
    try {
        if (Test-Path -LiteralPath $path) {
            $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($saved.ReportFolder) { return [pscustomobject]@{ ReportFolder = "$($saved.ReportFolder)" } }
        }
    } catch {
        Write-Verbose "Saved settings not read, using the defaults: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ ReportFolder = $default }
}

function Save-WindowSetting {
    param([string]$ReportFolder)
    try {
        $folder = Join-Path $env:APPDATA 'PC-Maintenance'
        if (-not (Test-Path -LiteralPath $folder)) { $null = [IO.Directory]::CreateDirectory($folder) }
        $json = ConvertTo-Json -InputObject ([pscustomobject]@{ ReportFolder = $ReportFolder })
        [System.IO.File]::WriteAllText((Join-Path $folder 'settings.json'), $json, $script:Utf8)
    } catch {
        Write-Verbose "Settings not saved: $($_.Exception.Message)"
    }
}

function Resolve-NetworkDrivePath {
    # An elevated process does not see the drive letters mapped by the user, so use the UNC path.
    param([string]$Path)
    if ($Path -notmatch '^([A-Za-z]:)(\\.*)?$') { return $Path }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($Matches[1].ToUpperInvariant())'" -ErrorAction SilentlyContinue
    if ($disk -and $disk.DriveType -eq 4 -and $disk.ProviderName) { return $disk.ProviderName + $Matches[2] }
    return $Path
}

function Switch-WindowState {
    param([bool]$Busy)
    $ui = $script:Ui
    foreach ($name in 'Run', 'Browse', 'Suggested') { $ui[$name].Enabled = -not $Busy }
    $ui.Progress.Style = if ($Busy) { 'Marquee' } else { 'Blocks' }
    $ui.Progress.MarqueeAnimationSpeed = if ($Busy) { 30 } else { 0 }
    if (-not $Busy) { $ui.Suggested.Enabled = $script:SuggestedTasks.Count -gt 0 }
}

function Invoke-WorkerRun {
    $ui = $script:Ui
    $selected = @($script:TaskCatalog | Where-Object { $ui.Tasks[$_.Name].Checked } | ForEach-Object { $_.Name })
    if (-not $ui.Check.Checked -and $selected.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Tick the check or at least one task.', 'Nothing to run')
        return
    }
    $elevate = $ui.Admin.Checked -and -not $script:IsAdmin
    $asAdmin = $script:IsAdmin -or $elevate
    $changing = @($script:TaskCatalog | Where-Object { $_.Changes -and $_.Name -in $selected })
    if ($changing.Count -gt 0 -and -not $ui.DryRun.Checked) {
        $lines = foreach ($definition in $changing) {
            $note = switch ($definition.Name) {
                'TempFiles' { if ($asAdmin) { 'every user and Windows\Temp' } else { 'the current user only' } }
                'RecycleBin' { if ($asAdmin) { 'every user on this PC, cannot be undone' } else { 'the current user, cannot be undone' } }
                'UpdateCache' { 'Windows downloads again what it still needs' }
                'RepairWindows' { '30 minutes to 2 hours; do not turn the PC off' }
                default { '' }
            }
            '- ' + $definition.Title + $(if ($note) { " ($note)" } else { '' })
        }
        $message = "These tasks change the PC:`r`n`r`n$($lines -join "`r`n")`r`n`r`nContinue?"
        $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Confirm the tasks', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $ui.Status.Text = 'Cancelled. Nothing was run.'
            return
        }
    }
    $folder = $ui.Folder.Text.Trim()
    try {
        if (-not $folder) { throw 'Choose a report folder.' }
        if (-not (Test-Path -LiteralPath $folder)) { $null = [IO.Directory]::CreateDirectory($folder) }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("The report folder cannot be used:`r`n$($_.Exception.Message)", 'Report folder')
        return
    }
    Save-WindowSetting -ReportFolder $folder
    if ($elevate) { $folder = Resolve-NetworkDrivePath -Path $folder }
    $base = Join-Path $folder ('pc-maintenance-{0}-{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:Run = @{ Report = "$base.html"; Log = "$base.log"; Json = "$base.json"; Process = $null; LogLength = -1 }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:ScriptPath
    if ($ui.Check.Checked) { $arguments += ' -Check' }
    if ($selected.Count -gt 0) { $arguments += ' -Task "{0}"' -f ($selected -join ',') }
    if ($ui.DryRun.Checked) { $arguments += ' -DryRun' }
    $arguments += ' -ReportPath "{0}" -LogPath "{1}" -JsonPath "{2}"' -f $script:Run.Report, $script:Run.Log, $script:Run.Json
    $start = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = $arguments; WindowStyle = 'Hidden'; PassThru = $true; ErrorAction = 'Stop' }
    if ($elevate) { $start.Verb = 'RunAs' }
    try {
        $script:Run.Process = Start-Process @start
    } catch {
        $ui.Status.Text = 'Not started.'
        [void][System.Windows.Forms.MessageBox]::Show("Windows did not start the run$(if ($elevate) { ' as administrator (was the permission prompt cancelled?). Untick Run as administrator to run without it' }).`r`n`r`n$($_.Exception.Message)", 'Not started')
        return
    }
    $ui.Results.Items.Clear()
    $ui.Log.Text = ''
    $ui.ReportButton.Enabled = $false
    $ui.Tabs.SelectedIndex = 1
    $ui.Status.Text = 'Running...' + $(if ($selected -contains 'RepairWindows') { ' Do not turn the PC off during the repair.' } else { '' })
    Switch-WindowState -Busy $true
    $script:Timer.Start()
}

function Show-WindowLog {
    $run = $script:Run
    if (-not $run -or -not (Test-Path -LiteralPath $run.Log)) { return }
    try {
        $length = (Get-Item -LiteralPath $run.Log).Length
        if ($length -eq $run.LogLength) { return }
        $run.LogLength = $length
        $text = (Get-Content -LiteralPath $run.Log -Tail 300 -Encoding UTF8 -ErrorAction Stop) -join "`r`n"
        $script:Ui.Log.Text = $text
        $script:Ui.Log.SelectionStart = $text.Length
        $script:Ui.Log.ScrollToCaret()
    } catch {
        # The worker may be writing the log right now; the next tick reads it.
        Write-Verbose "Log not read this time: $($_.Exception.Message)"
    }
}

function Show-WindowResult {
    $ui = $script:Ui
    $colors = @{
        Critical = [System.Drawing.Color]::FromArgb(255, 235, 233); Failed = [System.Drawing.Color]::FromArgb(255, 235, 233)
        Warning = [System.Drawing.Color]::FromArgb(255, 248, 197); Attention = [System.Drawing.Color]::FromArgb(255, 248, 197)
        Info = [System.Drawing.Color]::FromArgb(221, 244, 255); 'Dry run' = [System.Drawing.Color]::FromArgb(221, 244, 255)
        Skipped = [System.Drawing.Color]::FromArgb(240, 242, 245)
    }
    $ui.Results.BeginUpdate()
    $ui.Results.Items.Clear()
    $data = $null
    try {
        $data = Get-Content -LiteralPath $script:Run.Json -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $ui.Results.EndUpdate()
        $ui.Status.Text = 'The run ended without results. See the Log tab.'
        return
    }
    foreach ($f in @(Get-OrderedFinding -Findings @($data.Findings))) {
        $item = New-Object System.Windows.Forms.ListViewItem("$($f.Status)")
        foreach ($text in $f.Area, $f.Finding, $f.Advice) { [void]$item.SubItems.Add("$text") }
        if ($colors.ContainsKey("$($f.Status)")) { $item.BackColor = $colors["$($f.Status)"] }
        [void]$ui.Results.Items.Add($item)
    }
    foreach ($t in @($data.Tasks) | Where-Object { $_ }) {
        $space = if ($null -ne $t.Freed) { " ($(Format-Size $t.Freed))" } else { '' }
        $item = New-Object System.Windows.Forms.ListViewItem("$($t.Status)")
        foreach ($text in "Task: $($t.Title)", ("$($t.Details)" -replace "`n", ' | ') + $space, '') { [void]$item.SubItems.Add("$text") }
        if ($colors.ContainsKey("$($t.Status)")) { $item.BackColor = $colors["$($t.Status)"] }
        [void]$ui.Results.Items.Add($item)
    }
    $ui.Results.EndUpdate()
    $script:SuggestedTasks = @($data.Suggested | Where-Object { $_ })
    $ui.Suggested.Text = if ($script:SuggestedTasks.Count -gt 0) { "Tick suggested tasks ($($script:SuggestedTasks.Count))" } else { 'Tick suggested tasks' }
    $findings = @($data.Findings | Where-Object { $_ })
    $summary = Get-RunSummary -Findings $findings -Tasks @($data.Tasks | Where-Object { $_ }) -Checked ($findings.Count -gt 0)
    $ui.Status.Text = ("$summary The report is ready. Double-click a row to read all of it.").Trim()
    $ui.ReportButton.Enabled = Test-Path -LiteralPath $script:Run.Report
    $ui.Tabs.SelectedIndex = 0
}

function Initialize-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $settings = Get-WindowSetting
    $script:SuggestedTasks = @()
    $script:Run = $null
    $ui = @{ Tasks = @{} }
    $script:Ui = $ui

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PC Maintenance - $env:COMPUTERNAME"
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(940, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 760)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $ui.Form = $form

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'PC Maintenance'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.SetBounds(14, 10, 600, 30)
    $form.Controls.Add($title)

    $model = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '{0} | {1} | {2} | {3}' -f $env:COMPUTERNAME, (Get-ModelName -ComputerSystem $model), "$($os.Caption)".Replace('Microsoft ', ''), $(if ($script:IsAdmin) { 'Running as administrator' } else { 'Not running as administrator' })
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(89, 99, 110)
    $subtitle.SetBounds(16, 42, 900, 20)
    $subtitle.Anchor = 'Top, Left, Right'
    $form.Controls.Add($subtitle)

    $checkGroup = New-Object System.Windows.Forms.GroupBox
    $checkGroup.Text = '1. Check'
    $checkGroup.SetBounds(12, 68, 916, 66)
    $checkGroup.Anchor = 'Top, Left, Right'
    $form.Controls.Add($checkGroup)
    $ui.Check = New-Object System.Windows.Forms.CheckBox
    $ui.Check.Text = 'Check this PC first: disks, memory, processor, startup, crashes, updates, security, battery and network'
    $ui.Check.Checked = $true
    $ui.Check.SetBounds(12, 18, 890, 22)
    $checkGroup.Controls.Add($ui.Check)
    $checkNote = New-Object System.Windows.Forms.Label
    $checkNote.Text = 'Only reads; changes nothing. About 20 seconds. Afterwards, Tick suggested tasks ticks the tasks that fit what it found.'
    $checkNote.ForeColor = [System.Drawing.Color]::FromArgb(89, 99, 110)
    $checkNote.SetBounds(30, 41, 870, 18)
    $checkGroup.Controls.Add($checkNote)

    $taskGroup = New-Object System.Windows.Forms.GroupBox
    $taskGroup.Text = '2. Tasks'
    $taskGroup.SetBounds(12, 140, 916, 238)
    $taskGroup.Anchor = 'Top, Left, Right'
    $form.Controls.Add($taskGroup)
    $tip = New-Object System.Windows.Forms.ToolTip
    $y = 18
    foreach ($definition in $script:TaskCatalog) {
        $box = New-Object System.Windows.Forms.CheckBox
        $box.Text = $definition.Title + $(if ($definition.NeedsAdmin) { '  [admin]' } else { '' })
        $box.SetBounds(12, $y, 300, 24)
        $taskGroup.Controls.Add($box)
        $detail = New-Object System.Windows.Forms.Label
        $detail.Text = $definition.Detail
        $detail.ForeColor = [System.Drawing.Color]::FromArgb(89, 99, 110)
        $detail.SetBounds(316, $y + 4, 590, 20)
        $detail.Anchor = 'Top, Left, Right'
        $taskGroup.Controls.Add($detail)
        $tip.SetToolTip($box, "$($definition.Name): $($definition.Detail)")
        $ui.Tasks[$definition.Name] = $box
        $y += 27
    }

    $ui.DryRun = New-Object System.Windows.Forms.CheckBox
    $ui.DryRun.Text = 'Dry run: the tasks only say what they would do and change nothing'
    $ui.DryRun.SetBounds(16, 386, 600, 22)
    $form.Controls.Add($ui.DryRun)

    $ui.Admin = New-Object System.Windows.Forms.CheckBox
    if ($script:IsAdmin) {
        $ui.Admin.Text = 'Run as administrator (this window already is)'
        $ui.Admin.Checked = $true
        $ui.Admin.Enabled = $false
    } else {
        $ui.Admin.Text = 'Run as administrator (Windows asks for permission; some checks and tasks need it)'
        $ui.Admin.Checked = $true
    }
    $ui.Admin.SetBounds(16, 410, 700, 22)
    $form.Controls.Add($ui.Admin)

    $folderLabel = New-Object System.Windows.Forms.Label
    $folderLabel.Text = 'Report folder:'
    $folderLabel.SetBounds(16, 440, 90, 22)
    $form.Controls.Add($folderLabel)
    $ui.Folder = New-Object System.Windows.Forms.TextBox
    $ui.Folder.Text = $settings.ReportFolder
    $ui.Folder.SetBounds(108, 437, 708, 23)
    $ui.Folder.Anchor = 'Top, Left, Right'
    $form.Controls.Add($ui.Folder)
    $ui.Browse = New-Object System.Windows.Forms.Button
    $ui.Browse.Text = 'Browse...'
    $ui.Browse.SetBounds(824, 435, 104, 27)
    $ui.Browse.Anchor = 'Top, Right'
    $form.Controls.Add($ui.Browse)

    $ui.Run = New-Object System.Windows.Forms.Button
    $ui.Run.Text = 'Run'
    $ui.Run.SetBounds(12, 474, 150, 34)
    $ui.Run.BackColor = [System.Drawing.Color]::FromArgb(9, 105, 218)
    $ui.Run.ForeColor = [System.Drawing.Color]::White
    $ui.Run.FlatStyle = 'Flat'
    $form.Controls.Add($ui.Run)
    $ui.Suggested = New-Object System.Windows.Forms.Button
    $ui.Suggested.Text = 'Tick suggested tasks'
    $ui.Suggested.Enabled = $false
    $ui.Suggested.SetBounds(172, 474, 190, 34)
    $form.Controls.Add($ui.Suggested)
    $ui.ReportButton = New-Object System.Windows.Forms.Button
    $ui.ReportButton.Text = 'Open report'
    $ui.ReportButton.Enabled = $false
    $ui.ReportButton.SetBounds(372, 474, 130, 34)
    $form.Controls.Add($ui.ReportButton)
    $ui.FolderButton = New-Object System.Windows.Forms.Button
    $ui.FolderButton.Text = 'Open folder'
    $ui.FolderButton.SetBounds(512, 474, 130, 34)
    $form.Controls.Add($ui.FolderButton)
    $ui.Progress = New-Object System.Windows.Forms.ProgressBar
    $ui.Progress.SetBounds(708, 482, 220, 18)
    $ui.Progress.Anchor = 'Top, Right'
    $form.Controls.Add($ui.Progress)

    $ui.Status = New-Object System.Windows.Forms.Label
    $ui.Status.Text = 'Tick what to do and click Run.'
    $ui.Status.SetBounds(14, 516, 914, 22)
    $ui.Status.Anchor = 'Top, Left, Right'
    $form.Controls.Add($ui.Status)

    $ui.Tabs = New-Object System.Windows.Forms.TabControl
    $ui.Tabs.SetBounds(12, 542, 916, 226)
    $ui.Tabs.Anchor = 'Top, Bottom, Left, Right'
    $form.Controls.Add($ui.Tabs)
    $resultsPage = New-Object System.Windows.Forms.TabPage
    $resultsPage.Text = 'Results'
    $ui.Tabs.TabPages.Add($resultsPage)
    $ui.Results = New-Object System.Windows.Forms.ListView
    $ui.Results.View = 'Details'
    $ui.Results.FullRowSelect = $true
    $ui.Results.GridLines = $true
    $ui.Results.Dock = 'Fill'
    foreach ($column in @(@('Status', 80), @('Area', 130), @('Finding', 400), @('What to do', 380))) { [void]$ui.Results.Columns.Add($column[0], $column[1]) }
    $resultsPage.Controls.Add($ui.Results)
    $logPage = New-Object System.Windows.Forms.TabPage
    $logPage.Text = 'Log'
    $ui.Tabs.TabPages.Add($logPage)
    $ui.Log = New-Object System.Windows.Forms.TextBox
    $ui.Log.Multiline = $true
    $ui.Log.ReadOnly = $true
    $ui.Log.ScrollBars = 'Both'
    $ui.Log.WordWrap = $false
    $ui.Log.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $ui.Log.BackColor = [System.Drawing.Color]::White
    $ui.Log.Dock = 'Fill'
    $logPage.Controls.Add($ui.Log)

    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 1000
    $script:Timer.Add_Tick({
        Show-WindowLog
        $process = $script:Run.Process
        $finished = $true
        try { $finished = $null -eq $process -or $process.HasExited } catch { $finished = $true }
        if ($finished) {
            $script:Timer.Stop()
            Show-WindowLog
            Show-WindowResult
            Switch-WindowState -Busy $false
        }
    })

    $ui.Run.Add_Click({ Invoke-WorkerRun })
    $ui.Results.Add_DoubleClick({
        $item = $script:Ui.Results.SelectedItems | Select-Object -First 1
        if (-not $item) { return }
        $text = "$($item.SubItems[2].Text)"
        if ($item.SubItems[3].Text) { $text += "`r`n`r`nWhat to do: $($item.SubItems[3].Text)" }
        [void][System.Windows.Forms.MessageBox]::Show($text, "$($item.Text) - $($item.SubItems[1].Text)")
    })
    $ui.Browse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Folder for the reports (a network share works too)'
        if (Test-Path -LiteralPath $script:Ui.Folder.Text) { $dialog.SelectedPath = $script:Ui.Folder.Text }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:Ui.Folder.Text = $dialog.SelectedPath }
    })
    $ui.Suggested.Add_Click({
        foreach ($name in $script:SuggestedTasks) { $script:Ui.Tasks[$name].Checked = $true }
        $titles = ($script:TaskCatalog | Where-Object { $_.Name -in $script:SuggestedTasks } | ForEach-Object { $_.Title }) -join ', '
        $script:Ui.Status.Text = "Ticked: $titles. Click Run to run them."
    })
    $ui.ReportButton.Add_Click({ if ($script:Run -and (Test-Path -LiteralPath $script:Run.Report)) { Start-Process -FilePath $script:Run.Report } })
    $ui.FolderButton.Add_Click({
        $folder = $script:Ui.Folder.Text.Trim()
        if ($folder -and (Test-Path -LiteralPath $folder)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder) }
        else { [void][System.Windows.Forms.MessageBox]::Show('The report folder does not exist yet. It is created on the first run.', 'Report folder') }
    })
    $form.Add_FormClosing({
        # In an event handler, $_ holds the event arguments.
        $closing = $_
        $process = if ($script:Run) { $script:Run.Process } else { $null }
        $running = $false
        try { $running = $null -ne $process -and -not $process.HasExited } catch { $running = $false }
        if ($running) {
            $answer = [System.Windows.Forms.MessageBox]::Show('The run is still going. Closing the window does not stop it, but you will not see the result here. Close anyway?', 'Still running', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $closing.Cancel = $true }
        }
    })
    return $form
}

# --- Main ----------------------------------------------------------------------------------------------

$script:IsAdmin = Test-Administrator

$taskNames = New-Object System.Collections.Generic.List[string]
foreach ($value in @($Task | ForEach-Object { "$_" -split ',' })) {
    $name = $value.Trim()
    if (-not $name) { continue }
    $definition = $script:TaskCatalog | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $definition) {
        Write-Error "Unknown task: $name. Tasks: $(($script:TaskCatalog | ForEach-Object { $_.Name }) -join ', ')."
        exit 2
    }
    if (-not $taskNames.Contains($definition.Name)) { $taskNames.Add($definition.Name) }
}

if (-not $Check -and $taskNames.Count -eq 0) {
    if ($DryRun -or $ReportPath -or $LogPath -or $JsonPath -or $PassThru) {
        Write-Error 'Nothing to do: add -Check, -Task or both.'
        exit 2
    }
    if (-not [Environment]::UserInteractive) {
        Write-Error 'There is no desktop to open the window on. Use -Check or -Task, for example: -Check -Task TempFiles -DryRun.'
        exit 2
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Error 'The window needs a single-threaded PowerShell: start it with powershell.exe -STA -File .\Invoke-PCMaintenance.ps1, or with Start-PCMaintenance.cmd.'
        exit 2
    }
    $form = Initialize-MainWindow
    [void]$form.ShowDialog()
    $script:Timer.Dispose()
    $form.Dispose()
    exit 0
}

# .NET file methods resolve relative paths from the process folder, not from the PowerShell location.
if (-not $ReportPath) { $ReportPath = 'pc-maintenance-{0}-{1}.html' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss') }
$script:ReportFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
$script:LogFile = if ($LogPath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath) } else { [IO.Path]::ChangeExtension($script:ReportFile, '.log') }
if ($JsonPath) { $JsonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath) }
foreach ($file in @($script:ReportFile, $script:LogFile, $JsonPath | Where-Object { $_ })) {
    $folder = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $script:LogFile = $null
        Write-Error "The folder does not exist: $folder"
        exit 2
    }
}

$result = Invoke-Run -TaskNames $taskNames.ToArray()
if ($PassThru) { $result }
$critical = @($result.Findings | Where-Object { $_.Status -eq 'Critical' }).Count
$failed = @($result.Tasks | Where-Object { $_.Status -eq 'Failed' }).Count
if ($critical -gt 0 -or $failed -gt 0) { exit 1 }
exit 0
