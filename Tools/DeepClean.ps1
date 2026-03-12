# DeepClean.ps1
# Silently clears and recreates the MECM (SCCM) cache using PsExec as SYSTEM. 
# Uses WinRM to empty Windows Temp, all User Temp folders, the Recycle Bin, 
# and triggers a background Windows Disk Cleanup (cleanmgr /sagerun:1).
# Calculates the exact amount of space freed and logs it for auditing/gamification.

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
Write-Host " [UHDC] Remote deep cleanup utility"
Write-Host "========================================`n"

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

# --- Pre-Cleanup Space Check ---
$freeBefore = 0
try {
    $diskBefore = Get-CimInstance -ComputerName $Target -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($diskBefore) { $freeBefore = $diskBefore.FreeSpace }
} catch {}

# 1. MECM / SCCM cache cleanup
Wait-TrainingStep `
    -Desc "STEP 1: PURGE MECM (SCCM) CACHE`n`nWHEN TO USE THIS:`nUse this when Software Center deployments are stuck at 0%, failing with 'hash mismatch' errors, or when the C: drive is critically low on space due to large cached application installers.`n`nWHAT IT DOES:`nWe use PsExec (running as the SYSTEM account) to forcefully delete and recreate the 'ccmcache' directory using the native 'rd' (remove directory) and 'mkdir' commands, bypassing standard permission blocks.`n`nIN-PERSON EQUIVALENT:`nOpen Control Panel > Configuration Manager > Cache tab > Configure Settings > Delete Files." `
    -Code "psexec.exe \\$Target -s cmd /c `"rd /s /q C:\Windows\ccmcache & mkdir C:\Windows\ccmcache`""

Write-Host " [UHDC] [1/3] Clearing & rebuilding MECM (SCCM) cache..."

$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (Test-Path $psExecPath) {
    try {
        $cmdChain = 'cmd /c "rd /s /q C:\Windows\ccmcache & mkdir C:\Windows\ccmcache"'
        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "  > [OK] CCMCache purged and rebuilt."
    } catch {
        Write-Host "  > [!] Error: Failed to execute PsExec."
    }
} else {
    Write-Host "  > [!] Error: psexec.exe not found in $psExecPath"
    Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
}

# 2. Temp folders & Recycle Bin
Wait-TrainingStep `
    -Desc "STEP 2: CLEAR TEMP FOLDERS & RECYCLE BIN`n`nWHEN TO USE THIS:`nUse this when a user is experiencing bizarre application glitches (like Office apps crashing), cannot open certain files, or needs immediate disk space recovery.`n`nWHAT IT DOES:`nWe use remote commands to forcefully delete files in 'C:\Windows\Temp', iterate through every user profile to clear their 'AppData\Local\Temp' folders, and forcefully empty the Recycle Bin. (Note: The code below shows the native command equivalent for clearing the system temp and recycle bin).`n`nIN-PERSON EQUIVALENT:`nPress Win+R, type '%temp%', select all files, and delete. Repeat for 'C:\Windows\Temp'. Finally, right-click the Recycle Bin on the desktop and select 'Empty Recycle Bin'." `
    -Code "psexec.exe \\$Target -s cmd /c `"del /q /f /s C:\Windows\Temp\* & rd /s /q C:\`$Recycle.Bin`""

Write-Host "`n [UHDC] [2/3] Emptying temp folders & Recycle Bin..."
try {
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        # Clear Windows Temp
        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

        # Iteratively clear every user's AppData Temp folder
        $userProfiles = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue
        foreach ($profile in $userProfiles) {
            $tempPath = "$($profile.FullName)\AppData\Local\Temp\*"
            Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Clear the Recycle Bin across all drives
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  > [OK] System temp, user temp, and Recycle Bin zeroed out."
} catch {
    Write-Host "  > [!] Error: Failed to clear temp/Recycle Bin."
    Write-Host "     $($_.Exception.Message)"
}

# --- Post-Cleanup Space Check & Calculation ---
$freeAfter = 0
$freedStr = "0 MB"
try {
    $diskAfter = Get-CimInstance -ComputerName $Target -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($diskAfter) { 
        $freeAfter = $diskAfter.FreeSpace 
        $freedBytes = $freeAfter - $freeBefore

        # Prevent negative numbers if something downloaded in the background during the script
        if ($freedBytes -lt 0) { $freedBytes = 0 }

        if ($freedBytes -ge 1GB) {
            $freedStr = "$([math]::Round($freedBytes / 1GB, 2)) GB"
        } else {
            $freedStr = "$([math]::Round($freedBytes / 1MB, 2)) MB"
        }
    }
} catch {}

Write-Host "`n [UHDC] Success: Immediate cleanup freed $freedStr of disk space!" -ForegroundColor Green

# 3. Disk Cleanup (Sagerun)
Wait-TrainingStep `
    -Desc "STEP 3: TRIGGER BACKGROUND DISK CLEANUP`n`nWHEN TO USE THIS:`nUse this for general PC maintenance, post-Windows Update cleanup, or to safely remove old Windows installation files (Windows.old) without interrupting the user.`n`nWHAT IT DOES:`nWe remotely trigger the native Windows Disk Cleanup utility ('cleanmgr.exe') using the '/sagerun:1' flag, which runs a pre-configured, silent deep clean in the background.`n`nIN-PERSON EQUIVALENT:`nOpen the Start Menu, search for 'Disk Cleanup', select the C: drive, click 'Clean up system files', check all the boxes, and click OK." `
    -Code "psexec.exe \\$Target -s cleanmgr.exe /sagerun:1"

Write-Host "`n [UHDC] [3/3] Triggering Disk Cleanup (sagerun)..."
try {
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:1" -WindowStyle Hidden
    }
    Write-Host "  > [OK] Disk Cleanup job dispatched to background."
    Write-Host "  > [i] Note: This will free additional space over the next 10-15 minutes." -ForegroundColor DarkGray
} catch {
    Write-Host "  > [!] Error: Failed to dispatch cleanmgr."
    Write-Host "     $($_.Exception.Message)"
}

# Audit log
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action "Deep Clean Executed (Freed: $freedStr)" -SharedRoot $SharedRoot
    }
}

Write-Host "========================================`n"