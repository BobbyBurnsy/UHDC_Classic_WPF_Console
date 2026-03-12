# Fix-PrintSpooler.ps1
# Remotely stops the Print Spooler service, deletes stuck files in the 
# spool\PRINTERS directory, and restarts the service.
# Includes a PsExec fallback if WinRM is blocked.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# Training mode helper
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
            throw "Execution aborted by user during training mode."
        }
    }
}

# Load configuration
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
Write-Host " [UHDC] Print spooler remediation"
Write-Host "========================================"

# Fast ping check
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

# Execute spooler reset
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "Step 1: Reset the print spooler`n`nWhen to use this:`nUse this when a user complains that a document is 'stuck' in the print queue, preventing all other documents from printing, and right-clicking 'Cancel' does nothing.`n`nWhat it does:`nWe use PsExec to run a chain of native Windows commands. First, 'net stop spooler' halts the service to release file locks. Then, 'del' wipes out the corrupted .SHD and .SPL files inside the PRINTERS folder. Finally, 'net start spooler' brings the service back online.`n`nIn-person equivalent:`nOpening an elevated Command Prompt and typing these commands manually, or using services.msc and File Explorer." `
        -Code "psexec.exe \\$Target -s cmd /c `"net stop spooler & del /Q /F /S %systemroot%\System32\Spool\Printers\*.* & net start spooler`""

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

    Write-Host "`n [UHDC] Success: Print spooler restarted and print queue cleared."

    # Audit log
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Print Spooler Reset (WinRM)" -SharedRoot $SharedRoot
        }
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "Step 1 (Fallback): Restart service only`n`nWhen to use this:`nSometimes the queue isn't jammed with files, but the spooler service itself has just crashed or hung.`n`nWhat it does:`nYou can skip the file deletion and just bounce the service using the native 'net' commands.`n`nIn-person equivalent:`nOpening Command Prompt and typing 'net stop spooler' followed by 'net start spooler'." `
            -Code "psexec.exe \\$Target -s cmd /c `"net stop spooler & net start spooler`""

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
            Write-Host "`n [UHDC] Success: Print spooler restarted and print queue cleared via PsExec."

            # Audit log (Fallback)
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
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"