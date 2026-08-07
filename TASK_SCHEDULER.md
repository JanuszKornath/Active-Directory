# Running these scripts via Windows Task Scheduler

Both scripts in this repository are built for unattended, recurring execution:

| Script | Typical schedule | Purpose |
|---|---|---|
| `inactive_users.ps1` | Weekly or monthly | Find and disable stale accounts |
| `scheduled_account_tasks.ps1` | Daily | Apply prepared account activations and group changes |

This guide walks through setting them up. GUI labels are given in English with the
German equivalent in parentheses, since the Task Scheduler labels differ by system
language.

---

## Step 1 — Place the scripts

Copy the scripts to a fixed folder on the server that will run them, for example
`C:\Scripts\`. Two rules matter here:

- **Do not run them from a user profile, a network share, or a Downloads folder.**
  A scheduled task may run under an account that cannot reach those paths, and
  scripts on a network share are subject to additional trust checks.
- **Restrict write access on the folder.** Anyone who can modify the script can
  execute arbitrary code with the task's AD permissions. `Administrators: Full`,
  `SYSTEM: Full`, `Authenticated Users: Read & Execute` is a reasonable baseline.

Make sure the working directories exist and the task account may write to them —
by default both scripts write to `C:\Temp`.

## Step 2 — Choose the account the task runs as

This is the decision that most often makes the difference between a task that
works and one that silently fails. The task account needs to reach Active
Directory over the network, so it cannot be a purely local account.

**Option A — Group Managed Service Account (gMSA), recommended.** The password is
managed by AD, rotates automatically, and never has to be typed or stored.

```powershell
# Once per domain, on a domain controller:
Add-KdsRootKey -EffectiveImmediately     # usable after ~10 hours

# Create the account and allow the target server to retrieve its password:
New-ADServiceAccount -Name gmsa-adtasks `
    -DNSHostName gmsa-adtasks.contoso.local `
    -PrincipalsAllowedToRetrieveManagedPassword "SRV-ADM01$"

# On the server that will run the task:
Install-ADServiceAccount -Identity gmsa-adtasks
Test-ADServiceAccount    -Identity gmsa-adtasks   # must return True
```

**Option B — a dedicated service account.** An ordinary user account used only for
this task. Simpler to set up, but you must store its password in the task and
rotate it yourself.

In both cases, grant only the permissions the scripts actually need rather than
making the account a Domain Admin. Using the *Delegation of Control* wizard on the
relevant OUs:

- `scheduled_account_tasks.ps1` needs **Read all user information**, the
  **Enable/disable user accounts** permission (write access to
  `userAccountControl`), and **Write Members** on each group it manages.
- `inactive_users.ps1` needs **Read all user information** and the same
  enable/disable permission.

## Step 3 — Create the task (GUI)

Open Task Scheduler (`taskschd.msc`) and choose **Create Task…**
(*Aufgabe erstellen…*) — **not** "Create Basic Task", which does not expose the
settings you need.

**General tab** (*Allgemein*)

1. Give the task a name, e.g. `AD - Account Tasks`.
2. **Change User or Group…** (*Benutzer oder Gruppe ändern…*) — select your gMSA
   or service account. For a gMSA, type `CONTOSO\gmsa-adtasks$` (with the trailing
   `$`) and confirm; the password fields stay empty by design.
3. Select **Run whether user is logged on or not**
   (*Unabhängig von der Benutzeranmeldung ausführen*).
4. Tick **Run with highest privileges** (*Mit höchsten Privilegien ausführen*).
5. Leave **Do not store password** (*Kennwort nicht speichern*) **unticked** —
   see the warning below.
6. Set **Configure for** (*Konfigurieren für*) to your Windows version.

> ⚠️ **The most common failure:** ticking *Do not store password* makes the task
> run without network credentials (S4U logon). Every AD cmdlet then fails with an
> access or server-not-found error, even though the account has the right
> permissions. Either store the password, or use a gMSA — with a gMSA Windows
> retrieves the password itself and the box stays unticked without losing network
> access.

**Triggers tab** (*Trigger*)

For `scheduled_account_tasks.ps1`, create a **Daily** trigger at the time the
changes should take effect, e.g. 06:00. The `Datum` column in the CSV decides
which rows actually run on a given day, so one daily trigger covers different
changes on different days.

For `inactive_users.ps1`, a **Weekly** or **Monthly** trigger outside business
hours is usually the right fit.

If your servers span time zones, tick **Synchronize across time zones**
(*Zeitzonenübergreifend synchronisieren*) so the run time is unambiguous.

**Actions tab** (*Aktionen*)

Create a **Start a program** (*Programm starten*) action:

| Field | Value |
|---|---|
| Program/script (*Programm/Skript*) | `powershell.exe` |
| Add arguments (*Argumente hinzufügen*) | `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\scheduled_account_tasks.ps1"` |
| Start in (*Starten in*) | `C:\Scripts` |

Notes on these values:

- Put the script path **in the arguments field**, not in the program field, and
  quote it — an unquoted path with spaces is the second most common failure.
- `-NoProfile` avoids surprises from a profile script; `-NonInteractive` makes the
  script fail fast instead of waiting forever on an unexpected prompt;
  `-ExecutionPolicy Bypass` applies to this process only and does not change the
  machine policy.
