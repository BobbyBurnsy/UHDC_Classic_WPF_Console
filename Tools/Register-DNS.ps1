# Register-DNS.ps1
# Forcefully refreshes the target machine's DNS and NetBIOS registration
# on the domain controller. Executes 'ipconfig /flushdns', 'ipconfig /registerdns',
# and 'nbtstat -RR' sequentially via PsExec (SYSTEM context).

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
        } else {
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch { return }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] Remote DNS registration: $Target"
Write-Host "========================================`n"

# We do a quick ping, but we don't stop the script if it fails,
# because if DNS is broken, the ping will naturally fail.
$pingSender = New-Object System.Net.NetworkInformation.Ping
$isOnline = $false
try {
    if ($pingSender.Send($Target, 1000).Status -eq "Success") {
        $isOnline = $true
    }
} catch { }

if (-not $isOnline) {
    Write-Host " [UHDC] [i] Target didn't answer ping (Likely DNS mismatch). Proceeding anyway..." -ForegroundColor Yellow
} else {
    Write-Host " [UHDC] [i] Target is reachable. Proceeding..."
}

$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (Test-Path $psExecPath) {
    try {
        Write-Host " [UHDC]  > Connecting via PsExec..."
        Write-Host " [UHDC]  > Flushing local DNS cache..."
        Write-Host " [UHDC]  > Registering new DNS records..."
        Write-Host " [UHDC]  > Refreshing NetBIOS (nbtstat)..."

        # 1. Execute DNS/WINS refresh chain
        Wait-TrainingStep `
            -Desc "STEP 1: FLUSH AND REGISTER DNS`n`nWHEN TO USE THIS:`nUse this when a computer is turned on and connected to the network, but you cannot connect to it via hostname (e.g., Remote Desktop or File Shares fail). This usually happens when a user switches from Wi-Fi to a wired docking station, giving the laptop a new IP address, but the Domain Controller still has the old IP address cached (a 'stale' DNS record).`n`nWHAT IT DOES:`nWe use PsExec to run a chained command as the SYSTEM account on the remote PC. It flushes the PC's local DNS cache, forces the PC to re-register its current IP address with the Domain Controller's DNS server, and refreshes its NetBIOS names.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open an elevated Command Prompt and type 'ipconfig /flushdns', press Enter, type 'ipconfig /registerdns', press Enter, and finally type 'nbtstat -RR'." `
            -Code "psexec.exe \\$Target -s cmd /c `"ipconfig /flushdns & ipconfig /registerdns & nbtstat -RR`""

        # Chaining the commands with '&' executes them sequentially in a single PsExec session.
        # /accepteula silences the first-run prompt, -s runs as SYSTEM
        $cmdChain = 'cmd /c "ipconfig /flushdns & ipconfig /registerdns & nbtstat -RR"'

        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "`n [UHDC] Success: DNS/WINS refresh commands dispatched to $Target."
        Write-Host "        (Note: It may take 5-10 minutes for the Domain Controller to update)"

        # Audit log
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Forced Remote DNS Flush & Registration" -SharedRoot $SharedRoot
            }
        }

    } catch {
        Write-Host " [UHDC] [!] Error: Failed to execute PsExec. $($_.Exception.Message)"
    }
} else {
    Write-Host " [UHDC] [!] Error: psexec.exe not found at $psExecPath"
    Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
}

Write-Host "========================================`n"