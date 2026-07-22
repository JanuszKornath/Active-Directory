# Collection of Scripts and tools for managing Active Directory environments
## inactive_users.ps1

This PowerShell script scans an Active Directory domain for user accounts that have not logged in for more than 180 days, exports the results to a CSV file, and automatically disables all identified accounts (excluding those explicitly added to a whitelist).
Additionally, the script generates a detailed log file containing:

- Script execution date and time
- All disabled user accounts
- The full OU path of each user
- Their last logon timestamp

This makes the script ideal for automatic recurring cleanup operations, such as running it via Windows Task Scheduler.

### Features:
- Detects inactive AD user accounts
- Configurable inactivity threshold (default: 180 days)
- Whitelist to protect important accounts
- CSV export with timestamp
- Automatic account disabling
- Detailed log file with OU information
- Clean, human-readable OU path formatting
- Automatic self-elevation to Administrator
- Fully Task Scheduler compatible

### Output Files

The script generates two files per execution:

1. CSV File

    Example:
    ```
    C:\Temp\AD_StaleUsers_2025-02-14_10-33.csv
    ```
    
    Includes:
    - Display Name
    - SamAccountName
    - Enabled status
    - LastLogonDate
    - DistinguishedName (full OU path)

2. Log File

    Example:
    ```
    C:\Temp\AD_StaleUsers_Deactivation_2025-02-14_10-33.txt
    ```
    
    Contents sample:
    ```
    On 2025-02-14 at 10:33 the following accounts were disabled:
    
    Max Mustermann, with username mmustermann in organizational unit HQ / Users / IT, because the user has not logged in since 2024-01-01 09:12.
    ```
### Requirements:
- Windows Server or Windows 10+
- RSAT / ActiveDirectory PowerShell module
- Sufficient AD permissions (e.g., Domain Admin)
- PowerShell 5.1 or PowerShell 7
- Access to the AD OU structure

## scheduled_account_tasks.ps1

This PowerShell script is the counterpart to `inactive_users.ps1`: instead of disabling accounts, it enables disabled user accounts and/or changes group memberships based on a CSV task file. It is designed to be run at a specific time via Windows Task Scheduler — for example: "New employees start Monday at 06:00 — enable their accounts and add them to their department groups."

### How it works

You prepare a CSV task file (default: `C:\Temp\AD_AccountTasks.csv`) ahead of time, then schedule the script to run whenever the changes should take effect:

```
SamAccountName,Enable,AddGroups,RemoveGroups
mmustermann,Ja,VPN-Benutzer;Abt-Vertrieb,Praktikanten
jdoe,Nein,Abt-IT,
```

- **SamAccountName** — the user to process
- **Enable** — `Ja`/`Yes`/`true`/`1` enables the account; anything else leaves it untouched
- **AddGroups** — groups to add the user to (separate multiple groups with `;`)
- **RemoveGroups** — groups to remove the user from (separate multiple groups with `;`)

After a successful run the task file is renamed to `AD_AccountTasks_verarbeitet_<timestamp>.csv`, so the same tasks are never accidentally executed twice by the next scheduled run (use `-KeepTaskFile` to disable this).

### Features:
- Enables disabled AD user accounts
- Adds and removes group memberships
- CSV-driven — prepare changes ahead of time, execute them on schedule
- Per-row error handling: one bad entry does not stop the run
- Detailed log file per execution
- Task file archiving to prevent double execution
- Exit code 1 on errors, so Task Scheduler reports failed runs
- Fully Task Scheduler compatible

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-TaskFile` | `C:\Temp\AD_AccountTasks.csv` | Path to the CSV task file |
| `-LogDir` | `C:\Temp` | Directory for log files |
| `-KeepTaskFile` | off | Do not archive the task file after the run |

### Task Scheduler setup

Unlike `inactive_users.ps1`, this script intentionally does **not** self-elevate — a UAC prompt would hang forever in an unattended scheduled task. Instead, configure the task itself:

1. Run the task under an account with sufficient AD permissions
2. Enable "Run with highest privileges"
3. Action: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\scheduled_account_tasks.ps1"`
4. Trigger: the date/time the changes should take effect

### Requirements:
- Windows Server or Windows 10+
- RSAT / ActiveDirectory PowerShell module
- Sufficient AD permissions (e.g., Account Operator or delegated rights)
- PowerShell 5.1 or PowerShell 7
