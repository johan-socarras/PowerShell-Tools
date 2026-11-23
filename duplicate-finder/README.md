[← All tools](https://github.com/johan-socarras/PowerShell-Tools#tools)

# Duplicate Finder

A local web app for finding and safely removing duplicate files and folders on Windows, built entirely in PowerShell, with nothing to install.

![Duplicate Finder results: duplicate files and a duplicate backup folder, one copy selected for deletion](screenshot.png)

*Scan results on sample data.*

## What it does

- **Finds duplicate files:** scans the folders, drives or individual files you choose and groups the files with identical content (same size and MD5 hash).
- **Finds whole duplicate folders:** a backup copy of an entire folder tree is reported as one entry instead of one line per file inside it.
- **Lets you choose what to scan:** preset folders (Desktop, Downloads, Documents, Pictures, and more), or Browse to add any folder, drive or individual file. Each selection stays listed before the scan starts.
- **Shows the results by duplicate set:** sortable by space wasted, number of copies or path, and filterable by text or by type (folder or file).
- **Show in Explorer:** jumps to a file or folder's location in File Explorer instead of just copying the path.
- **Deletes only what you check:** check the copies to remove, click delete and confirm. At least one copy of each set must stay unchecked, so you cannot remove every copy.

It runs as a small local web app: a PowerShell HTTP server on localhost, with an interactive page in your browser.

## Requirements

- Windows with PowerShell (tested on Windows PowerShell 5.1 and PowerShell 7).
- No installs, no admin rights needed.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-DuplicateFinder.ps1
```

This opens http://localhost:8791/ in your default browser. Keep the PowerShell window open while you use the page: it is the engine behind it. Close the window, or press Ctrl+C in it, to stop the server.

## Safety notes

- Never deletes permanently: everything goes through the Recycle Bin and can be restored.
- Never opens or downloads OneDrive cloud-only files: they are skipped, and a folder that contains one is never reported as a duplicate folder.
- Nothing is deleted without an explicit checkbox selection and a confirmation click.
- The local server only answers its own page: each run creates a random session token, and requests without it, or from another website, are rejected.

## Tested on

Windows 11, in both Windows PowerShell 5.1 and PowerShell 7: deleting to the Recycle Bin, the rule that one copy of each set must stay, Show in Explorer and removing a selection on a path with an apostrophe, a crafted file name that must not run as script in the page, and requests to the local server without the session token or from another website, which are rejected.
