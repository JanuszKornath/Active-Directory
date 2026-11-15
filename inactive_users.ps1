# --- Admin-Check ---
# Fuer die AD-Aenderungen selbst genuegen delegierte Rechte auf den OUs,
# eine Mitgliedschaft in "Administratoren" ist dafuer nicht noetig. Erhoehte
# Rechte braucht nur, wer selbst Administrator ist und das Skript in einer
# nicht erhoehten Konsole startet: dann filtert UAC das Token, und die
# Aenderungen werden verweigert.
#
# Deshalb wird nur in genau diesem Fall neu gestartet. Als geplante Aufgabe
# (keine interaktive Sitzung) und unter einem delegierten Konto laeuft das
# Skript ohne Umweg weiter - eine UAC-Abfrage koennte dort niemand
# bestaetigen. Fehlende Rechte zeigen sich dann weiter unten als Fehler und
# im Exit-Code.
$identity   = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isElevated -and [Environment]::UserInteractive) {
    # Im gefilterten Token steht die Gruppe "Administratoren" (S-1-5-32-544)
    # weiterhin, nur als "deny only". Bei einem Konto ohne Adminrechte fehlt
    # sie ganz. Die SID ist anders als der Gruppenname sprachunabhaengig.
    $isFilteredAdmin = [bool](& whoami.exe /groups /fo csv /nh 2>$null | Select-String -SimpleMatch 'S-1-5-32-544')

    if ($isFilteredAdmin) {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }
}

# --- Einstellungen ---
$days = 180
$cutoff = (Get-Date).AddDays(-$days)

# Whitelist: SamAccountNames, die niemals deaktiviert werden duerfen
$whitelist = @(
    "Administrator"
)

$runDate   = Get-Date
$timestamp = $runDate.ToString("yyyy-MM-dd_HH-mm")
$csvPath   = "C:\Temp\AD_StaleUsers_$timestamp.csv"
$logPath   = "C:\Temp\AD_StaleUsers_Deaktivierung_$timestamp.txt"

# Liefert die Organisationseinheiten eines Distinguished Name von aussen
# nach innen, z. B. "HQ / Users / IT". Getrennt wird nur an nicht maskierten
# Kommas, damit ein CN wie "Mustermann\, Max" die Aufteilung nicht stoert.
# Liegt das Konto in keiner OU (etwa im Container "Users"), wird ersatzweise
# der Container genannt.
function Get-OuLabel {
    param([string]$DistinguishedName)

    $parents = @($DistinguishedName -split '(?<!\\),' | Select-Object -Skip 1)

    $parts = @($parents | Where-Object { $_ -match '^OU=' } | ForEach-Object { $_ -replace '^OU=', '' })
    if ($parts.Count -eq 0) {
        $parts = @($parents | Where-Object { $_ -match '^CN=' } | ForEach-Object { $_ -replace '^CN=', '' })
    }

    [array]::Reverse($parts)
    return ($parts -join ' / ')
}

# --- Benutzer suchen ---
# Schlaegt schon die Abfrage fehl (Modul fehlt, DC nicht erreichbar, keine
# Leserechte), darf der Lauf nicht als Erfolg mit null Treffern enden.
try {
    Import-Module ActiveDirectory -ErrorAction Stop

    $staleUsers = @(Get-ADUser -Filter * -Properties LastLogonDate, Enabled, DistinguishedName -ErrorAction Stop |
        Where-Object {
            ($_.Enabled -eq $true) -and
            ($null -ne $_.LastLogonDate) -and
            ($_.LastLogonDate -lt $cutoff) -and
            ($whitelist -notcontains $_.SamAccountName)
        } |
        Select-Object Name, SamAccountName, Enabled, LastLogonDate, DistinguishedName)
}
catch {
    $message = "FEHLER: Active Directory konnte nicht abgefragt werden: $($_.Exception.Message)"
    Write-Host $message -ForegroundColor Red
    $message | Out-File -FilePath $logPath -Encoding UTF8 -Force
    exit 1
}

# --- CSV-Export mit Timestamp ---
$staleUsers | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "Export abgeschlossen: $csvPath" -ForegroundColor Cyan

# --- Automatische Deaktivierung ---
# Jedes Konto einzeln absichern: ein Fehler bei einem Konto soll die
# uebrigen nicht aufhalten, muss aber im Log und im Exit-Code ankommen.
$disabledUsers = @()
$failedUsers   = @()

foreach ($user in $staleUsers) {
    try {
        Disable-ADAccount -Identity $user.SamAccountName -ErrorAction Stop
        $disabledUsers += $user
        Write-Host "Deaktiviert: $($user.SamAccountName)" -ForegroundColor Yellow
    }
    catch {
        $failedUsers += [pscustomobject]@{
            User   = $user
            Reason = $_.Exception.Message
        }
        Write-Host "FEHLER: $($user.SamAccountName) konnte nicht deaktiviert werden: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Logdatei erstellen ---
# Kopfzeile
"Am $($runDate.ToString('yyyy-MM-dd')) um $($runDate.ToString('HH:mm')) wurden folgende Konten deaktiviert:`n" | Out-File -FilePath $logPath -Encoding UTF8 -Force

foreach ($user in $disabledUsers) {
    $ou = Get-OuLabel -DistinguishedName $user.DistinguishedName
    $lastLogon = $user.LastLogonDate.ToString("yyyy-MM-dd HH:mm")
    $line = "$($user.Name), angelegt als $($user.SamAccountName) in der Organisationseinheit $ou, weil seit $lastLogon nicht mehr angemeldet."
    $line | Out-File -FilePath $logPath -Encoding UTF8 -Append
}

if ($failedUsers.Count -gt 0) {
    "`nFolgende Konten konnten NICHT deaktiviert werden:`n" | Out-File -FilePath $logPath -Encoding UTF8 -Append

    foreach ($failed in $failedUsers) {
        $ou = Get-OuLabel -DistinguishedName $failed.User.DistinguishedName
        $line = "FEHLER: $($failed.User.Name), angelegt als $($failed.User.SamAccountName) in der Organisationseinheit ${ou}: $($failed.Reason)"
        $line | Out-File -FilePath $logPath -Encoding UTF8 -Append
    }
}

Write-Host "Logdatei erstellt: $logPath" -ForegroundColor Cyan

if ($failedUsers.Count -gt 0) {
    Write-Host "`n$($disabledUsers.Count) Konto/Konten deaktiviert, $($failedUsers.Count) Fehler." -ForegroundColor Red
    exit 1
}

Write-Host "`nAlle gefundenen alten Konten (ausser Whitelist) wurden deaktiviert." -ForegroundColor Green
exit 0
