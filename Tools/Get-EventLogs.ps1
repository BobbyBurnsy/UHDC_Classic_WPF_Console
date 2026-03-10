# Get-EventLogs.ps1
# Remotely queries the System and Application event logs.
# If no keyword is provided, it pulls the last 50 Critical/Error events.
# If a keyword is provided, it deep-scans the last 10,000 events for matches.
# Results are exported to a local CSV in C:\UHDC\Logs and previewed in the console.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$Keyword,

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
Write-Host " [UHDC] REMOTE EVENT LOG DIAGNOSTICS"
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

# --- 2. Setup Export Directory ---
$LocalTemp = "C:\UHDC\Logs"
if (-not (Test-Path $LocalTemp)) {
    New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null
}

$Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$ExportPath = "$LocalTemp\EventLogs_$Target_$Timestamp.csv"

try {
    # --- 3. Query Event Logs ---
    if ([string]::IsNullOrWhiteSpace($Keyword)) {

        Wait-TrainingStep `
            -Desc "STEP 1: QUERY CRITICAL & ERROR LOGS`n`nWHEN TO USE THIS:`nUse this when a user reports unexpected reboots (BSODs), system hangs, or general instability, but doesn't have a specific error code.`n`nWHAT IT DOES:`nWe are using 'Invoke-Command' to run 'Get-WinEvent' directly on the target's CPU. We filter specifically for Level 1 (Critical) and Level 2 (Error) events, pulling the 50 most recent occurrences, and returning them over the network.`n`nIN-PERSON EQUIVALENT:`nOpen Event Viewer (eventvwr.msc), expand 'Windows Logs', select 'System', click 'Filter Current Log' on the right pane, and check the boxes for 'Critical' and 'Error'." `
            -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Get-WinEvent -FilterHashtable @{LogName='System','Application'; Level=1,2} -MaxEvents 50 }"

        Write-Host "  > [1/2] Pulling last 50 Critical/Error logs from System & Application..."

        $logs = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
            try {
                Get-WinEvent -FilterHashtable @{LogName='System','Application'; Level=1,2} -MaxEvents 50 -ErrorAction Stop
            } catch {
                Get-WinEvent -LogName 'System','Application' -MaxEvents 2000 -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Level -eq 1 -or $_.Level -eq 2 } | 
                    Select-Object -First 50
            }
        }
    } else {

        Wait-TrainingStep `
            -Desc "STEP 1: DEEP SCAN FOR KEYWORD`n`nWHEN TO USE THIS:`nUse this when troubleshooting a specific failing application (e.g., 'Outlook', 'Teams') or a specific error code provided by the user.`n`nWHAT IT DOES:`nIn PowerShell 5.1, pulling 10,000 events over the network and filtering them locally will freeze the console. Instead, we use 'Invoke-Command' to force the target PC to pull the 10,000 events, filter them locally using 'Where-Object', and only send the matching results back to us.`n`nIN-PERSON EQUIVALENT:`nOpen Event Viewer (eventvwr.msc), select the 'Application' log, click 'Find...' on the right pane, type your keyword, and click 'Find Next' repeatedly." `
            -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Get-WinEvent -LogName 'System','Application' -MaxEvents 10000 | Where-Object { `$_.Message -match `$using:Keyword -or `$_.ProviderName -match `$using:Keyword } }"

        Write-Host "  > [1/2] Deep searching last 10,000 events for keyword: '$Keyword'..."
        Write-Host "    (Offloading query to target CPU... Please wait...)"

        $logs = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
            Get-WinEvent -LogName 'System','Application' -MaxEvents 10000 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match $using:Keyword -or $_.ProviderName -match $using:Keyword }
        }
    }

    if ($null -ne $logs -and $logs.Count -gt 0) {
        Write-Host "  [UHDC SUCCESS] Found $($logs.Count) matching logs."

        # --- 4. Export and Display ---
        Wait-TrainingStep `
            -Desc "STEP 2: EXPORT AND ANALYZE`n`nWHEN TO USE THIS:`nEvent logs contain massive blocks of text that are difficult to read in a standard console window. Exporting them to a spreadsheet allows for easy sorting, filtering, and sharing with higher-tier support teams.`n`nWHAT IT DOES:`nWe are selecting the most relevant properties (Time, ID, Level, Provider, and Message) and exporting them to a local CSV file. We then automatically open File Explorer to highlight the new file for immediate review.`n`nIN-PERSON EQUIVALENT:`nIn Event Viewer, right-click the filtered log view and select 'Save Filtered Log File As...', save it as a CSV to the Desktop, and open it in Excel." `
            -Code "`$logs | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, LogName, Message | Export-Csv -Path '$ExportPath' -NoTypeInformation`nStart-Process explorer.exe -ArgumentList `"/select,\`"$ExportPath\`"`""

        Write-Host "  > [2/2] Exporting results to CSV..."
        $logs | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, LogName, Message |
                Export-Csv -Path $ExportPath -NoTypeInformation -Force

        Write-Host "  [i] Full results exported to: $ExportPath`n"

        Start-Process explorer.exe -ArgumentList "/select,`"$ExportPath`""

        $consoleLogs = $logs | Select-Object -First 15
        foreach ($log in $consoleLogs) {
            Write-Host "  [$($log.TimeCreated)] [$($log.LevelDisplayName)] $($log.ProviderName)"

            $msg = if ($log.Message) { $log.Message.Replace("`r`n", " ").Replace("`n", " ") } else { "No message data." }
            if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 147) + "..." }
            Write-Host "  > $msg`n"
        }

        if ($logs.Count -gt 15) {
            Write-Host "  [+] ... plus $($logs.Count - 15) more hidden from console. Open the CSV to view them all!" -ForegroundColor Yellow
        }

        # --- Audit Log ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                $actionStr = if ($Keyword) { "Queried Event Logs (Keyword: $Keyword)" } else { "Queried Event Logs (Critical/Error)" }
                & $AuditHelper -Target $Target -Action $actionStr -SharedRoot $SharedRoot
            }
        }

    } else {
        Write-Host "  [UHDC] [i] No matching event logs found."
    }
} catch {
    Write-Host "  [UHDC] [!] ERROR querying Event Logs: $($_.Exception.Message)"
}
