# RemapNetworkDrives.ps1
# Locates the currently logged-in user on the target machine, finds their
# active Desktop (accounting for OneDrive folder redirection), copies a custom 
# RemapDrives.cmd from the \Core folder via the C$ share, and sends a popup.

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
        while (-not $SyncHash.StepAck) { Start-Sleep -Milliseconds 200 }

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
Write-Host " [UHDC] Remap network drives: $Target"
Write-Host "========================================"

# Fast ping check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# Verify source file exists
$SourceCmd = Join-Path -Path $SharedRoot -ChildPath "Core\RemapDrives.cmd"
if (-not (Test-Path $SourceCmd)) {
    Write-Host " [UHDC] [!] Error: RemapDrives.cmd not found in \Core folder."
    Write-Host "        Expected path: $SourceCmd"
    return
}

try {
    Write-Host " [UHDC] [i] Connecting to $Target..."

    # 1. Identify logged-in user
    Wait-TrainingStep `
        -Desc "STEP 1: IDENTIFY ACTIVE USER`n`nWHEN TO USE THIS:`nBefore we can place a file on a user's desktop, we need to know exactly who is currently logged into the machine.`n`nWHAT IT DOES:`nWe query the target machine to find the active user session. While the script uses WMI under the hood for reliability, you can easily do this natively using the 'quser' command.`n`nIN-PERSON EQUIVALENT:`nWalking up to the computer and reading the name on the lock screen or Start Menu." `
        -Code "quser /server:$Target"

    Write-Host "  > [1/4] Querying active user session..."
    $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Target -ErrorAction Stop
    $rawUser = $compInfo.UserName

    if (-not $rawUser) {
        Write-Host "  > [!] No user is currently logged into $Target. Aborting."
        return
    }

    $cleanUser = ($rawUser -split "\\")[-1].Trim()
    Write-Host "  > [OK] Found active user: $cleanUser"

    # 2. Resolve desktop path
    Wait-TrainingStep `
        -Desc "STEP 2: RESOLVE DESKTOP PATH`n`nWHEN TO USE THIS:`nModern Windows environments often use OneDrive Known Folder Move (KFM), which redirects the Desktop from 'C:\Users\Name\Desktop' to 'C:\Users\Name\OneDrive - Company\Desktop'.`n`nWHAT IT DOES:`nWe scan the user's profile directory via the hidden C$ administrative share. We look for a 'OneDrive' folder to see if their Desktop is synced to the cloud. If not, we fall back to the standard local Desktop path.`n`nIN-PERSON EQUIVALENT:`nOpening File Explorer, navigating to C:\Users, and checking if their Desktop is inside a OneDrive folder." `
        -Code "dir `"\\$Target\C`$\Users\$cleanUser\OneDrive*`""

    Write-Host "  > [2/4] Locating Desktop directory..."
    $basePath = "\\$Target\C$\Users\$cleanUser"
    $desktopPath = "$basePath\Desktop"

    $odPath = Get-ChildItem -Path $basePath -Filter "OneDrive*" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\Desktop" } | Select-Object -ExpandProperty FullName -First 1

    if ($odPath) {
        $desktopPath = "$odPath\Desktop"
        Write-Host "  > [OK] OneDrive redirection detected."
    } else {
        Write-Host "  > [OK] Standard local Desktop detected."
    }

    # 3. Copy the file
    Wait-TrainingStep `
        -Desc "STEP 3: DEPLOY THE SCRIPT`n`nWHEN TO USE THIS:`nNow that we know exactly where the user's Desktop is located, we can push the remediation script.`n`nWHAT IT DOES:`nWe use standard SMB file copying to transfer 'RemapDrives.cmd' from our central \Core folder directly to the user's Desktop.`n`nIN-PERSON EQUIVALENT:`nPlugging in a flash drive and dragging the script onto their Desktop." `
        -Code "copy `"$SourceCmd`" `"$desktopPath\RemapDrives.cmd`""

    Write-Host "  > [3/4] Copying RemapDrives.cmd to Desktop..."
    Copy-Item -Path $SourceCmd -Destination "$desktopPath\RemapDrives.cmd" -Force -ErrorAction Stop
    Write-Host "  > [OK] File deployed successfully."

    # 4. Send notification
    Wait-TrainingStep `
        -Desc "STEP 4: NOTIFY THE USER`n`nWHEN TO USE THIS:`nThe file is on their Desktop, but they might not notice it. We need to tell them what to do next.`n`nWHAT IT DOES:`nWe use the native Windows 'msg.exe' utility to send a direct pop-up message to the target computer's screen, instructing them to run the file.`n`nIN-PERSON EQUIVALENT:`nTapping the user on the shoulder and saying, 'Hey, I just put a file on your desktop. Double-click it to fix your drives.'" `
        -Code "msg * /server:$Target `"Help Desk has placed RemapDrives.cmd on your desktop. Please double-click it to restore your network drives.`""

    Write-Host "  > [4/4] Sending notification popup to user..."
    $msgText = "Help Desk has placed RemapDrives.cmd on your desktop. Please double-click it to restore your network drives."
    $msgOutput = & cmd.exe /c "msg * /server:$Target `"$msgText`" 2>&1"

    if ($LASTEXITCODE -eq 0 -or [string]::IsNullOrWhiteSpace($msgOutput)) {
        Write-Host "  > [OK] Notification delivered."
    } else {
        Write-Host "  > [!] Notification failed (RPC/Firewall block), but file was deployed." -ForegroundColor Yellow
    }

    Write-Host "`n [UHDC] Success: Remap Drives script pushed to $cleanUser on $Target."

    # Audit log
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Pushed RemapDrives.cmd to Desktop ($cleanUser)" -SharedRoot $SharedRoot
        }
    }

} catch {
    Write-Host "`n [UHDC] [!] Error: Failed to push script."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"