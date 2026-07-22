# =====================================================================
# scheduled_account_tasks.ps1
#
# Aktiviert deaktivierte AD-Konten und/oder aendert Gruppenmitglied-
# schaften anhand einer CSV-Aufgabendatei. Gedacht fuer den Einsatz
# ueber die Windows-Aufgabenplanung (z.B. "Neue Mitarbeiter starten
# Montag 06:00 - Konten aktivieren und in Abteilungsgruppen aufnehmen").
#
# CSV-Format (Trennzeichen: Komma, mehrere Gruppen mit ";" trennen):
#
#   SamAccountName,Enable,AddGroups,RemoveGroups,Datum
#   mmustermann,Ja,VPN-Benutzer;Abt-Vertrieb,Praktikanten,2026-07-27
#   jdoe,Nein,Abt-IT,,28.07.2026
#   asmith,Ja,,,
#
# Die Spalte "Datum" ist optional (Formate: yyyy-MM-dd oder dd.MM.yyyy):
#   - Zeilen mit Datum werden erst ab diesem Tag ausgefuehrt; bis dahin
#     bleiben sie in der Aufgabendatei stehen. So reicht EINE zentrale
#     Aufgabendatei plus EINE taegliche geplante Aufgabe, um an
#     verschiedenen Tagen verschiedene Aenderungen auszufuehren.
#   - Zeilen ohne Datum werden beim naechsten Lauf sofort ausgefuehrt.
#   - Abgearbeitete Zeilen werden in eine Archivdatei verschoben,
#     noch nicht faellige Zeilen bleiben erhalten.
#
# Hinweis: KEIN Selbst-Elevation-Block wie in inactive_users.ps1 -
# ein UAC-Prompt wuerde in der Aufgabenplanung haengen bleiben.
# Die Aufgabe stattdessen mit einem berechtigten Konto und der Option
# "Mit hoechsten Privilegien ausfuehren" anlegen.
# =====================================================================

param(
    # Pfad zur CSV-Aufgabendatei
    [string]$TaskFile = "C:\Temp\AD_AccountTasks.csv",

    # Verzeichnis fuer Logdateien
    [string]$LogDir = "C:\Temp",

    # Standard: Aufgabendatei nach dem Lauf archivieren (verhindert
    # versehentliche Doppelausfuehrung beim naechsten geplanten Lauf)
    [switch]$KeepTaskFile
)

Import-Module ActiveDirectory

# --- Logging vorbereiten ---
$runDate = Get-Date
$logTimestamp = $runDate.ToString("yyyy-MM-dd_HH-mm")
$logPath = Join-Path $LogDir "AD_AccountTasks_$logTimestamp.txt"

function Write-Log {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
    $Message | Out-File -FilePath $logPath -Encoding UTF8 -Append
}

"Lauf am $($runDate.ToString('yyyy-MM-dd')) um $($runDate.ToString('HH:mm')):`n" |
    Out-File -FilePath $logPath -Encoding UTF8 -Force

# --- Aufgabendatei einlesen ---
if (!(Test-Path $TaskFile)) {
    Write-Log "FEHLER: Aufgabendatei nicht gefunden: $TaskFile" Red
    exit 1
}

$tasks = Import-Csv -Path $TaskFile -Encoding UTF8

if (-not $tasks) {
    Write-Log "Aufgabendatei ist leer, nichts zu tun: $TaskFile" Yellow
    exit 0
}

$errorCount = 0
$today = $runDate.Date
$remainingRows = @()   # noch nicht faellige Zeilen, bleiben in der Aufgabendatei
$processedRows = @()   # heute abgearbeitete Zeilen, wandern ins Archiv

