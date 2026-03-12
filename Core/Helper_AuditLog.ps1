# Helper_AuditLog.ps1
# Central logging engine for the UHDC platform.
# Appends a timestamped, pseudonymized record to the ConsoleAudit.csv file.
# NOTE: We intentionally do NOT encrypt this file to maintain SIEM/Excel compatibility.

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

# --- PSEUDONYMIZATION: Resolve Nickname ---
# Protects the technician's AD username from appearing in plain text logs.
$ResolvedTech = $Tech
if ($Tech -eq $env:USERNAME) {
    try {
        $UsersFile = Join-Path -Path $SharedRoot -ChildPath "Core\users.json"
        if (Test-Path $UsersFile) {
            $prefs = Get-Content $UsersFile -Raw | ConvertFrom-Json
            if ($null -ne $prefs.$env:USERNAME -and $null -ne $prefs.$env:USERNAME.Nickname) {
                $ResolvedTech = $prefs.$env:USERNAME.Nickname
            } else {
                $ResolvedTech = "Tech_Masked"
            }
        } else {
            $ResolvedTech = "Tech_Masked"
        }
    } catch {
        $ResolvedTech = "Tech_Masked"
    }
}

# --- PII SANITIZATION: Mask Target ---
function Mask-PII ([string]$InputString) {
    if ([string]::IsNullOrWhiteSpace($InputString)) { return "N/A" }

    # Basic masking: If it looks like a username (no dots, short), mask the middle.
    if ($InputString -notmatch "\." -and $InputString.Length -gt 3) {
        $first = $InputString.Substring(0,1)
        $last = $InputString.Substring($InputString.Length - 1, 1)
        return "$first***$last"
    }
    return $InputString
}

# --- Write to CSV Log ---
$LogFolder = Join-Path -Path $SharedRoot -ChildPath "Logs"
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }

$LogFile = Join-Path -Path $LogFolder -ChildPath "ConsoleAudit.csv"

try {
    $newEntry = [PSCustomObject]@{ 
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Tech      = $ResolvedTech
        Target    = if ($Target) { Mask-PII $Target } else { "N/A" }
        Action    = $Action 
    }

    # Export as plain CSV for easy ingestion by external auditing tools
    $newEntry | Export-Csv -Path $LogFile -Append -NoTypeInformation -Force
} catch {
    Write-Host " [UHDC] [!] Failed to write to audit log: $($_.Exception.Message)" -ForegroundColor Red
}