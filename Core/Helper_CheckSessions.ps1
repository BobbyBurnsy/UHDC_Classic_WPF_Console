# Helper_CheckSessions.ps1 - Place this script in the \Core folder
# DESCRIPTION: Queries a remote computer to retrieve a list of all currently 
# active and disconnected user sessions. This allows technicians to safely 
# verify who is physically or remotely logged into a machine before initiating 
# disruptive actions like forced logoffs or reboots. Includes an automated 
# PsExec fallback to bypass strict Windows Firewall RPC blocks.
# Optimized for PS 5.1 (.NET Ping & Training Mode Integration).

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

if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Host " [UHDC] [!] Error: No target computer provided."
    return
}

Write-Host "========================================"
Write-Host " [UHDC] SESSION CHECK: $Target"
Write-Host "========================================"

# --- 1. FAST PING CHECK (PS 5.1 Safe) ---
$pingSender = New-Object System.Net.NetworkInformation.Ping
$isOnline = $false

try {
    if ($pingSender.Send($Target, 1000).Status -eq "Success") { 
        $isOnline = $true 
    }
} catch {}

if (-not $isOnline) {
    Write-Host " [UHDC] [!] $Target is offline or not responding."
    Write-Host "========================================`n"
    return
}

# Helper variables
$UpdateHelper = if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) { Join-Path -Path $SharedRoot -ChildPath "Core\Helper_UpdateHistory.ps1" } else { $null }
$psExecPath = if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) { Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe" } else { $null }

# --- 2. WMI CONSOLE CHECK (Physical Login) ---
Write-Host " [UHDC] [i] Querying physical console user..."

Wait-TrainingStep `
    -Desc "STEP 1: QUERY PHYSICAL CONSOLE`n`nWHEN TO USE THIS:`nUse this to see who is physically sitting at the computer right now, or whose profile is actively displayed on the monitor.`n`nWHAT IT DOES:`nWe use WMI to query the 'Win32_ComputerSystem' class and check the 'UserName' property. This specifically returns the user attached to the physical console session.`n`nIN-PERSON EQUIVALENT:`nWalking up to the computer and reading the name on the lock screen or Start Menu." `
    -Code "`$comp = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName `$Target`n`$rawUser = `$comp.UserName"

try {
    $comp = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Target -ErrorAction Stop
    $rawUser = $comp.UserName

    if ($rawUser) {
        Write-Host "  > Console User: $rawUser" 

        # INTELLIGENCE INJECTION: Strip domain and update history!
        if ($UpdateHelper -and (Test-Path $UpdateHelper)) {
            $cleanUser = ($rawUser -split "\\")[-1].Trim()
            & $UpdateHelper -User $cleanUser -Computer $Target -SharedRoot $SharedRoot
            Write-Host "  > [UHDC INTEL] History map updated for $cleanUser." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  > Console User: [Nobody is physically logged in]"
    }
} catch {
    Write-Host "  > [!] WMI Query Failed: RPC unavailable or Access Denied." 
}

# --- 3. TERMINAL/RDP SESSION CHECK (quser) ---
Write-Host "`n [UHDC] [i] Querying terminal/background sessions..."

Wait-TrainingStep `
    -Desc "STEP 2: QUERY BACKGROUND SESSIONS`n`nWHEN TO USE THIS:`nUse this to see if anyone is connected via Remote Desktop, or if a previous user locked their screen and walked away instead of signing out (leaving a 'Disconnected' session running in the background).`n`nWHAT IT DOES:`nWe execute the native Windows 'quser' command against the target server. If the Windows Firewall blocks the RPC connection, we automatically fall back to using PsExec to bypass the block and run the command locally on the target.`n`nIN-PERSON EQUIVALENT:`nOpening Task Manager, clicking the 'Users' tab, and looking at the list of signed-in accounts." `
    -Code "`$quserOutput = quser /server:`$Target 2>&1`nif (`$quserOutput -match 'Error') {`n    `$quserOutput = & `$psExecPath /accepteula \\`$Target -s quser 2>&1`n}"

try {
    # We capture the output and the error stream (2>&1)
    $quserOutput = quser /server:$Target 2>&1

    # [UHDC] PSEXEC FALLBACK INJECTION
    # If the firewall blocks RPC, native quser fails. We bypass it using PsExec.
    if ($quserOutput -match "Error" -or $quserOutput -match "RPC") {
        Write-Host "  > [i] RPC Blocked by Firewall. Attempting PsExec bypass..." -ForegroundColor DarkGray

        if ($psExecPath -and (Test-Path $psExecPath)) {
            # Run quser locally on the target and stream it back
            $quserOutput = & $psExecPath /accepteula \\$Target -s quser 2>&1
        } else {
            Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot bypass firewall."
        }
    }

    # Check if the output contains the standard "No User exists" error
    if ($quserOutput -match "No User exists") {
        Write-Host "  > No background or remote sessions found."
    } 
    elseif ($quserOutput -match "Error" -or $quserOutput -match "RPC" -or $quserOutput -match "could not be found") {
        Write-Host "  > [!] Target refused connection. Unable to verify sessions."
    }
    else {
        # Print the valid session table cleanly
        foreach ($line in $quserOutput) {
            # Filter out standard PsExec startup noise
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }

            Write-Host "  $line"

            # INTELLIGENCE INJECTION: Regex to parse active RDP users and update history!
            if ($line -match "^\s*>?([a-zA-Z0-9_\.-]+)\s+.*Active") {
                $qUser = $matches[1]
                if ($qUser -ne "services" -and $UpdateHelper -and (Test-Path $UpdateHelper)) {
                    & $UpdateHelper -User $qUser -Computer $Target -SharedRoot $SharedRoot
                    Write-Host "  > [UHDC INTEL] History map updated for $qUser." -ForegroundColor DarkGray
                }
            }
        }
    }
} catch {
    Write-Host "  > [!] Terminal query failed." 
}

Write-Host "========================================`n"