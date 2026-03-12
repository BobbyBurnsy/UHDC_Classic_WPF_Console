# Check-BitLocker.ps1
# Remotely queries the target computer to retrieve the BitLocker encryption status 
# for all connected volumes. Includes a PsExec fallback if WinRM is blocked.

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
Write-Host " [UHDC] BitLocker status utility"
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

# Query BitLocker volumes
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY BITLOCKER STATUS`n`nWHEN TO USE THIS:`nUse this to verify if a laptop's hard drive is fully encrypted, or to check which Key Protectors (like TPM or a Numerical Password) are actively securing the drive.`n`nWHAT IT DOES:`nWe use PsExec to run the native Windows 'manage-bde' (BitLocker Drive Encryption Configuration Tool) command on the remote machine. This retrieves the encryption status, protection state, and active key protectors for all mounted volumes.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open an elevated Command Prompt and type 'manage-bde -status', or navigate to 'Control Panel > System and Security > BitLocker Drive Encryption'." `
        -Code "psexec.exe \\$Target -s manage-bde -status"

    $bdeVolumes = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, EncryptionMethod, ProtectionStatus,
            @{Name="Protectors";Expression={ ($_.KeyProtector.KeyProtectorType) -join ", " }}
    }

    Write-Host "`n --- BitLocker volumes ---"

    if ($bdeVolumes) {
        foreach ($vol in $bdeVolumes) {
            Write-Host "  > Drive: $($vol.MountPoint)"
            Write-Host "    Status:     $($vol.VolumeStatus)"
            Write-Host "    Protection: $($vol.ProtectionStatus)"
            Write-Host "    Encryption: $($vol.EncryptionMethod)"
            Write-Host "    Protectors: $($vol.Protectors)`n"
        }

        # Audit log
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried BitLocker Status (WinRM)" -SharedRoot $SharedRoot
            }
        }

    } else {
        Write-Host "  [UHDC] [i] No BitLocker volumes found or feature is not installed."
    }

} catch {
    # PsExec fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): TARGET SPECIFIC DRIVES`n`nWHEN TO USE THIS:`nIf a machine has multiple drives (like a C: OS drive and a D: Data drive), running a general status check can return too much text.`n`nWHAT IT DOES:`nYou can append the drive letter to the 'manage-bde' command to only return the encryption status for that specific volume.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt on the user's PC and typing 'manage-bde -status C:'." `
            -Code "psexec.exe \\$Target -s manage-bde -status C:"

        # Execute manage-bde and capture output/errors
        $bdeOutput = & $psExecPath /accepteula \\$Target -s manage-bde -status 2>&1

        Write-Host "`n --- BitLocker volumes (Fallback) ---"

        $foundData = $false
        foreach ($line in $bdeOutput) {
            # Filter out standard PsExec startup noise and manage-bde copyright headers
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code" -or $line -match "Configuration Tool version") { continue }

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
                    & $AuditHelper -Target $Target -Action "Queried BitLocker Status (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"