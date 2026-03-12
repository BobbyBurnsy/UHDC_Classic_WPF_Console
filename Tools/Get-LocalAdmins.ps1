# Get-LocalAdmins.ps1
# Remotely queries the target computer to list all members of the local "Administrators" group.
# Includes a PsExec fallback using 'net localgroup' if WinRM is blocked.

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
Write-Host " [UHDC] Local administrator audit"
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

# Query local administrators
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY LOCAL ADMINISTRATORS GROUP`n`nWHEN TO USE THIS:`nUse this when auditing a machine for unauthorized privilege escalation, verifying that LAPS (Local Administrator Password Solution) is functioning, or confirming a specific user/group has the necessary rights to install software.`n`nWHAT IT DOES:`nWe use PsExec to run the native Windows 'net localgroup' command on the remote machine. This queries the local SAM (Security Account Manager) database and returns a list of all accounts and groups that have local admin rights.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt on the user's PC and typing 'net localgroup administrators', or opening Computer Management (compmgmt.msc) and checking the Administrators group." `
        -Code "psexec.exe \\$Target -s net localgroup administrators"

    $admins = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
    }

    Write-Host "`n --- Administrators group members ---"

    if ($admins) {
        foreach ($admin in $admins) {
            $name = $admin.Name
            $source = $admin.PrincipalSource
            $type = $admin.ObjectClass

            Write-Host "  > $name"
            Write-Host "    Type:   $type"
            Write-Host "    Source: $source`n"
        }

        # Audit log
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried Local Administrators (WinRM)" -SharedRoot $SharedRoot
            }
        }

    } else {
        Write-Host "  [UHDC] [i] No members found."
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): CHECK SPECIFIC USER RIGHTS`n`nWHEN TO USE THIS:`nIf you only care about one specific local user (like the built-in Administrator account), dumping the whole admin group might be too noisy.`n`nWHAT IT DOES:`nYou can use the 'net user' command to query a specific local account and see its group memberships directly.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt and typing 'net user Administrator'." `
            -Code "psexec.exe \\$Target -s net user Administrator"

        $netOutput = & $psExecPath /accepteula \\$Target -s net localgroup administrators 2>&1

        Write-Host "`n --- Administrators group members (Fallback) ---"

        $capture = $false
        $foundMembers = $false

        foreach ($line in $netOutput) {
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }

            if ($line -match "^-{10,}") { 
                $capture = $true
                continue 
            }

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
            # Audit log (Fallback)
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Queried Local Administrators (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"