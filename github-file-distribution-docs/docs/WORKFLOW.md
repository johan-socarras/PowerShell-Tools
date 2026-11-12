# Workflow

## File Distribution Workflow

```mermaid
flowchart LR
    admin(["Administrator"])
    update[("Update repository<br>public")]
    script["Remote location script<br>Download-Update.ps1"]
    local["Local file<br>updated"]
    reports[("Report repository<br>daily logs")]

    admin -->|"Publishes the file<br>and its checksum"| update
    update -->|"Remote locations<br>download the file"| script
    script -->|"Verifies the checksum,<br>compares local<br>and remote file"| local
    local -->|"Sends status<br>report"| reports
```

## Daily Reporting Workflow

```mermaid
flowchart LR
    run(["Administrator runs<br>Generate-DailyReport.ps1"])
    check["Checks the day's log folder<br>in the report repository"]
    show["Displays missing<br>locations"]

    run -->|"Reads expected<br>locations"| check
    check -->|"Compares expected<br>vs reported"| show
```

## Example Daily Process

1. Publish the new update file and its checksum in the update repository.
2. Wait for all remote locations to run the download script.
3. Run the daily report script.
4. Review missing locations.
5. If all locations reported, the update was successfully distributed.
6. If some locations are missing, check internet access or script execution at those locations.

## When Not All Locations Report

If one or more locations do not report:

- do not delete the current update file yet
- verify internet access at the missing locations
- confirm the scheduled task or script ran correctly
- check whether pending reports exist locally
- run the report again after the missing locations retry

