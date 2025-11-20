# --- Admin-Check ---
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Import-Module ActiveDirectory

# --- Einstellungen ---
$days = 180
$cutoff = (Get-Date).AddDays(-$days)

# Whitelist: SamAccountNames, die niemals deaktiviert werden dürfen
$whitelist = @(
    "Administrator"
)

# --- Benutzer suchen ---
$staleUsers = Get-ADUser -Filter * -Properties LastLogonDate, Enabled |
    Where-Object {
        ($_.Enabled -eq $true) -and
        ($_.LastLogonDate -ne $null) -and
        ($_.LastLogonDate -lt $cutoff) -and
        ($whitelist -notcontains $_.SamAccountName)
    } |
    Select-Object Name, SamAccountName, Enabled, LastLogonDate

# --- Export als CSV ---
# --- Export als CSV ---
$timestamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm")
$csvPath = "C:\Temp\AD_StaleUsers_$timestamp.csv"

$staleUsers | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "Export abgeschlossen: $csvPath" -ForegroundColor Cyan

# --- Automatische Deaktivierung ---
foreach ($user in $staleUsers) {
    Disable-ADAccount -Identity $user.SamAccountName
    Write-Host "Deaktiviert: $($user.SamAccountName)" -ForegroundColor Yellow
}

Write-Host "`nFertig. Alle gefundenen alten Konten (außer Whitelist) wurden deaktiviert." -ForegroundColor Green
