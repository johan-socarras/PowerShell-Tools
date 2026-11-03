# PowerShell Tools

PowerShell tools for IT support and Windows administration. Each tool has its own README with what it does and how to run it, and runs on Windows with no installs or external dependencies.

## Tools

### [duplicate-finder](duplicate-finder)

A local web app for finding and safely removing duplicate files and folders on Windows. It finds files with identical content and whole duplicate folders, runs as a small local web server with a browser UI, and only deletes through the Recycle Bin after explicit confirmation.

### [github-file-distribution-docs](github-file-distribution-docs)

A system for distributing one update file from GitHub to many remote locations. Each location downloads the file, verifies it against a published SHA-256 checksum, replaces its local copy atomically, and reports its status to a separate GitHub repository. A second script lets an administrator confirm which locations completed the update.

## Skills Demonstrated

- PowerShell scripting and automation
- REST APIs (GitHub Contents API) and a local HTTP server
- File integrity checks (SHA-256) and atomic file replacement
- Unattended runs, safe for Windows Task Scheduler
- Operational reporting

## License

[MIT](LICENSE)
