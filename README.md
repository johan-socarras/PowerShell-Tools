# Software Projects

This repository is a collection of software projects I've built — scripts, desktop tools, and web apps — covering practical automation, small applications, and full projects built end to end.

The goal is to document real, working software: the problem it solves, the approach taken, and the result, rather than isolated code snippets.

## Projects

### [duplicate-finder](duplicate-finder)

A local web app for finding and safely removing duplicate files and folders on Windows, built entirely in PowerShell. Detects byte-identical duplicate files and whole duplicate folders, runs as a small local web server with a browser UI, and only deletes through the Recycle Bin after explicit confirmation. No installs, no external dependencies.

### [github-file-distribution-docs](github-file-distribution-docs)

A PowerShell-based system for distributing a centralized update file from GitHub to multiple remote locations. Each location downloads the file, verifies it against a published SHA-256 checksum, replaces the local copy atomically, and reports its status back to GitHub. Includes a reporting script an administrator can use to confirm which locations completed the update.

## About This Repository

These projects span a range of skills, including:

* Scripting and automation (PowerShell and other tools)
* Desktop application development
* Web application development
* File, data, and reporting automation
* System integration (APIs, local servers, file distribution)
* Task scheduling and unattended execution

Each project includes its own README with the problem it solves, the approach taken, and how to run it.
