# Helper_RemoveHistory.ps1
# Safely manages the central UserHistory.json database by finding and deleting
# a specific User-to-PC mapping. Used by the GUI's "Rem PC" button.
# ZERO-TRUST EDITION: Uses AES-256 Encryption to protect PII in the database.

param(
    [Parameter(Mandatory=$false)]
    [string]$User,

    [Parameter(Mandatory=$false)]
    [string]$Computer,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot
)

# --- PII SANITIZATION: AES-256 Encryption Engine ---
$global:UHDCKey = [byte[]](0x5A, 0x2B, 0x3C, 0x4D, 0x5E, 0x6F, 0x7A, 0x8B, 0x9C, 0xAD, 0xBE, 0xCF, 0xD0, 0xE1, 0xF2, 0x03, 0x14, 0x25, 0x36, 0x47, 0x58, 0x69, 0x7A, 0x8B, 0x9C, 0xAD, 0xBE, 0xCF, 0xD0, 0xE1, 0xF2, 0x03)
$global:UHDCIV  = [byte[]](0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10)

function Protect-UHDCData ([string]$PlainText) {
    if ([string]::IsNullOrWhiteSpace($PlainText)) { return $PlainText }
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $global:UHDCKey
    $aes.IV = $global:UHDCIV
    $encryptor = $aes.CreateEncryptor()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encrypted = $encryptor.TransformFinalBlock($bytes, 0, $bytes.Length)
    return [Convert]::ToBase64String($encrypted)
}

function Unprotect-UHDCData ([string]$EncryptedText) {
    if ([string]::IsNullOrWhiteSpace($EncryptedText)) { return $EncryptedText }
    try {
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $global:UHDCKey
        $aes.IV = $global:UHDCIV
        $decryptor = $aes.CreateDecryptor()
        $bytes = [Convert]::FromBase64String($EncryptedText)
        $decrypted = $decryptor.TransformFinalBlock($bytes, 0, $bytes.Length)
        return [System.Text.Encoding]::UTF8.GetString($decrypted)
    } catch { 
        return $EncryptedText 
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
        } else {
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host " [UHDC] [!] Error: Failed to resolve SharedRoot." -ForegroundColor Red
        return
    }
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

# --- 1. Read Existing Database ---
$db = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
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
                    # Decrypt and re-encrypt to ensure database is fully sanitized
                    $decUser = Unprotect-UHDCData $entry.User
                    $decPC   = Unprotect-UHDCData $entry.Computer

                    $encUser = Protect-UHDCData $decUser
                    $encPC   = Protect-UHDCData $decPC

                    $entry.User = $encUser
                    $entry.Computer = $encPC

                    $key = "$encUser-$encPC"
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

# --- 2. Remove Target Record ---
$targetEncUser = Protect-UHDCData $User
$targetEncPC   = Protect-UHDCData $Computer
$scanKey = "$targetEncUser-$targetEncPC"

if ($db.ContainsKey($scanKey)) {
    $db.Remove($scanKey)
    $expectedCount = $initialCount - 1
    Write-Host "  > [UHDC] Target record identified and removed from memory."
} else {
    Write-Host " [UHDC] [i] Record not found in database. Nothing removed." -ForegroundColor Yellow
    return
}

# --- 3. Save Database ---
if ($db.Count -eq $expectedCount -and $initialCount -gt 0) {
    try {
        $finalList = @($db.Values | Sort-Object User)

        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

        if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            throw "Generated JSON string was completely empty."
        }

        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

    } catch {
        Write-Host "`n [UHDC] [!] ERROR SAVING: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "`n [UHDC] [!] PROTECTION TRIGGERED: Record count mismatch. Aborting save to protect database." -ForegroundColor Red
}