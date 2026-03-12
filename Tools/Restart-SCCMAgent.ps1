# Restart-SCCMAgent.ps1
# Remotely restarts the MECM/SCCM Agent service (CcmExec).
# Includes a 4-second delay to release log file locks before restarting.
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
Write-Host " [UHDC] Restart SCCM agent: $Target"
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

# Execute remote restart
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "STEP 1: RESTART THE SMS AGENT HOST`n`nWHEN TO USE THIS:`nUse this when a user complains that an application in Software Center is stuck on 'Downloading' or 'Waiting to install', or when a newly deployed application is not showing up in their Software Center at all.`n`nWHAT IT DOES:`nWe are restarting the 'CcmExec' (SMS Agent Host) service. We explicitly stop the service, wait 4 seconds to ensure it fully releases its lock on the local SCCM log files (like CAS.log or AppEnforce.log), and then start it again. While this console uses WinRM for speed when available, the command below shows how to do this natively using PsExec and standard Windows commands.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open Services (services.msc), locate 'SMS Agent Host', right-click it, and select 'Restart'." `
        -Code "psexec.exe \\$Target -s cmd /c `"net stop CcmExec & timeout /t 4 /nobreak > NUL & net start CcmExec`""

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Write-Host "  > [UHDC] Stopping CcmExec service..."
        Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue | Out-Null

        # Give the service a moment to fully release its lock on log files
        Start-Sleep -Seconds 4

        Write-Host "  > [UHDC] Starting CcmExec service..."
        Start-Service -Name CcmExec -ErrorAction Stop
    }

    Write-Host "`n [UHDC] Success: SCCM Agent restarted successfully."
    Write-Host " [UHDC] [i] Note: It may take 2-3 minutes for the PC to check in with the Site Server."

    # Audit log
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Restarted SCCM Agent (WinRM)" -SharedRoot $SharedRoot
        }
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC SCCM RESTART`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM connection is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nSince WinRM failed, we are falling back to the native PsExec method. We use 'net stop' to kill the service, 'timeout' to wait 4 seconds, and 'net start' to bring it back online.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt and typing the equivalent native commands manually." `
            -Code "psexec.exe \\$Target -s cmd /c `"net stop CcmExec & timeout /t 4 /nobreak > NUL & net start CcmExec`""

        $cmdChain = 'cmd /c "net stop CcmExec & timeout /t 4 /nobreak > NUL & net start CcmExec"'

        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "`n [UHDC] Success: SCCM Agent restarted via PsExec."
        Write-Host " [UHDC] [i] Note: It may take 2-3 minutes for the PC to check in with the Site Server."

        # Audit log (Fallback)
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { 
                & $AuditHelper -Target $Target -Action "Restarted SCCM Agent (PsExec Fallback)" -SharedRoot $SharedRoot
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"