# --- Aufgaben abarbeiten ---
foreach ($task in $tasks) {

    # --- Faelligkeit pruefen (Spalte "Datum" ist optional) ---
    $dateText = "$($task.Datum)".Trim()
    if ($dateText) {
        $dueDate = [datetime]::MinValue
        $dateValid = $false
        foreach ($format in 'yyyy-MM-dd', 'dd.MM.yyyy') {
            if ([datetime]::TryParseExact($dateText, $format,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$dueDate)) {
                $dateValid = $true
                break
            }
        }
        if (-not $dateValid) {
            Write-Log "FEHLER: Ungueltiges Datum '$dateText' bei '$($task.SamAccountName)' (erwartet yyyy-MM-dd oder dd.MM.yyyy) - Zeile bleibt in der Aufgabendatei." Red
            $errorCount++
            $remainingRows += $task
            continue
        }
        if ($dueDate.Date -gt $today) {
            $remainingRows += $task
            continue
        }
    }
    $processedRows += $task

    $sam = ($task.SamAccountName).Trim()
    if ([string]::IsNullOrWhiteSpace($sam)) { continue }

    try {
        $user = Get-ADUser -Identity $sam -Properties Enabled
    }
    catch {
        Write-Log "FEHLER: Benutzer '$sam' nicht gefunden - Zeile uebersprungen." Red
        $errorCount++
        continue
    }

    # --- Konto aktivieren ---
    if ($task.Enable -match '^(ja|yes|true|1)$') {
        if ($user.Enabled) {
            Write-Log "${sam}: Konto war bereits aktiviert." Gray
        }
        else {
            try {
                Enable-ADAccount -Identity $user
                Write-Log "${sam}: Konto aktiviert." Green
            }
            catch {
                Write-Log "FEHLER: ${sam}: Konto konnte nicht aktiviert werden: $($_.Exception.Message)" Red
                $errorCount++
            }
        }
    }

    # --- Gruppen hinzufuegen ---
    foreach ($group in ($task.AddGroups -split ';')) {
        $group = $group.Trim()
        if ([string]::IsNullOrWhiteSpace($group)) { continue }
        try {
            Add-ADGroupMember -Identity $group -Members $user -ErrorAction Stop
            Write-Log "${sam}: Zur Gruppe '$group' hinzugefuegt." Green
        }
        catch {
            Write-Log "FEHLER: ${sam}: Hinzufuegen zu '$group' fehlgeschlagen: $($_.Exception.Message)" Red
            $errorCount++
        }
    }

    # --- Gruppen entfernen ---
    foreach ($group in ($task.RemoveGroups -split ';')) {
        $group = $group.Trim()
        if ([string]::IsNullOrWhiteSpace($group)) { continue }
        try {
            Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false -ErrorAction Stop
            Write-Log "${sam}: Aus Gruppe '$group' entfernt." Yellow
        }
        catch {
            Write-Log "FEHLER: ${sam}: Entfernen aus '$group' fehlgeschlagen: $($_.Exception.Message)" Red
            $errorCount++
        }
    }
}

# --- Aufgabendatei aktualisieren ---
# Abgearbeitete Zeilen ins Archiv verschieben (verhindert Doppel-
# ausfuehrung), noch nicht faellige Zeilen bleiben in der Aufgabendatei.
if (-not $KeepTaskFile) {
    $baseName = [System.IO.Path]::ChangeExtension($TaskFile, $null).TrimEnd('.')

    if ($processedRows.Count -gt 0) {
        $archivePath = $baseName + "_verarbeitet_$logTimestamp.csv"
        $processedRows | Export-Csv -Path $archivePath -NoTypeInformation -Encoding UTF8
        Write-Log "`n$($processedRows.Count) abgearbeitete Zeile(n) archiviert als: $archivePath" Cyan
    }

    if ($remainingRows.Count -gt 0) {
        $remainingRows | Export-Csv -Path $TaskFile -NoTypeInformation -Encoding UTF8
        Write-Log "$($remainingRows.Count) noch nicht faellige Zeile(n) verbleiben in: $TaskFile" Cyan
    }
    else {
        Remove-Item -Path $TaskFile -Force
        Write-Log "Alle Zeilen abgearbeitet, Aufgabendatei entfernt: $TaskFile" Cyan
    }
}

Write-Log "`nLogdatei erstellt: $logPath" Cyan

if ($errorCount -gt 0) {
    Write-Log "Lauf mit $errorCount Fehler(n) beendet." Red
    exit 1
}

Write-Log "Alle Aufgaben erfolgreich abgearbeitet." Green
exit 0
