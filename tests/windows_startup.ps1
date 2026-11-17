param([Parameter(Mandatory)][string]$Application)
$ErrorActionPreference='Stop'
$key='HKCU:\Software\Bonfire'
if (Test-Path -LiteralPath $key) {throw 'This test requires an isolated user without Bonfire preferences.'}
try {
    New-Item -Path $key -Force | Out-Null
    foreach ($language in 'system','zh-Hans','en') {
        $settings=@{Language=$language;AutoCheck=$true} | ConvertTo-Json -Compress
        Set-ItemProperty -LiteralPath $key -Name Preferences -Value $settings
        $process=Start-Process -FilePath $Application -PassThru
        Start-Sleep -Seconds 4
        if($process.HasExited){
            Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddMinutes(-2)} -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'Bonfire|Microsoft.ui.xaml|.NET Runtime' } | Select-Object -ExpandProperty Message
            throw "Startup failed for $language ($($process.ExitCode))"
        }
        $process.CloseMainWindow() | Out-Null
        if(-not $process.WaitForExit(10000)){throw "Graceful shutdown failed for $language"}
        Write-Host "Installed app startup and shutdown passed for $language."
    }
} finally {
    Remove-Item -LiteralPath $key -ErrorAction SilentlyContinue
}

