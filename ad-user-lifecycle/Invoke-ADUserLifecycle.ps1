<#
.SYNOPSIS
Onboards and offboards Active Directory users from CSV files.

.DESCRIPTION
Onboarding creates each account in its department's OU, adds it to the department's group and gives it
a temporary password that must be changed at first logon. Offboarding disables the account, removes it
from its groups, records when, by whom and why in its description, resets its password to a random value
nobody sees, and moves it to the OU for offboarded accounts.

Every run writes a CSV report with one row per input row. Passwords never appear in it. Use -WhatIf to
see what would change without changing anything. A row that cannot be processed is skipped and reported;
the other rows still run.

.PARAMETER OnboardCsv
CSV with the columns EmployeeId, FirstName, LastName and Department, and optionally Title.

.PARAMETER OffboardCsv
CSV with the column SamAccountName, and optionally Reason.

.PARAMETER InitialPassword
Temporary password for the new accounts. If it is not given, the script asks for it. It is never written
anywhere.

.PARAMETER UsersOu
OU that holds one child OU per department. Default: OU=Users,OU=Lab,<domain>.

.PARAMETER DisabledOu
OU where offboarded accounts are moved. It must already exist. Default: OU=Disabled Users,OU=Lab,<domain>.

.PARAMETER GroupPrefix
Prefix of the department groups: with the default, department Sales uses the group GG-Sales.

.PARAMETER ReportPath
Where to write the CSV report. Default: ad-user-lifecycle-<date>-<time>.csv in the current folder.

.EXAMPLE
.\Invoke-ADUserLifecycle.ps1 -OnboardCsv .\new-hires.csv -WhatIf

.EXAMPLE
.\Invoke-ADUserLifecycle.ps1 -OnboardCsv .\new-hires.csv

.EXAMPLE
.\Invoke-ADUserLifecycle.ps1 -OffboardCsv .\leavers.csv
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Onboard')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Onboard')]
    [string]$OnboardCsv,

    [Parameter(Mandatory, ParameterSetName = 'Offboard')]
    [string]$OffboardCsv,

    [Parameter(ParameterSetName = 'Onboard')]
    [securestring]$InitialPassword,

    [string]$UsersOu,
    [string]$DisabledOu,
    [string]$GroupPrefix = 'GG-',
    [string]$ReportPath = (Join-Path (Get-Location) ('ad-user-lifecycle-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error 'The ActiveDirectory module (RSAT) is required. Run this on a domain controller or a computer with RSAT.'
    exit 1
}

$domain = Get-ADDomain
if (-not $UsersOu) { $UsersOu = "OU=Users,OU=Lab,$($domain.DistinguishedName)" }
if (-not $DisabledOu) { $DisabledOu = "OU=Disabled Users,OU=Lab,$($domain.DistinguishedName)" }
$operator = "$env:USERDOMAIN\$env:USERNAME"
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Action, [string]$Identity, [string]$Name, [string]$Result, [string]$Detail)
    $results.Add([pscustomobject]@{
            Time     = (Get-Date).ToString('s')
            Action   = $Action
            Identity = $Identity
            Name     = $Name
            Result   = $Result
            Detail   = $Detail
        })
}

