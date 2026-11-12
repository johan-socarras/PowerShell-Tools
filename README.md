<h1 align="center">PowerShell Tools</h1>

<p align="center">
  PowerShell tools for IT support and Windows administration.<br>
  Each tool has its own README with what it does, what it needs and how to run it.
</p>

<p align="center">
  <a href="https://github.com/johan-socarras/PowerShell-Tools/actions/workflows/powershell-checks.yml"><img alt="PowerShell checks" src="https://github.com/johan-socarras/PowerShell-Tools/actions/workflows/powershell-checks.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Runs on Windows PowerShell 5.1 and PowerShell 7" src="https://img.shields.io/badge/runs%20on-Windows%20PowerShell%205.1%20%7C%20PowerShell%207-5391FE">
</p>

| Tool | What it does | Windows PowerShell 5.1 | PowerShell 7 | Tested on |
| --- | --- | :---: | :---: | --- |
| [AD User Lifecycle](ad-user-lifecycle) | Onboards and offboards Active Directory users from CSV files | Yes | Not tested | Windows Server 2025 domain controller in my home lab |
| [Computer Health](computer-health) | Reports low disk space, long uptime, pending restarts and stopped services on a list of computers | Yes | Yes | Home lab domain and Windows 11 Pro |
| [Network Inventory](network-inventory) | Lists every device on a subnet with its vendor and open ports | Yes | Yes | Home lab network and a home network of about 25 devices |
| [GitHub File Distribution](github-file-distribution-docs) | Distributes one update file to many locations and reports who has it | Yes | Yes | End to end against a local stand-in for the GitHub API |
| [Duplicate Finder](duplicate-finder) | Finds duplicate files and folders and removes them through the Recycle Bin | Yes | Yes | Windows 11 |

## Quick start

```powershell
git clone https://github.com/johan-socarras/PowerShell-Tools.git
cd PowerShell-Tools\computer-health
.\Get-ComputerHealth.ps1
```

That checks the computer you are on and writes an HTML report in the current folder. If Windows answers that running scripts is disabled, start it with `powershell -ExecutionPolicy Bypass -File .\Get-ComputerHealth.ps1`. The requirements and examples of each tool are in its folder.

## Tools

### [AD User Lifecycle](ad-user-lifecycle)

Onboards and offboards Active Directory users from CSV files: accounts in the right OU and group with a temporary password, and leavers disabled, removed from their groups and moved aside. Includes a dry run (`-WhatIf`) and a report of every change. Tested on a Windows Server 2025 domain controller in my home lab.

### [Computer Health](computer-health)

Checks a list of Windows computers for low disk space, long uptime, pending restarts and services that should be running, and writes an HTML report with the ones that need attention first. Connects over CIM (WinRM or DCOM) with nothing to install, and exits with an error code for scheduled alerts.

[![Computer Health HTML report with sample data: one unreachable computer, one critical and two warnings listed before the healthy ones](computer-health/screenshot.png)](computer-health)

### [Network Inventory](network-inventory)

Finds every device on a subnet and reports its IP address, host name, MAC address, vendor and open ports as CSV or an HTML report. Fast parallel discovery that also catches devices that block ping, vendor lookup against the IEEE list, and nothing changed on the network.

<p align="center">
  <a href="network-inventory"><img src="network-inventory/screenshot.png" width="640" alt="Network Inventory HTML report with sample data: totals, devices per vendor, open ports and the list of devices"></a>
</p>

### [GitHub File Distribution](github-file-distribution-docs)

A system for distributing one update file from GitHub to many remote locations. Each location downloads the file, verifies it against a published SHA-256 checksum, replaces its local copy atomically, and reports its status to a separate GitHub repository. A second script lets an administrator confirm which locations completed the update.

### [Duplicate Finder](duplicate-finder)

A local web app for finding and safely removing duplicate files and folders on Windows. It finds files with identical content and whole duplicate folders, runs as a small local web server with a browser UI, and only deletes through the Recycle Bin after explicit confirmation.

[![Duplicate Finder results with sample data: duplicate files and a duplicate backup folder, one copy selected for deletion](duplicate-finder/screenshot.png)](duplicate-finder)

## Skills Demonstrated

- PowerShell scripting and automation
- Active Directory user lifecycle with the ActiveDirectory module, with `-WhatIf` support
- Network discovery: ping sweep, ARP table, MAC vendor lookup and TCP port checks
- Remote health checks over CIM (WinRM and DCOM), including registry reads with StdRegProv
- REST APIs (GitHub Contents API) and a local HTTP server
- File integrity checks (SHA-256) and atomic file replacement
- Unattended runs, safe for Windows Task Scheduler
- Operational reporting
- Code checks on every change: syntax in Windows PowerShell 5.1 and PowerShell 7, plus PSScriptAnalyzer, in GitHub Actions

## License

[MIT](LICENSE)
