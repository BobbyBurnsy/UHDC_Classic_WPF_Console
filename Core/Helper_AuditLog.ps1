# Helper_AuditLog.ps1
# Central logging engine for the UHDC platform.
# Appends a timestamped record to the ConsoleAudit.csv file.

param(
    [string]$Target,
    [string]$Action,
    [string]$Tech = $env:USERNAME,
    [string]$SharedRoot
)

# --- Load Configuration ---
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        } else {
            return 
        }
    } catch {
        return
    }
}

# --- Write to CSV Log ---
$LogFolder = Join-Path -Path $SharedRoot -ChildPath "Logs"
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }

$LogFile = Join-Path -Path $LogFolder -ChildPath "ConsoleAudit.csv"

try {
    $newEntry = [PSCustomObject]@{ 
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Tech      = $Tech
        Target    = if ($Target) { $Target } else { "N/A" }
        Action    = $Action 
    }

    $newEntry | Export-Csv -Path $LogFile -Append -NoTypeInformation -Force
} catch {
    Write-Host " [UHDC] [!] Failed to write to audit log: $($_.Exception.Message)" -ForegroundColor Red
}
