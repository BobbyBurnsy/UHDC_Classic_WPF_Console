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

# --- Training Mode Helper ---
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

# --- Load Configuration ---
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
Write-Host " [UHDC] BITLOCKER STATUS UTILITY"
Write-Host "========================================"

# --- 1. Fast Ping Check ---
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

# --- 2. Query BitLocker Volumes ---
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY BITLOCKER STATUS`n`nWHEN TO USE THIS:`nUse this to verify if a laptop's hard drive is fully encrypted, or to check which Key Protectors (like TPM or a Numerical Password) are actively securing the drive.`n`nWHAT IT DOES:`nWe are establishing a remote WinRM session to query the target's BitLocker management interface using the 'Get-BitLockerVolume' cmdlet. This retrieves the encryption status, protection state, and active key protectors for all mounted volumes.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open an elevated Command Prompt and type 'manage-bde -status', or navigate to 'Control Panel > System and Security > BitLocker Drive Encryption'." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionMethod, KeyProtector }"

    $bdeVolumes = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, EncryptionMethod, ProtectionStatus,
            @{Name="Protectors";Expression={ ($_.KeyProtector.KeyProtectorType) -join ", " }}
    }

    Write-Host "`n --- BitLocker Volumes ---"

    if ($bdeVolumes) {
        foreach ($vol in $bdeVolumes) {
            Write-Host "  > Drive: $($vol.MountPoint)"
            Write-Host "    Status:     $($vol.VolumeStatus)"
            Write-Host "    Protection: $($vol.ProtectionStatus)"
            Write-Host "    Encryption: $($vol.EncryptionMethod)"
            Write-Host "    Protectors: $($vol.Protectors)`n"
        }

        # --- Audit Log ---
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
    # --- PsExec Fallback ---
    Write-Host "  > [i] WinRM Blocked by Firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC MANAGE-BDE`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM query is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WinRM block and execute the native 'manage-bde -status' command directly on the target PC. We then stream the text output back to the console.`n`nIN-PERSON EQUIVALENT:`nOpening Command Prompt on the user's PC and typing 'manage-bde -status'." `
            -Code "`$output = & `$psExecPath /accepteula \\`$Target -s manage-bde -status"

        # Execute manage-bde and capture output/errors
        $bdeOutput = & $psExecPath /accepteula \\$Target -s manage-bde -status 2>&1

        Write-Host "`n --- BitLocker Volumes (Fallback) ---"

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
            # --- Audit Log (Fallback) ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) { 
                    & $AuditHelper -Target $Target -Action "Queried BitLocker Status (PsExec Fallback)" -SharedRoot $SharedRoot
                }
            }
        }
    } else {
        Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"
