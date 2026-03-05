# Restart-SCCMAgent.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely restarts the MECM/SCCM Agent service (CcmExec).
# It includes a 4-second delay between stopping and starting to ensure that
# the service fully releases its locks on the local log files before spinning back up.
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
Write-Host " [UHDC] RESTART SCCM AGENT: $Target"
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

# 2. Execute Remote Restart
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: RESTART THE SMS AGENT HOST (WinRM)
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: RESTART THE SMS AGENT HOST`n`nWHEN TO USE THIS:`nUse this when a user complains that an application in Software Center is stuck on 'Downloading' or 'Waiting to install', or when a newly deployed application is not showing up in their Software Center at all.`n`nWHAT IT DOES:`nWe are establishing a remote WinRM session to restart the 'CcmExec' (SMS Agent Host) service. We explicitly stop the service, wait 4 seconds to ensure it fully releases its lock on the local SCCM log files (like CAS.log or AppEnforce.log), and then start it again. This forces the agent to wake up and request a fresh machine policy from the management point.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open Services (services.msc), locate 'SMS Agent Host', right-click it, and select 'Restart'. Alternatively, you would open the Configuration Manager applet in the Control Panel, go to the Actions tab, select 'Machine Policy Retrieval & Evaluation Cycle', and click 'Run Now'." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock {`n    Stop-Service -Name CcmExec -Force`n    Start-Sleep -Seconds 4`n    Start-Service -Name CcmExec`n}"

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Write-Host "  > [UHDC] Stopping CcmExec service..."
        Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue | Out-Null

        # Give the service a moment to fully release its lock on log files
        Start-Sleep -Seconds 4

        Write-Host "  > [UHDC] Starting CcmExec service..."
        Start-Service -Name CcmExec -ErrorAction Stop
    }

    Write-Host "`n [UHDC SUCCESS] SCCM Agent restarted successfully!"
    Write-Host " [UHDC] [i] Note: It may take 2-3 minutes for the PC to check in with the Site Server."

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Restarted SCCM Agent (WinRM)" -SharedRoot $SharedRoot
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
            -Desc "STEP 1 (FALLBACK): PSEXEC SCCM RESTART`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM query is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WinRM block and execute a chained command directly on the target PC. It uses 'net stop' to kill the service, 'timeout' to wait 4 seconds, and 'net start' to bring it back online.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt and typing the equivalent native commands manually." `
            -Code "`$cmdChain = 'cmd /c `"net stop CcmExec & timeout /t 4 /nobreak > NUL & net start CcmExec`"'`n& `$psExecPath /accepteula \\`$Target -s `$cmdChain"

        # Execute chained command via PsExec
        $cmdChain = 'cmd /c "net stop CcmExec & timeout /t 4 /nobreak > NUL & net start CcmExec"'

        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "`n [UHDC SUCCESS] SCCM Agent restarted via PsExec!"
        Write-Host " [UHDC] [i] Note: It may take 2-3 minutes for the PC to check in with the Site Server."

        # --- AUDIT LOG INJECTION (Fallback) ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { 
                & $AuditHelper -Target $Target -Action "Restarted SCCM Agent (PsExec Fallback)" -SharedRoot $SharedRoot
            }
        }
    } else {
        Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"