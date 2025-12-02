# Collection of Scripts and tools for managing Active Directory
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
