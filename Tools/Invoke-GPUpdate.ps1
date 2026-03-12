# Invoke-GPUpdate.ps1
# Remotely triggers a forced Group Policy update (Computer policy only).
# Uses /wait:0 to ensure the command returns instantly without hanging.
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
Write-Host " [UHDC] Force GPUpdate: $Target"
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

# Execute remote update
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "STEP 1: FORCE GROUP POLICY UPDATE`n`nWHEN TO USE THIS:`nUse this when a user is missing mapped network drives, hasn't received a newly deployed software package, or when a new security policy (like a firewall rule or LAPS configuration) needs to be applied immediately without waiting for the standard 90-minute background refresh cycle.`n`nWHAT IT DOES:`nWe establish a remote WinRM session to execute the native Windows 'gpupdate' utility. We use the '/force' flag to reapply all policies (not just changed ones), '/target:computer' to limit the scope and speed it up, and '/wait:0' to ensure the command returns instantly without hanging our console if a policy requires a reboot.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open an elevated Command Prompt, type 'gpupdate /force', and wait for the 'Computer Policy update has completed successfully' message." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { gpupdate /force /target:computer /wait:0 }"

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Write-Host "  > [UHDC] Running gpupdate /force /target:computer..."
        gpupdate /force /target:computer /wait:0 | Out-Null
    }

    Write-Host "`n [UHDC] Success: Computer policy update triggered."

    # Audit log
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Forced Remote GPUpdate (WinRM)" -SharedRoot $SharedRoot
        }
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC GPUPDATE`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM connection is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WinRM block and execute the native 'gpupdate' command directly on the target PC as the SYSTEM account.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt on the user's PC and typing 'gpupdate /force /target:computer /wait:0'." `
            -Code "psexec.exe \\$Target -s cmd /c `"gpupdate /force /target:computer /wait:0`""

        $cmd = 'cmd /c "gpupdate /force /target:computer /wait:0"'

        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmd" -Wait -NoNewWindow

        Write-Host "`n [UHDC] Success: Computer policy update triggered via PsExec."

        # Audit log (Fallback)
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { 
                & $AuditHelper -Target $Target -Action "Forced Remote GPUpdate (PsExec Fallback)" -SharedRoot $SharedRoot
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"