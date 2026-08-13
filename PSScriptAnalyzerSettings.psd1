@{
    # Error und Warning lassen den Lauf scheitern. Information ist fuer
    # dieses Repo ueberwiegend Stilrauschen und wuerde die CI dauerhaft
    # rot faerben, ohne dass jemand etwas davon haette.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Beide Skripte geben bewusst farbige Konsolenmeldungen aus: sie
        # laufen interaktiv oder als geplante Aufgabe, ihre Ausgabe ist
        # fuer Menschen gedacht und wird nicht weiterverarbeitet. Der
        # uebliche Einwand gegen Write-Host - dass es die Pipeline
        # verstopft - trifft hier also nicht zu.
        'PSAvoidUsingWriteHost'
    )
}
