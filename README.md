# Collection of Scripts and tools for managing Active Directory environments

Both scripts are designed for unattended, recurring execution. See
**[TASK_SCHEDULER.md](TASK_SCHEDULER.md)** for a step-by-step guide to setting
them up in the Windows Task Scheduler, including account and permission choices,
result codes, and troubleshooting.

## inactive_users.ps1

This PowerShell script scans an Active Directory domain for user accounts that have not logged in for more than 180 days, exports the results to a CSV file, and automatically disables all identified accounts (excluding those explicitly added to a whitelist).
Accounts that have never logged on (no `LastLogonDate`) are skipped, so freshly created accounts are not disabled before their first use.

Additionally, the script generates a detailed log file containing:

- Script execution date and time
- All accounts that were actually disabled
- The full OU path of each user
- Their last logon timestamp
- A separate list of accounts that could not be disabled, with the reason

This makes the script ideal for automatic recurring cleanup operations, such as running it via Windows Task Scheduler.

### Features:
- Detects inactive AD user accounts
- Configurable inactivity threshold (default: 180 days)
- Whitelist to protect important accounts
- CSV export with timestamp
- Automatic account disabling
- Detailed log file with OU information
- Clean, human-readable OU path formatting
- Self-elevation when an administrator starts it in a non-elevated console; no admin membership required otherwise (see below)
- Per-account error handling: one failure does not stop the run
- Exit code 1 on errors, so Task Scheduler reports failed runs
- Fully Task Scheduler compatible

### Output Files

The script generates two files per execution:

