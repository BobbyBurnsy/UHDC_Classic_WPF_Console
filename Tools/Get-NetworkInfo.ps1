# Get-NetworkInfo.ps1
# Remotely queries the target for active network adapters.
# Filters out loopback/APIPA addresses and correlates IPv4 addresses with
# interface descriptions, MAC addresses, and link speeds.
# Includes a PsExec fallback using 'ipconfig /all' if WinRM is blocked.

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
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] Network interface diagnostics"
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

# Remote network query
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "Step 1: Query active network interfaces`n`nWhen to use this:`nUse this when troubleshooting network connectivity, verifying if a user is on Wi-Fi or Ethernet, checking link speeds for performance issues, or retrieving a MAC address for DHCP reservations.`n`nWhat it does:`nWe use PsExec to run the native Windows 'ipconfig /all' command on the remote machine. This dumps all IP, DNS, and MAC address configurations for every adapter on the system.`n`nIn-person equivalent:`nOpen Command Prompt and type 'ipconfig /all', or press Win+R, type 'ncpa.cpl' (Network Connections), double-click the active adapter, and click 'Details...'." `
        -Code "psexec.exe \\$Target -s ipconfig /all"

    $netData = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
        $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notmatch "169.254|127.0"

        $results = @()
        foreach ($ip in $ips) {
            $matchAdapter = $adapters | Where-Object Name -eq $ip.InterfaceAlias

            $results += [PSCustomObject]@{
                Adapter = $ip.InterfaceAlias
                Desc    = if ($matchAdapter) { $matchAdapter.InterfaceDescription } else { "Unknown" }
                IP      = $ip.IPAddress
                MAC     = if ($matchAdapter) { $matchAdapter.MacAddress } else { "N/A" }
                Speed   = if ($matchAdapter) { $matchAdapter.LinkSpeed } else { "N/A" }
            }
        }
        return $results
    }

    if ($netData) {
        Write-Host "`n --- Active interfaces ---"
        foreach ($nic in $netData) {
            Write-Host "  > Adapter: $($nic.Adapter)"
            Write-Host "    Desc:    $($nic.Desc)"
            Write-Host "    IP:      $($nic.IP)"
            Write-Host "    MAC:     $($nic.MAC)"
            Write-Host "    Speed:   $($nic.Speed)`n"
        }

        # Audit log
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried Network Info (WinRM)" -SharedRoot $SharedRoot
            }
        }
    } else {
        Write-Host "`n [UHDC] [i] No active IPv4 interfaces found."
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "Step 1 (Fallback): Filter ipconfig output`n`nWhen to use this:`nRunning 'ipconfig /all' returns a massive wall of text, including disconnected Bluetooth adapters and virtual switches. We only want the important stuff.`n`nWhat it does:`nWe pipe the output of 'ipconfig /all' into the native Windows 'findstr' command, searching specifically for lines containing 'IPv4', 'Description', or 'Physical Address' (MAC).`n`nIn-person equivalent:`nOpening Command Prompt and typing 'ipconfig /all | findstr /i `"IPv4 Description Physical`"'." `
            -Code "psexec.exe \\$Target -s cmd /c `"ipconfig /all | findstr /i 'IPv4 Description Physical'`""

        $cmdChain = 'cmd /c "ipconfig /all | findstr /i \"IPv4 Description Physical\""'
        $ipOutput = & $psExecPath /accepteula \\$Target -s $cmdChain 2>&1

        Write-Host "`n --- Active interfaces (Fallback) ---"

        $foundData = $false
        foreach ($line in $ipOutput) {
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }

            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host "  $line"
                $foundData = $true
            }
        }

        if (-not $foundData) {
            Write-Host "  > [!] PsExec fallback failed. Target may be completely locked down."
        } else {
            # Audit log (Fallback)
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Queried Network Info (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"