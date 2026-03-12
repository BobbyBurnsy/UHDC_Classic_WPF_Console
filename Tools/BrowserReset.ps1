# BrowserReset.ps1
# Resets Chrome and Edge browser profiles for a specific user on a remote machine.
# Backs up bookmarks, terminates browser processes, deletes the AppData profiles 
# (wiping cookies, history, and cache), and restores the bookmarks.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

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

# Validation and fallbacks
if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] Browser profile reset utility"
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

# Ensure we have the user from AD box or prompt if missing
if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $TargetUser = [Microsoft.VisualBasic.Interaction]::InputBox("Username was missing from the AD box. Enter target username:", "User Required", "")
    if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }
}

Write-Host " [UHDC] Target set to $TargetUser. Awaiting technician confirmation..."

# GUI safety prompt
Add-Type -AssemblyName Microsoft.VisualBasic
$conf = [Microsoft.VisualBasic.Interaction]::InputBox("WARNING: This will DELETE all Passwords, History, and Cookies for $TargetUser on $Target.`n`nOnly Bookmarks will be preserved.`n`nType 'CONFIRM' to proceed:", "Confirm Browser Reset", "")

if ($conf -ne "CONFIRM") {
    Write-Host " [UHDC] [i] Profile reset aborted by technician."
    return
}

# Setup and backup bookmarks
$localBackup = "C:\UHDC\Backups\BrowserReset_$Target"
if (-not (Test-Path $localBackup)) { New-Item -ItemType Directory -Path $localBackup -Force | Out-Null }

$cRoot = "\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data"
$eRoot = "\\$Target\c$\Users\$TargetUser\AppData\Local\Microsoft\Edge\User Data"

Wait-TrainingStep `
    -Desc "STEP 1: BACKUP BOOKMARKS`n`nWHEN TO USE THIS:`nAlways do this before wiping a browser profile so the user doesn't lose their saved links.`n`nWHAT IT DOES:`nWe use the native 'copy' command over the hidden C$ administrative share to pull the user's Bookmarks file to a safe local backup folder on your machine.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would open File Explorer, navigate to '%LocalAppData%\Google\Chrome\User Data\Default', copy the 'Bookmarks' file, and paste it to the Desktop for safekeeping." `
    -Code "copy `"\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data\Default\Bookmarks`" `"C:\UHDC\Backups\BrowserReset_$Target\Chrome_BM`""

Write-Host " [UHDC] [1/4] Securing user bookmarks..."
if (Test-Path "$cRoot\Default\Bookmarks") { Copy-Item "$cRoot\Default\Bookmarks" "$localBackup\Chrome_BM" -Force }
if (Test-Path "$eRoot\Default\Bookmarks") { Copy-Item "$eRoot\Default\Bookmarks" "$localBackup\Edge_BM" -Force }

# Kill processes
Wait-TrainingStep `
    -Desc "STEP 2: TERMINATE BROWSER PROCESSES`n`nWHEN TO USE THIS:`nWe must forcefully terminate any running instances of Chrome or Edge. If the browser is open (or running in the background), Windows will lock the AppData files and prevent us from deleting them.`n`nWHAT IT DOES:`nWe use PsExec to run the native 'taskkill' command on the target PC. The '/F' switch forces the kill, '/IM' targets the image name, and '/T' kills any child processes.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would press Ctrl+Shift+Esc to open Task Manager, locate all 'Google Chrome' and 'Microsoft Edge' processes, right-click them, and select 'End task'." `
    -Code "psexec.exe \\$Target -s taskkill /F /IM chrome.exe /IM msedge.exe /T"

Write-Host " [UHDC] [2/4] Terminating active browser processes..."

$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (Test-Path $psExecPath) {
    Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s taskkill /F /IM chrome.exe /IM msedge.exe /T" -Wait -NoNewWindow
} else {
    Write-Host " [UHDC] [!] Error: psexec.exe not found at $psExecPath"
    Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
}

# Delete AppData folders
Wait-TrainingStep `
    -Desc "STEP 3: PURGE CORRUPTED PROFILES`n`nWHEN TO USE THIS:`nUse this when a browser is crashing on launch, extensions are hijacked, or pages refuse to load properly.`n`nWHAT IT DOES:`nWe use the native 'rd' (remove directory) command over the C$ share to permanently delete the entire 'User Data' directory for both browsers. This wipes the corrupted cache, cookies, history, and extensions.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would navigate to '%LocalAppData%\Google\Chrome\' and permanently delete the 'User Data' folder. You would then repeat this for '%LocalAppData%\Microsoft\Edge\'." `
    -Code "rd /s /q `"\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data`""

Write-Host " [UHDC] [3/4] Purging corrupted AppData profiles..."
if (Test-Path $cRoot) { Remove-Item $cRoot -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $eRoot) { Remove-Item $eRoot -Recurse -Force -ErrorAction SilentlyContinue }

# Restore bookmarks
Wait-TrainingStep `
    -Desc "STEP 4: RESTORE BOOKMARKS`n`nWHEN TO USE THIS:`nWe need to put the bookmarks back before the user opens the browser again.`n`nWHAT IT DOES:`nWe use the native 'mkdir' command to recreate the 'Default' profile directory structure, and then use 'copy' to push the backed-up Bookmarks file back into place.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would open Chrome once to let it automatically recreate the default folders, close the browser, and then copy the saved 'Bookmarks' file from the Desktop back into the 'Default' folder." `
    -Code "mkdir `"\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data\Default`"`ncopy `"C:\UHDC\Backups\BrowserReset_$Target\Chrome_BM`" `"\\$Target\...\Default\Bookmarks`""

Write-Host " [UHDC] [4/4] Restoring bookmarks to fresh profile structure..."
if (Test-Path "$localBackup\Chrome_BM") {
    New-Item -ItemType Directory -Path "$cRoot\Default" -Force | Out-Null
    Copy-Item "$localBackup\Chrome_BM" "$cRoot\Default\Bookmarks" -Force
}
if (Test-Path "$localBackup\Edge_BM") {
    New-Item -ItemType Directory -Path "$eRoot\Default" -Force | Out-Null
    Copy-Item "$localBackup\Edge_BM" "$eRoot\Default\Bookmarks" -Force
}

Write-Host "`n [UHDC] Success: $TargetUser's browsers have been successfully reset on $Target."

# Audit log
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action "Browser Profile Reset executed for user: $TargetUser" -SharedRoot $SharedRoot
    }
} else {
    Write-Host " [UHDC] [i] Audit log skipped (No SharedRoot mapped)." -ForegroundColor Yellow
}

Write-Host "========================================================`n"