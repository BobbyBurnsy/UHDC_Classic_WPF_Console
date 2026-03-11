# Compile-UHDC.ps1
# Compiles the UHDC.ps1 script into a standalone executable using ps2exe.

# --- Auto-Elevate to Administrator ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Write-Host "--- ADMIN WINDOW ACTIVE ---" -ForegroundColor Cyan
Write-Host "Working Directory: $PSScriptRoot"

try {
    Set-Location $PSScriptRoot

    $SourceFile = "UHDC.ps1"
    $OutputFile = "UHDC.exe"
    $IconFile   = "UHDC.ico"

    if (-not (Get-Command ps2exe -ErrorAction SilentlyContinue)) {
        Write-Host "Installing ps2exe module..." -ForegroundColor Cyan
        Install-Module ps2exe -Scope CurrentUser -Force
    }

    Write-Host "[>] Starting Compilation..." -ForegroundColor White

    ps2exe -inputFile $SourceFile -outputFile $OutputFile -iconFile $IconFile -noConsole -requireAdmin

    Write-Host "`n[SUCCESS] Build Finished!" -ForegroundColor Green
}
catch {
    Write-Host "`n[!] ERROR DETECTED:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor White -BackgroundColor Red
}

Write-Host "`nBUILD PROCESS COMPLETE. Press ENTER to close this window." -ForegroundColor Gray
Read-Host