function Test-ADPath {
    param([string]$DistinguishedName)
    try {
        $null = Get-ADObject -Identity $DistinguishedName -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function ConvertTo-AsciiName {
    # Accented letters lose their accent and anything that is not a plain letter is dropped, so
    # account names stay valid everywhere.
    param([string]$Text)
    $decomposed = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $letters = $decomposed.ToCharArray() | Where-Object { [char]::IsLetter($_) -and [int]$_ -lt 128 }
    return (-join $letters).ToLowerInvariant()
}

function Get-UniqueSamAccountName {
    param([string]$FirstName, [string]$LastName)
    $first = ConvertTo-AsciiName -Text $FirstName
    $last = ConvertTo-AsciiName -Text $LastName
    if (-not $first -or -not $last) { return $null }
    # sAMAccountName allows 20 characters; keep two for the number added when the name is taken.
    $base = ($first.Substring(0, 1) + $last)
    $base = $base.Substring(0, [Math]::Min(18, $base.Length))
    $candidate = $base
    for ($n = 2; Get-ADUser -Filter "SamAccountName -eq '$candidate'"; $n++) { $candidate = "$base$n" }
    return $candidate
}

function Get-RandomPassword {
    # 24 random characters that cycle through the four character classes, so the value meets the usual
    # complexity policies. It is built straight into a SecureString and never shown or stored.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=?@_'
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = New-Object System.Security.SecureString
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $set = $sets[$i % $sets.Count]
        $password.AppendChar($set[$bytes[$i] % $set.Length])
    }
    $password.MakeReadOnly()
    return $password
}

function Import-InputCsv {
    param([string]$Path, [string[]]$Required)
    $rows = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
    if ($rows.Count -gt 0) {
        $missing = @($Required | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ })
        if ($missing.Count -gt 0) { throw "The CSV is missing the column(s): $($missing -join ', ')." }
    }
    return , $rows
}

