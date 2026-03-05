# Get-Uptime.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Queries the remote computer's WMI/CIM repository for Win32_OperatingSystem
# to calculate the exact Last Boot Up Time and current Uptime.
# Features an automated PsExec fallback to query 'systeminfo' if WMI ports are blocked.
# Optimized for PS 5.1 (.NET Ping & WPF Training Mode Fix).

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
Write-Host " [UHDC] UPTIME CHECK: $Target"
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

# 2. Execute WMI/CIM Query with PsExec Fallback
try {
    Write-Host " [UHDC] [i] Querying $Target via WMI..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY OPERATING SYSTEM UPTIME`n`nWHEN TO USE THIS:`nUse this when a user complains about general system slowness, strange application glitches, or when verifying if a user actually rebooted their PC like you asked them to.`n`nWHAT IT DOES:`nWe establish a remote WMI/CIM session to query the 'Win32_OperatingSystem' class. We extract the 'LastBootUpTime' property (which is a native DateTime object) and subtract it from the current time to calculate exactly how many days, hours, and minutes the PC has been running.`n`nIN-PERSON EQUIVALENT:`nPress Ctrl+Shift+Esc to open Task Manager, click the 'Performance' tab, select 'CPU', and look at the 'Up time' counter at the bottom." `
        -Code "`$os = Get-CimInstance -ComputerName `$Target -ClassName Win32_OperatingSystem`n`$uptime = (Get-Date) - `$os.LastBootUpTime"

    $os = Get-CimInstance -ComputerName $Target -ClassName Win32_OperatingSystem -ErrorAction Stop
    $boot = $os.LastBootUpTime
    $now = Get-Date
    $uptime = $now - $boot

    Write-Host "  > Last Boot: $($boot.ToString('MM/dd/yyyy HH:mm'))" 
    Write-Host "  > Uptime:    $($uptime.Days) Days, $($uptime.Hours) Hours, $($uptime.Minutes) Minutes" 

    if ($uptime.Days -gt 14) {
        Write-Host " [UHDC] [!] ATTENTION: Machine has not been rebooted in over 2 weeks." -ForegroundColor Yellow
    }

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) { 
            & $AuditHelper -Target $Target -Action "Checked Uptime ($($uptime.Days) Days)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    # ------------------------------------------------------------------
    # PSEXEC FALLBACK
    # ------------------------------------------------------------------
    Write-Host "  > [i] WMI Blocked by Firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC SYSTEMINFO`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WMI query is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WMI block and execute the native 'systeminfo' command directly on the target PC. We pipe the output into 'find' to isolate just the line containing the boot time.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt on the user's PC and typing 'systeminfo | find `"System Boot Time`"'." `
            -Code "`$output = & `$psExecPath /accepteula \\`$Target -s cmd /c 'systeminfo | find `"System Boot Time`"'"

        # Execute systeminfo and capture output/errors
        $sysInfoOutput = & $psExecPath /accepteula \\$Target -s cmd /c 'systeminfo | find "System Boot Time"' 2>&1

        $bootTimeFound = $false
        foreach ($line in $sysInfoOutput) {
            # Filter out standard PsExec startup noise
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }

            if ($line -match "System Boot Time:") {
                Write-Host "  > $line"
                $bootTimeFound = $true
            }
        }

        if (-not $bootTimeFound) {
            Write-Host "  > [!] PsExec fallback failed. Target may be completely locked down."
        } else {
            # --- AUDIT LOG INJECTION (Fallback) ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Checked Uptime (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"