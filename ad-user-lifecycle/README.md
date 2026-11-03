# AD User Lifecycle

Onboards and offboards Active Directory users from CSV files, with a dry run (`-WhatIf`) and a report of every change. Built in PowerShell with the `ActiveDirectory` module.

## What it does

- **Onboarding:** creates each account in its department's OU, adds it to the department's group and sets a temporary password that must be changed at first logon. Account names are the first initial plus the last name (`jrivers`); if a name is taken, a number is added (`jrivers2`).
- **Offboarding:** disables the account, removes it from its groups, writes when, by whom and why in its description, resets its password to a random value nobody sees and moves it to the OU for offboarded accounts. The account is kept, so it can still be audited or restored.
- **Dry run:** `-WhatIf` shows every change without making any.
- **Report:** every run writes a CSV with one row per input row (created, offboarded, planned, skipped or failed) and the reason.
- **Safe to re-run:** an employee who already has an account (matched by `EmployeeId`) or an account that is already offboarded is skipped, not duplicated. A row with a problem is skipped and reported; the other rows still run.

## Requirements

- The `ActiveDirectory` module: run it on a domain controller or on a computer with RSAT.
- Rights to create and change users and group memberships in the OUs it uses.
- Windows PowerShell 5.1, the version that comes with Windows Server.

## Directory layout it expects

One OU per department under a users OU, and one group per department:

```text
OU=Lab
├── OU=Users
│   ├── OU=IT      (group GG-IT)
│   ├── OU=Sales   (group GG-Sales)
│   └── OU=HR      (group GG-HR)
└── OU=Disabled Users   (offboarded accounts)
```

Those are the defaults; `-UsersOu`, `-DisabledOu` and `-GroupPrefix` change them. The OU for offboarded accounts must exist before the first offboarding:

```powershell
New-ADOrganizationalUnit -Name 'Disabled Users' -Path 'OU=Lab,DC=ad,DC=lab'
```

## CSV files

`new-hires.csv` (`Title` is optional):

```text
EmployeeId,FirstName,LastName,Department,Title
T9001,Jordan,Rivers,IT,Help Desk Technician
T9002,Casey,Morgan,Sales,Account Executive
```

`leavers.csv` (`Reason` is optional):

```text
SamAccountName,Reason
cmorgan,Left the company
```

## Usage

```powershell
# See what would happen
.\Invoke-ADUserLifecycle.ps1 -OnboardCsv .\new-hires.csv -WhatIf

# Create the accounts (asks once for the temporary password)
.\Invoke-ADUserLifecycle.ps1 -OnboardCsv .\new-hires.csv

# Offboard
.\Invoke-ADUserLifecycle.ps1 -OffboardCsv .\leavers.csv
```

`Get-Help .\Invoke-ADUserLifecycle.ps1 -Full` describes every parameter.

## Safety notes

- The temporary password is typed once at a hidden prompt, or passed as a `SecureString`, and is never written to disk or to the report.
- Offboarding never deletes an account.
- The script exits with code 1 if any row failed, so a scheduled run can raise an alert.

## Tested on

A Windows Server 2025 domain controller (`ad.lab`) in my home lab, described in [Proxmox-Homelab](https://github.com/johan-socarras/Proxmox-Homelab): dry runs, onboarding of three test users plus a row with an unknown department, a second onboarding that changed nothing, and offboarding, each step checked against the directory.
