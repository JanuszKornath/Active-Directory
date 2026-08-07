# =====================================================================
# scheduled_account_tasks.ps1
#
# Aktiviert deaktivierte AD-Konten und/oder aendert Gruppenmitglied-
# schaften anhand einer CSV-Aufgabendatei. Gedacht fuer den Einsatz
# ueber die Windows-Aufgabenplanung (z.B. "Neue Mitarbeiter starten
# Montag 06:00 - Konten aktivieren und in Abteilungsgruppen aufnehmen").
#
# CSV-Format (Spaltentrenner wird erkannt, mehrere Gruppen mit ";" trennen):
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
# Kodierung und Trennzeichen der Aufgabendatei werden automatisch
# erkannt (UTF-8 mit/ohne BOM, UTF-16, UTF-32; Komma, Semikolon oder
# Tabulator), damit Dateien aus Excel oder einem Editor ohne
# Nachbearbeitung funktionieren.
#
# Das Skript ist wiederholbar: bereits bestehende bzw. bereits fehlende
# Gruppenmitgliedschaften gelten als Erfolg, nicht als Fehler.
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

# --- Kodierung anhand des BOM bestimmen ---
# Excel und Editoren schreiben je nach Sprache und Version UTF-16 oder
# UTF-8 mit bzw. ohne BOM. Eine feste Vorgabe wuerde solche Dateien
# unlesbar machen, ohne dass man ihnen das ansieht.
function Get-CsvEncoding {
    param([string]$Path)

    # .NET arbeitet mit einem eigenen Arbeitsverzeichnis, deshalb muss ein
    # relativ uebergebener Pfad hier aufgeloest werden.
    $Path = (Resolve-Path -LiteralPath $Path).Path

    $bom    = New-Object byte[] 4
    $stream = [System.IO.File]::OpenRead($Path)
    try     { $read = $stream.Read($bom, 0, 4) }
    finally { $stream.Dispose() }

    # UTF-32 LE vor UTF-16 LE pruefen: beide beginnen mit FF FE
    if ($read -ge 4 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE -and $bom[2] -eq 0x00 -and $bom[3] -eq 0x00) { return 'UTF32' }
    if ($read -ge 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF) { return 'UTF8' }
    if ($read -ge 2 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) { return 'Unicode' }
    if ($read -ge 2 -and $bom[0] -eq 0xFE -and $bom[1] -eq 0xFF) { return 'BigEndianUnicode' }

    # Ohne BOM ist UTF-8 der sinnvollste Standard, reines ASCII ist mit abgedeckt
    return 'UTF8'
}

# --- Trennzeichen anhand der Kopfzeile bestimmen ---
# Bewusst nur die Kopfzeile auswerten: in den Datenzeilen trennt ";"
# die Gruppennamen und wuerde die Zaehlung verfaelschen.
function Get-CsvDelimiter {
    param([string]$Path, [string]$Encoding)

    $headerLine = Get-Content -Path $Path -Encoding $Encoding -TotalCount 1
    if (-not $headerLine) { return ',' }

    $comma = ([regex]::Matches($headerLine, ',')).Count
    $semi  = ([regex]::Matches($headerLine, ';')).Count
    $tab   = ([regex]::Matches($headerLine, "`t")).Count

    if ($semi -gt $comma -and $semi -ge $tab) { return ';' }
    if ($tab  -gt $comma -and $tab  -gt $semi) { return "`t" }
    return ','
}

# --- Aufgabendatei einlesen ---
if (!(Test-Path $TaskFile)) {
    Write-Log "FEHLER: Aufgabendatei nicht gefunden: $TaskFile" Red
    exit 1
}

$encodingName   = Get-CsvEncoding -Path $TaskFile
$delimiter      = Get-CsvDelimiter -Path $TaskFile -Encoding $encodingName
$delimiterLabel = if ($delimiter -eq "`t") { 'Tabulator' } else { $delimiter }

Write-Log "Aufgabendatei: $TaskFile (Kodierung: $encodingName, Trennzeichen: '$delimiterLabel')"

$tasks = Import-Csv -Path $TaskFile -Encoding $encodingName -Delimiter $delimiter