if ($PSCmdlet.ParameterSetName -eq 'Onboard') {
    try {
        $rows = Import-InputCsv -Path $OnboardCsv -Required 'EmployeeId', 'FirstName', 'LastName', 'Department'
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
    if (-not $InitialPassword -and -not $WhatIfPreference) {
        $InitialPassword = Read-Host -Prompt 'Temporary password for the new accounts' -AsSecureString
    }

    foreach ($row in $rows) {
        $id = "$($row.EmployeeId)".Trim()
        $first = "$($row.FirstName)".Trim()
        $last = "$($row.LastName)".Trim()
        $department = "$($row.Department)".Trim()
        $title = "$($row.Title)".Trim()
        $name = "$first $last".Trim()

        if (-not ($id -and $first -and $last -and $department)) {
            Add-Result -Action 'Onboard' -Identity $id -Name $name -Result 'Skipped' -Detail 'EmployeeId, FirstName, LastName and Department are required.'
            continue
        }
        if ($department -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]*$') {
            Add-Result -Action 'Onboard' -Identity $id -Name $name -Result 'Skipped' -Detail "Department '$department' has characters that cannot go in an OU name."
            continue
        }
        $ou = "OU=$department,$UsersOu"
        $group = "$GroupPrefix$department"
        if (-not (Test-ADPath -DistinguishedName $ou) -or -not (Get-ADGroup -Filter "Name -eq '$group'")) {
            Add-Result -Action 'Onboard' -Identity $id -Name $name -Result 'Skipped' -Detail "Unknown department '$department': $ou or the group $group does not exist."
            continue
        }
        $existing = Get-ADUser -Filter "EmployeeID -eq '$($id.Replace("'", "''"))'"
        if ($existing) {
            Add-Result -Action 'Onboard' -Identity $existing.SamAccountName -Name $name -Result 'Skipped' -Detail "Employee $id already has the account $($existing.SamAccountName)."
            continue
        }
        $sam = Get-UniqueSamAccountName -FirstName $first -LastName $last
        if (-not $sam) {
            Add-Result -Action 'Onboard' -Identity $id -Name $name -Result 'Skipped' -Detail 'The name has no letters that can form an account name.'
            continue
        }

        if ($PSCmdlet.ShouldProcess("$name ($sam)", "Create the account in $ou and add it to $group")) {
            $newUser = @{
                Name                  = $name
                GivenName             = $first
                Surname               = $last
                DisplayName           = $name
                SamAccountName        = $sam
                UserPrincipalName     = "$sam@$($domain.DNSRoot)"
                EmployeeID            = $id
                Department            = $department
                Path                  = $ou
                AccountPassword       = $InitialPassword
                ChangePasswordAtLogon = $true
                Enabled               = $true
                PassThru              = $true
                ErrorAction           = 'Stop'
            }
            if ($title) { $newUser.Title = $title }
            try {
                $user = New-ADUser @newUser
                Add-ADGroupMember -Identity $group -Members $user -ErrorAction Stop
                Add-Result -Action 'Onboard' -Identity $sam -Name $name -Result 'Created' -Detail "In $ou, member of $group; the password must be changed at first logon."
            } catch {
                Add-Result -Action 'Onboard' -Identity $sam -Name $name -Result 'Failed' -Detail $_.Exception.Message
            }
        } else {
            Add-Result -Action 'Onboard' -Identity $sam -Name $name -Result 'Planned' -Detail "Would be created in $ou and added to $group."
        }
    }
} else {
    try {
        $rows = Import-InputCsv -Path $OffboardCsv -Required 'SamAccountName'
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
    if (-not (Test-ADPath -DistinguishedName $DisabledOu)) {
        Write-Error "The OU for offboarded accounts does not exist: $DisabledOu"
        exit 1
    }

    foreach ($row in $rows) {
        $sam = "$($row.SamAccountName)".Trim()
        $reason = "$($row.Reason)".Trim()
        if (-not $sam) {
            Add-Result -Action 'Offboard' -Identity '' -Name '' -Result 'Skipped' -Detail 'SamAccountName is required.'
            continue
        }
        $user = Get-ADUser -Filter "SamAccountName -eq '$($sam.Replace("'", "''"))'" -Properties MemberOf
        if (-not $user) {
            Add-Result -Action 'Offboard' -Identity $sam -Name '' -Result 'Skipped' -Detail 'No account with this name.'
            continue
        }
        if (-not $user.Enabled -and $user.DistinguishedName -like "*,$DisabledOu") {
            Add-Result -Action 'Offboard' -Identity $sam -Name $user.Name -Result 'Skipped' -Detail 'Already offboarded.'
            continue
        }
        $groups = @($user.MemberOf)
        $groupNames = @($groups | ForEach-Object { ($_ -split ',', 2)[0] -replace '^CN=' })
        $groupList = if ($groupNames.Count -gt 0) { $groupNames -join ', ' } else { 'none' }

        if ($PSCmdlet.ShouldProcess("$($user.Name) ($sam)", "Disable, remove from $($groups.Count) group(s) and move to $DisabledOu")) {
            try {
                Disable-ADAccount -Identity $user -Confirm:$false -ErrorAction Stop
                foreach ($group in $groups) { Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false -ErrorAction Stop }
                $note = "Offboarded $(Get-Date -Format 'yyyy-MM-dd') by $operator"
                if ($reason) { $note += ": $reason" }
                Set-ADUser -Identity $user -Description $note -Confirm:$false -ErrorAction Stop
                Set-ADAccountPassword -Identity $user -Reset -NewPassword (Get-RandomPassword) -Confirm:$false -ErrorAction Stop
                Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOu -Confirm:$false -ErrorAction Stop
                Add-Result -Action 'Offboard' -Identity $sam -Name $user.Name -Result 'Offboarded' -Detail "Disabled and moved to $DisabledOu; groups removed: $groupList."
            } catch {
                Add-Result -Action 'Offboard' -Identity $sam -Name $user.Name -Result 'Failed' -Detail $_.Exception.Message
            }
        } else {
            Add-Result -Action 'Offboard' -Identity $sam -Name $user.Name -Result 'Planned' -Detail "Would be disabled and moved to $DisabledOu; groups to remove: $groupList."
        }
    }
}

# The report is written even with -WhatIf: it is the list of what would happen.
# Windows PowerShell 5.1 writes a "#TYPE" line unless told not to. PowerShell 7 never writes it and
# warns that the switch is obsolete.
$csvOptions = @{ LiteralPath = $ReportPath; Encoding = 'UTF8'; WhatIf = $false }
if ($PSVersionTable.PSVersion.Major -lt 6) { $csvOptions.NoTypeInformation = $true }
$results | Export-Csv @csvOptions
$summary = ($results | Group-Object Result | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
Write-Host "$($PSCmdlet.ParameterSetName): $($results.Count) row(s). $summary"
Write-Host "Report: $ReportPath"
$results
if ($results | Where-Object Result -eq 'Failed') { exit 1 }
