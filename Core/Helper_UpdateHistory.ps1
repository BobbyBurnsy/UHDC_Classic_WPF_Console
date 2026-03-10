# Helper_UpdateHistory.ps1
# Manually adds or updates a specific User-to-PC mapping in the central
# UserHistory.json database. Triggered by the GUI's "Add PC" button.

param(
    [Parameter(Mandatory=$false)]
    [string]$User,

    [Parameter(Mandatory=$false)]
    [string]$Computer,

    [Parameter(Mandatory=$false)]
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
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host " [UHDC] [!] Error: Failed to resolve SharedRoot." -ForegroundColor Red
        return
    }
}

if ([string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Computer)) {
    Write-Host " [UHDC] [!] Error: User and Computer must be provided." -ForegroundColor Red
    return
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

# --- 1. Read Existing Database ---
$db = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    # Only backup if the file is healthy (>100 bytes).
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    try {
        $content = Get-Content $HistoryFile -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $raw = $content | ConvertFrom-Json
            if ($raw -isnot [System.Array]) { $raw = @($raw) }

            foreach ($entry in $raw) {
                if ($entry.User -and $entry.Computer) {
                    $key = "$($entry.User)-$($entry.Computer)"
                    $db[$key] = $entry
                }
            }
            $initialCount = $db.Count
        }
    } catch {
        Write-Host "`n [UHDC] [!] CRITICAL: JSON Parsing failed. Aborting to prevent data wipe." -ForegroundColor Red
        return
    }
}

# --- 2. Add or Update Record ---
$scanKey = "$User-$Computer"
$timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")

if ($db.ContainsKey($scanKey)) {
    $db[$scanKey].LastSeen = $timeStamp
    $db[$scanKey].Source   = "UHDC-Update"
} else {
    $db[$scanKey] = [PSCustomObject]@{
        User     = $User
        Computer = $Computer
        LastSeen = $timeStamp
        Source   = "UHDC-Update"
    }
}

# --- 3. Save Database ---
if ($db.Count -ge $initialCount -and $db.Count -gt 0) {
    try {
        $finalList = @($db.Values | Sort-Object User)

        # Convert to JSON in memory first
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

        # Single-Item Array Protection
        if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            throw "Generated JSON string was completely empty."
        }

        # Write to a temporary file
        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop

        # Swap temporary file with live file
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

    } catch {
        Write-Host "`n [UHDC] [!] ERROR SAVING: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "`n [UHDC] [!] PROTECTION TRIGGERED: Attempted to save fewer records than loaded." -ForegroundColor Red
    Write-Host "      Operation aborted to protect database." -ForegroundColor Yellow
}
