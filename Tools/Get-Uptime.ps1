# Get-Uptime.ps1
# Queries the remote computer's WMI/CIM repository to calculate last boot time and uptime.
# Includes a PsExec fallback to query 'systeminfo' if WMI is blocked.

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
Write-Host " [UHDC] Uptime check: $Target"
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

# Execute WMI/CIM query
try {
    Write-Host " [UHDC] [i] Querying $Target via WMI..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY OPERATING SYSTEM UPTIME`n`nWHEN TO USE THIS:`nUse this when a user complains about general system slowness, strange application glitches, or when verifying if a user actually rebooted their PC like you asked them to.`n`nWHAT IT DOES:`nWe use PsExec to run the native Windows 'systeminfo' command on the remote machine. This command pulls a massive amount of data, including the exact date and time the OS was last booted.`n`nIN-PERSON EQUIVALENT:`nPress Ctrl+Shift+Esc to open Task Manager, click the 'Performance' tab, select 'CPU', and look at the 'Up time' counter at the bottom." `
        -Code "psexec.exe \\$Target -s systeminfo"

    $os = Get-CimInstance -ComputerName $Target -ClassName Win32_OperatingSystem -ErrorAction Stop
    $boot = $os.LastBootUpTime
    $now = Get-Date
    $uptime = $now - $boot

    Write-Host "  > Last boot: $($boot.ToString('MM/dd/yyyy HH:mm'))" 
    Write-Host "  > Uptime:    $($uptime.Days) days, $($uptime.Hours) hours, $($uptime.Minutes) minutes" 

    if ($uptime.Days -gt 14) {
        Write-Host " [UHDC] [i] Note: Machine has not been rebooted in over 2 weeks." -ForegroundColor Yellow
    }

    # Audit log
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) { 
            & $AuditHelper -Target $Target -Action "Checked Uptime ($($uptime.Days) Days)" -SharedRoot $SharedRoot
        }
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WMI blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): FILTER SYSTEMINFO OUTPUT`n`nWHEN TO USE THIS:`nRunning 'systeminfo' by itself returns way too much text. We only care about the boot time.`n`nWHAT IT DOES:`nWe pipe the output of 'systeminfo' directly into the native Windows 'find' command, searching specifically for the string 'System Boot Time'. This filters the output down to a single, readable line.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt on the user's PC and typing 'systeminfo | find `"System Boot Time`"'." `
            -Code "psexec.exe \\$Target -s cmd /c `"systeminfo | find 'System Boot Time'`""

        $sysInfoOutput = & $psExecPath /accepteula \\$Target -s cmd /c 'systeminfo | find "System Boot Time"' 2>&1

        $bootTimeFound = $false
        foreach ($line in $sysInfoOutput) {
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }

            if ($line -match "System Boot Time:") {
                Write-Host "  > $line"
                $bootTimeFound = $true
            }
        }

        if (-not $bootTimeFound) {
            Write-Host "  > [!] PsExec fallback failed. Target may be completely locked down."
        } else {
            # Audit log (Fallback)
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Checked Uptime (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"