- `-File` must come **last**. Everything after the script path is passed to the
  script, so custom parameters go there:
  `-File "C:\Scripts\scheduled_account_tasks.ps1" -TaskFile "D:\AD\Tasks.csv"`
- Leave *Start in* empty only if you are sure no relative paths are involved.
- Using PowerShell 7 instead of Windows PowerShell 5.1? Use `pwsh.exe` as the
  program.

**Conditions tab** (*Bedingungen*)

Untick **Start the task only if the computer is on AC power**
(*Nur starten, wenn Computer im Netzbetrieb ausgeführt wird*) if the task runs on
a laptop; otherwise the defaults are fine.

**Settings tab** (*Einstellungen*)

| Setting | Recommendation |
|---|---|
| Allow task to be run on demand (*Ausführen der Aufgabe bei Bedarf zulassen*) | On — you need this to test |
| Run task as soon as possible after a scheduled start is missed (*Aufgabe so schnell wie möglich nach einem verpassten Start ausführen*) | On — pairs with the catch-up logic in `scheduled_account_tasks.ps1` |
| Stop the task if it runs longer than (*Aufgabe beenden, falls sie länger ausgeführt wird als*) | 1 hour — the default of 3 days hides a hung run |
| If the task is already running (*Falls die Aufgabe bereits ausgeführt wird*) | **Do not start a new instance** (*Keine neue Instanz starten*) |

## Step 3 (alternative) — Create the task via PowerShell

The same task, scripted. Run this on the target server in an elevated PowerShell
session:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\scheduled_account_tasks.ps1"' `
    -WorkingDirectory 'C:\Scripts'

$trigger = New-ScheduledTaskTrigger -Daily -At '06:00'

# gMSA: no password needed, Windows retrieves it automatically
$principal = New-ScheduledTaskPrincipal -UserId 'CONTOSO\gmsa-adtasks$' `
    -LogonType Password -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'AD - Account Tasks' `
    -Description 'Enables prepared AD accounts and applies group changes' `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

For an ordinary service account instead of a gMSA, replace the `$principal` line
and register with `-User` / `-Password`. Be aware that `Register-ScheduledTask`
takes the password as plain text, which lands in your PowerShell history — for a
one-off setup the GUI is the safer route.

## Step 4 — Test before trusting it

Test in this order, so a mistake shows up while you are watching:

1. **Run the script manually** in a PowerShell window on the server, as yourself.
   Confirms the script and CSV are valid.
2. **Run it as the task account.** This is the step that catches permission
   problems. With a stored-password service account:
   `Start-Process powershell.exe -Credential (Get-Credential CONTOSO\svc-adtasks)`
3. **Run the task on demand.** Right-click the task → **Run** (*Ausführen*), then
   check **Last Run Result** (*Letztes Ausführungsergebnis*).
4. **Check the log file** the script wrote to `C:\Temp` — it lists every account
   and group it touched, and every error it hit.

For a safe dry run of `scheduled_account_tasks.ps1`, point it at a CSV containing
a single test user and pass `-KeepTaskFile` so the task file is left untouched.

Task history is disabled by default. Turn it on via **Enable All Tasks History**
(*Verlauf für alle Aufgaben aktivieren*) in the right-hand pane — without it,
troubleshooting a failed run is guesswork.

## Reading the result codes

Both scripts exit with `0` on success and `1` when at least one error was logged,
so a failed run is visible in Task Scheduler without opening the log.

| Last Run Result | Meaning |
|---|---|
| `0x0` | Success — all rows processed without errors |
| `0x1` | The script logged at least one error, or the task file was missing. Read the log in `C:\Temp` |
| `0x41300` | Task is ready, has not run yet |
| `0x41301` | Task is currently running |
| `0x41303` | Task has never run |
| `0x41306` | Task was terminated by a user or by the time limit |
| `0x8007010B` | Invalid *Start in* directory |
| `0x80070002` | File not found — usually a wrong or unquoted script path |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Works manually, fails as a task with AD access errors | *Do not store password* is ticked, so the task has no network credentials. Untick it and store the password, or switch to a gMSA |
| `The term 'Get-ADUser' is not recognized` | The ActiveDirectory module is missing on that server. Install RSAT: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`, or on a server `Install-WindowsFeature RSAT-AD-PowerShell` |
| Result `0x1`, log says "Aufgabendatei nicht gefunden" | The CSV was already fully processed and removed, or `-TaskFile` points somewhere else. Expected if there was nothing scheduled |
| Task returns `0x0` but nothing happened | All rows carry a future date — correct behaviour. The log states how many rows remain pending |
| Umlauts appear garbled in the CSV | Save the file as UTF-8. Excel's "CSV UTF-8 (comma delimited)" export produces the right format |
| Excel writes semicolons instead of commas | On a German locale Excel uses `;` as the list separator. Save via "CSV UTF-8 (comma delimited)", or edit the file in a text editor |
| Nothing runs, no history | Task history is off, or the trigger is disabled. Enable history and check the **Next Run Time** (*Nächste Laufzeit*) column |

## Note on `inactive_users.ps1`

That script contains a self-elevation block that relaunches itself via
`Start-Process -Verb RunAs` when not started as administrator. In an interactive
session that is convenient; in a scheduled task it is not needed, because
*Run with highest privileges* already provides elevation. Configure the task as
described above and the block is simply skipped.

`scheduled_account_tasks.ps1` deliberately has no such block: a UAC prompt in an
unattended task would wait forever and the task would run into its time limit.