if (-not $tasks) {
    Write-Log "Aufgabendatei enthaelt keine Datenzeilen: $TaskFile" Yellow
    Write-Log "Falls das unerwartet ist: Kodierung und Trennzeichen pruefen (siehe Zeile oben)." Yellow
    exit 0
}

# --- Pflichtspalte pruefen ---
# Ohne diese Pruefung wuerde eine falsch getrennte Datei erst spaeter
# mit einem nichtssagenden Null-Referenz-Fehler abbrechen.
$columns = @($tasks)[0].PSObject.Properties.Name
if ($columns -notcontains 'SamAccountName') {
    Write-Log "FEHLER: Spalte 'SamAccountName' fehlt in $TaskFile." Red
    Write-Log "Gefundene Spalten: $($columns -join ', ')" Red
    Write-Log "Haeufigste Ursache: falsches Trennzeichen oder eine fehlerhafte Kopfzeile." Red
    exit 1
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

    $sam = "$($task.SamAccountName)".Trim()
    if ([string]::IsNullOrWhiteSpace($sam)) { continue }

    try {
        $user = Get-ADUser -Identity $sam -Properties Enabled, MemberOf
    }
    catch {
        Write-Log "FEHLER: Benutzer '$sam' nicht gefunden - Zeile uebersprungen." Red
        $errorCount++
        continue
    }

    # Direkte Mitgliedschaften einmal lesen und lokal mitfuehren. Damit
    # laesst sich vorab pruefen, ob eine Aenderung ueberhaupt noetig ist -
    # zuverlaessiger als das Auswerten von Fehlermeldungen, die auf einem
    # deutschsprachigen DC anders lauten als auf einem englischen.
    $memberOf = @($user.MemberOf)

    # --- Konto aktivieren ---
    if ("$($task.Enable)".Trim() -match '^(ja|yes|true|1)$') {
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
    foreach ($group in ("$($task.AddGroups)" -split ';')) {
        $group = $group.Trim()
        if ([string]::IsNullOrWhiteSpace($group)) { continue }
        try {
            $groupObj = Get-ADGroup -Identity $group -ErrorAction Stop
            if ($memberOf -contains $groupObj.DistinguishedName) {
                Write-Log "${sam}: War bereits Mitglied von '$group'." Gray
            }
            else {
                Add-ADGroupMember -Identity $groupObj -Members $user -ErrorAction Stop
                $memberOf += $groupObj.DistinguishedName
                Write-Log "${sam}: Zur Gruppe '$group' hinzugefuegt." Green
            }
        }
        catch {
            Write-Log "FEHLER: ${sam}: Hinzufuegen zu '$group' fehlgeschlagen: $($_.Exception.Message)" Red
            $errorCount++
        }
    }

    # --- Gruppen entfernen ---
    foreach ($group in ("$($task.RemoveGroups)" -split ';')) {
        $group = $group.Trim()
        if ([string]::IsNullOrWhiteSpace($group)) { continue }
        try {
            $groupObj = Get-ADGroup -Identity $group -ErrorAction Stop
            if ($memberOf -notcontains $groupObj.DistinguishedName) {
                Write-Log "${sam}: War kein Mitglied von '$group'." Gray
            }
            else {
                Remove-ADGroupMember -Identity $groupObj -Members $user -Confirm:$false -ErrorAction Stop
                $memberOf = @($memberOf | Where-Object { $_ -ne $groupObj.DistinguishedName })
                Write-Log "${sam}: Aus Gruppe '$group' entfernt." Yellow
            }
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

    # Trennzeichen und Kodierung der Quelldatei beibehalten, damit eine
    # in Excel gepflegte Datei nach dem Lauf unveraendert nutzbar bleibt.
    if ($processedRows.Count -gt 0) {
        $archivePath = $baseName + "_verarbeitet_$logTimestamp.csv"
        $processedRows | Export-Csv -Path $archivePath -NoTypeInformation -Encoding $encodingName -Delimiter $delimiter
        Write-Log "`n$($processedRows.Count) abgearbeitete Zeile(n) archiviert als: $archivePath" Cyan
    }

    if ($remainingRows.Count -gt 0) {
        $remainingRows | Export-Csv -Path $TaskFile -NoTypeInformation -Encoding $encodingName -Delimiter $delimiter
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
