# PowerShell Tools

[![PowerShell checks](https://github.com/johan-socarras/PowerShell-Tools/actions/workflows/powershell-checks.yml/badge.svg)](https://github.com/johan-socarras/PowerShell-Tools/actions/workflows/powershell-checks.yml)

PowerShell tools for IT support and Windows administration. Each tool has its own README with what it does, what it needs and how to run it.

## Tools

### [duplicate-finder](duplicate-finder)

A local web app for finding and safely removing duplicate files and folders on Windows. It finds files with identical content and whole duplicate folders, runs as a small local web server with a browser UI, and only deletes through the Recycle Bin after explicit confirmation.

### [ad-user-lifecycle](ad-user-lifecycle)

Onboards and offboards Active Directory users from CSV files: accounts in the right OU and group with a temporary password, and leavers disabled, removed from their groups and moved aside. Includes a dry run (`-WhatIf`) and a report of every change. Tested on a Windows Server 2025 domain controller in my home lab.

### [network-inventory](network-inventory)

Finds every device on a subnet and reports its IP address, host name, MAC address, vendor and open ports as CSV or an HTML report. Fast parallel discovery that also catches devices that block ping, vendor lookup against the IEEE list, and nothing changed on the network.

### [computer-health](computer-health)

Checks a list of Windows computers for low disk space, long uptime, pending restarts and services that should be running, and writes an HTML report with the ones that need attention first. Connects over CIM (WinRM or DCOM) with nothing to install, and exits with an error code for scheduled alerts.

### [github-file-distribution-docs](github-file-distribution-docs)

A system for distributing one update file from GitHub to many remote locations. Each location downloads the file, verifies it against a published SHA-256 checksum, replaces its local copy atomically, and reports its status to a separate GitHub repository. A second script lets an administrator confirm which locations completed the update.

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