1. CSV File

    Example:
    ```
    C:\Temp\AD_StaleUsers_2025-02-14_10-33.csv
    ```
    
    Includes:
    - Name (the account's common name, CN)
    - SamAccountName
    - Enabled status
    - LastLogonDate
    - DistinguishedName (full OU path)

2. Log File

    Example:
    ```
    C:\Temp\AD_StaleUsers_Deaktivierung_2025-02-14_10-33.txt
    ```
    
    The log is written in German. Contents sample:
    ```
    Am 2025-02-14 um 10:33 wurden folgende Konten deaktiviert:
    
    Max Mustermann, angelegt als mmustermann in der Organisationseinheit HQ / Users / IT, weil seit 2024-01-01 09:12 nicht mehr angemeldet.
    ```

    Only accounts that were actually disabled appear in this list. If disabling an
    account fails, the run continues with the next one, and the failed accounts are
    listed in a separate section (`Folgende Konten konnten NICHT deaktiviert werden:`)
    together with the error message.

### Exit codes and elevation

The script exits with `0` when every account found was disabled, and with `1` when
Active Directory could not be queried or at least one account could not be disabled.

Being a member of `Administrators` is not required: delegated rights on the relevant
OUs are enough. The script relaunches itself with a UAC prompt in exactly one case —
an administrator starts it interactively in a non-elevated console, where UAC would
otherwise filter the token and the changes would be refused. As a scheduled task, or
under a delegated non-admin account, it runs straight through without prompting.

### Requirements:
- Windows Server or Windows 10+
- RSAT / ActiveDirectory PowerShell module
- Sufficient AD permissions: read access to user accounts and the right to enable/disable them on the relevant OUs (delegated rights are enough, Domain Admin is not needed)
- PowerShell 5.1 or PowerShell 7
- Write access to `C:\Temp`

## scheduled_account_tasks.ps1

This PowerShell script is the counterpart to `inactive_users.ps1`: instead of disabling accounts, it enables disabled user accounts and/or changes group memberships based on a CSV task file. It is designed to be run at a specific time via Windows Task Scheduler — for example: "New employees start Monday at 06:00 — enable their accounts and add them to their department groups."

### How it works

You prepare a CSV task file (default: `C:\Temp\AD_AccountTasks.csv`) ahead of time, then schedule the script to run daily — each row is executed on its scheduled date:

```
SamAccountName,Enable,AddGroups,RemoveGroups,Datum
mmustermann,Ja,VPN-Benutzer;Abt-Vertrieb,Praktikanten,2026-07-27
jdoe,Nein,Abt-IT,,28.07.2026
asmith,Ja,,,
```

- **SamAccountName** — the user to process
- **Enable** — `Ja`/`Yes`/`true`/`1` enables the account; anything else leaves it untouched
- **AddGroups** — groups to add the user to (separate multiple groups with `;`)
- **RemoveGroups** — groups to remove the user from (separate multiple groups with `;`)
- **Datum** — optional execution date (`yyyy-MM-dd` or `dd.MM.yyyy`). Rows with a date are only executed once that day has arrived; until then they stay in the task file untouched. Rows without a date are executed on the next run. This way a single central task file plus one daily scheduled task covers different changes on different days of the week — just keep adding rows with the appropriate dates.

After each run, processed rows are moved to an archive file (`AD_AccountTasks_verarbeitet_<timestamp>.csv`) so they are never accidentally executed twice, while not-yet-due rows remain in the task file for future runs. `-KeepTaskFile` disables the archiving and leaves the task file as it is — the account and group changes are still carried out, so the same rows run again on the next run. If a row's date lies in the past but the row is still in the task file (e.g., the server was off that day), it is caught up on the next run.

Once every row has been processed, the task file itself stays in place with just its header line, so the next batch of changes can simply be appended — no need to recreate and reformat the file each time. The header is written back exactly as it was found, keeping the original column names, encoding and separator. A run that finds only the header line and no data rows logs `Keine offenen Aufgaben` and exits with code 0; a run where rows exist but none is due yet also exits with 0 and logs how many rows remain. If you prefer the file to be deleted when it runs empty, pass `-RemoveEmptyTaskFile`.

### File format tolerance

The task file does not have to be in one exact format. Encoding is detected from the byte order mark (UTF-8 with or without BOM, UTF-16 LE/BE, UTF-32 LE) and the column separator is detected from the header line (comma, semicolon or tab). This matters in practice because a German Excel writes semicolon-separated files, and PowerShell's own `Out-File` and `>` default to UTF-16 — both of which would otherwise be silently unreadable.

Both are written to the log on every run, and the file is rewritten with the same encoding and separator, so a file maintained in Excel stays usable afterwards. Two details do change: under Windows PowerShell 5.1 a UTF-8 file without BOM gets a BOM when it is written back, and remaining rows are written with every field in double quotes. If the `SamAccountName` column is missing, the script names the columns it did find and stops, rather than failing later with an unhelpful error.

### Repeatable runs

Group changes are applied only where they are actually needed: the script reads each user's current memberships first, so a group the user already belongs to (or already does not belong to) is logged as such instead of counting as an error. Re-running the same task file therefore ends with exit code 0 rather than reporting failures for work that was already done.

This check is done by comparing distinguished names rather than by inspecting error messages, which differ by domain controller language.

### Features:
- Enables disabled AD user accounts
- Adds and removes group memberships
- CSV-driven — prepare changes ahead of time, execute them on schedule
- Per-row execution date: one central task file, one daily scheduled task, different changes on different days
- Catch-up for missed dates (e.g., after server downtime)
- Automatic detection of file encoding and column separator
- Repeatable: existing or already-absent group memberships count as success, not as errors
- Per-row error handling: one bad entry does not stop the run
- Detailed log file per execution
- Processed rows are archived to prevent double execution
- The task file survives an empty run: its header line stays, ready for the next batch
- Exit code 1 on errors, so Task Scheduler reports failed runs
- Fully Task Scheduler compatible

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-TaskFile` | `C:\Temp\AD_AccountTasks.csv` | Path to the CSV task file |
| `-LogDir` | `C:\Temp` | Directory for log files |
| `-KeepTaskFile` | off | Do not archive processed rows and do not rewrite the task file. **Not a dry run:** all changes are still applied |
| `-RemoveEmptyTaskFile` | off | Delete the task file once all rows have been processed, instead of keeping its header line |

### Task Scheduler setup

This script intentionally never self-elevates — a UAC prompt would hang forever in an unattended scheduled task. (`inactive_users.ps1` only does so in an interactive session.) Instead, configure the task itself:

1. Run the task under an account with sufficient AD permissions
2. Enable "Run with highest privileges"
3. Action: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\scheduled_account_tasks.ps1"`
4. Trigger: daily at the time the changes should take effect (e.g., 06:00) — the `Datum` column decides which rows run on which day

The full walkthrough — choosing the task account, gMSA setup, delegating minimal AD permissions, testing, result codes and troubleshooting — is in **[TASK_SCHEDULER.md](TASK_SCHEDULER.md)**.

### Requirements:
- Windows Server or Windows 10+
- RSAT / ActiveDirectory PowerShell module
- Sufficient AD permissions (e.g., Account Operator or delegated rights)
- PowerShell 5.1 or PowerShell 7

---

## Continuous integration

Every push to `main` and every pull request runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml) on a Windows runner; the workflow can also be started manually (`workflow_dispatch`):

- **Syntax check** — every `.ps1` file is parsed with `[System.Management.Automation.Language.Parser]`. This catches a broken script before it reaches a domain controller, where the next scheduled run would be the first thing to notice.
- **PSScriptAnalyzer** — linting, configured through [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1). Findings of severity Error or Warning fail the run, Information-level findings are ignored. `PSAvoidUsingWriteHost` is excluded on purpose: both scripts write coloured status output meant for a human reading the console or the log.

The workflow deliberately uses `powershell` (Windows PowerShell 5.1) rather than `pwsh` (7), because that is what the scheduled task invokes — and the two differ in exactly the area these scripts care about, encoding defaults.

What CI cannot do here: run the scripts against Active Directory. GitHub-hosted runners have no RSAT and no `ActiveDirectory` module, so any change to the AD logic itself still needs a manual run against a test domain.
