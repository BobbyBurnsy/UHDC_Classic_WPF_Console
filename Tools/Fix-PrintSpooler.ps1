# Fix-PrintSpooler.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely stops the Print Spooler service, forcibly deletes any
# stuck files in the spool\PRINTERS directory, and then restarts the service.
# Features an automated PsExec fallback if WinRM is blocked by the firewall.
# Optimized for PS 5.1 (.NET Ping, WPF Training Mode Fix, & PsExec Fallback).

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# --- TRAINING MODE HELPER (WPF Safe) ---
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

        # Pause the script until the GUI user clicks Execute or Abort
        while (-not $SyncHash.StepAck) { 
            Start-Sleep -Milliseconds 200 
            $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
            if ($Dispatcher) {
                $Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            }
        }

        if (-not $SyncHash.StepResult) {
            throw "Execution aborted by user during Training Mode."
        }
    }
}
# ----------------------------

# ------------------------------------------------------------------
# BULLETPROOF CONFIG LOADER (Fallback if run standalone)
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] PRINT SPOOLER REMEDIATION"
Write-Host "========================================"

# 1. Fast Ping Check (.NET Ping for PS 5.1 Safety)
$pingSender = New-Object System.Net.NetworkInformation.Ping
try {
    if ($pingSender.Send($Target, 1000).Status -ne "Success") {
        Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
        Write-Host "========================================`n"
        return
    }
} catch {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Execute Spooler Reset
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: WINRM SPOOLER RESET
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: RESET PRINT SPOOLER (WINRM)`n`nWHEN TO USE THIS:`nUse this when a user complains that a document is 'stuck' in the print queue, preventing all other documents from printing, and right-clicking 'Cancel' does nothing.`n`nWHAT IT DOES:`nWe establish a WinRM session to execute three commands sequentially: 1) Stop the 'Spooler' service to release file locks. 2) Delete all corrupted .SHD and .SPL files inside 'C:\Windows\System32\spool\PRINTERS'. 3) Start the 'Spooler' service back up.`n`nIN-PERSON EQUIVALENT:`nOpen Services (services.msc), stop 'Print Spooler', navigate to the PRINTERS folder in File Explorer, delete all files, and start the service again." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock {`n    Stop-Service -Name Spooler -Force`n    Start-Sleep -Seconds 2`n    Remove-Item -Path 'C:\Windows\System32\spool\PRINTERS\*' -File -Force`n    Start-Service -Name Spooler`n}"

    Write-Host "  > [1/1] Stopping service, clearing queue, and restarting..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $spoolFolder = "C:\Windows\System32\spool\PRINTERS"
        if (Test-Path $spoolFolder) {
            Remove-Item -Path "$spoolFolder\*" -File -Force -ErrorAction SilentlyContinue
        }
        Start-Service -Name Spooler -ErrorAction Stop
    }

    Write-Host "`n [UHDC SUCCESS] Print Spooler restarted and print queue cleared!"

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Print Spooler Reset (WinRM)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    # ------------------------------------------------------------------
    # PSEXEC FALLBACK
    # ------------------------------------------------------------------
    Write-Host "  > [i] WinRM Blocked by Firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC SPOOLER RESET`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM query is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WinRM block and execute a chained command directly on the target PC using the native 'net' and 'del' commands.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt on the user's PC and typing: 'net stop spooler', then 'del /Q /F /S %systemroot%\System32\Spool\Printers\*.*', then 'net start spooler'." `
            -Code "`$cmdChain = 'cmd /c `"net stop spooler & del /Q /F /S %systemroot%\System32\Spool\Printers\*.* & net start spooler`"'`n& `$psExecPath /accepteula \\`$Target -s `$cmdChain"

        # Execute chained command via PsExec
        $cmdChain = 'cmd /c "net stop spooler & del /Q /F /S %systemroot%\System32\Spool\Printers\*.* & net start spooler"'
        $spoolOutput = & $psExecPath /accepteula \\$Target -s $cmdChain 2>&1

        $success = $false
        foreach ($line in $spoolOutput) {
            if ($line -match "The Print Spooler service was started successfully") {
                $success = $true
            }
        }

        if ($success) {
            Write-Host "`n [UHDC SUCCESS] Print Spooler restarted and print queue cleared via PsExec!"

            # --- AUDIT LOG INJECTION (Fallback) ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Print Spooler Reset (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Host "  > [!] PsExec fallback failed. Target may be completely locked down."
        }
    } else {
        Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"