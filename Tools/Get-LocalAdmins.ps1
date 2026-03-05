# Get-LocalAdmins.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely queries the target computer to list all members of the local
# "Administrators" group. Features an automated PsExec fallback using the native
# 'net localgroup' command if WinRM is blocked by the Windows Firewall.
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
Write-Host " [UHDC] LOCAL ADMINISTRATOR AUDIT"
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

# 2. Query Local Administrators
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: QUERY LOCAL SAM DATABASE (WinRM)
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: QUERY LOCAL ADMINISTRATORS GROUP`n`nWHEN TO USE THIS:`nUse this when auditing a machine for unauthorized privilege escalation, verifying that LAPS (Local Administrator Password Solution) is functioning, or confirming a specific user/group has the necessary rights to install software.`n`nWHAT IT DOES:`nWe are establishing a WinRM session to query the local SAM (Security Account Manager) database of the target machine. We specifically target the built-in 'Administrators' group and return its members, identifying whether they are local accounts or Active Directory objects.`n`nIN-PERSON EQUIVALENT:`nRight-click the Start Menu, select 'Computer Management' (compmgmt.msc), expand 'Local Users and Groups', click 'Groups', and double-click the 'Administrators' group to view its members." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Get-LocalGroupMember -Group 'Administrators' | Select-Object Name, PrincipalSource, ObjectClass }"

    # We grab the objects remotely and bring them back for local formatting
    $admins = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
    }

    Write-Host "`n --- Administrators Group Members ---"

    if ($admins) {
        foreach ($admin in $admins) {
            # Strip out the PSComputerName property that Invoke-Command secretly adds
            $name = $admin.Name
            $source = $admin.PrincipalSource
            $type = $admin.ObjectClass

            Write-Host "  > $name"
            Write-Host "    Type:   $type"
            Write-Host "    Source: $source`n"
        }

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried Local Administrators (WinRM)" -SharedRoot $SharedRoot
            }
        }
        # ---------------------------

    } else {
        Write-Host "  [UHDC] [i] No members found."
    }

} catch {
    # ------------------------------------------------------------------
    # PSEXEC FALLBACK
    # ------------------------------------------------------------------
    Write-Host "  > [i] WinRM Blocked by Firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC NET LOCALGROUP`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM query is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WinRM block and execute the native 'net localgroup administrators' command directly on the target PC. We then parse the text output to extract the list of users.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt on the user's PC and typing 'net localgroup administrators'." `
            -Code "`$output = & `$psExecPath /accepteula \\`$Target -s net localgroup administrators"

        # Execute net localgroup and capture output/errors
        $netOutput = & $psExecPath /accepteula \\$Target -s net localgroup administrators 2>&1

        Write-Host "`n --- Administrators Group Members (Fallback) ---"

        $capture = $false
        $foundMembers = $false

        foreach ($line in $netOutput) {
            # Filter out standard PsExec startup noise
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }

            # The actual list of names starts after a line of dashes
            if ($line -match "^-{10,}") { 
                $capture = $true
                continue 
            }

            # The list ends with this success message
            if ($line -match "The command completed successfully.") { 
                $capture = $false
                continue 
            }

            if ($capture -and -not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host "  > $($line.Trim())"
                $foundMembers = $true
            }
        }

        if (-not $foundMembers) {
            Write-Host "  > [!] PsExec fallback failed. Target may be completely locked down."
        } else {
            # --- AUDIT LOG INJECTION (Fallback) ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Queried Local Administrators (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"