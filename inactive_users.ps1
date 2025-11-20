if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit }

Import-Module ActiveDirectory

# Anzahl der Tage ohne Anmeldung
$days = 180
$cutoff = (Get-Date).AddDays(-$days)

# AD-Benutzer abrufen, die sich seit über 180 Tagen NICHT angemeldet haben
$staleUsers = Get-ADUser -Filter * -Properties LastLogonDate |
    Where-Object {
        # Nur Benutzer mit vorhandener letzter Anmeldung
        ($_.LastLogonDate -ne $null) -and ($_.LastLogonDate -lt $cutoff)
    } |
    Select-Object Name, SamAccountName, Enabled, LastLogonDate

# Export als CSV
$staleUsers | Export-Csv -Path "C:\Temp\AD_StaleUsers.csv" -NoTypeInformation -Encoding UTF8

Write-Host "Export abgeschlossen: C:\Temp\AD_StaleUsers.csv"
