# GlobalNetworkMap.ps1
# Compiles a master map of User-to-Computer relationships.
# Scans AD for enabled workstations, pings them, and queries the logged-on user.
# ZERO-TRUST EDITION: Uses AES-256 Encryption to protect PII in the database.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$DummyTarget,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
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
        # If it fails to decrypt, it might be legacy plain-text. Return as-is.
        return $EncryptedText 
    }
}

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
        } else {
            Write-Host " [!] FATAL: Could not locate config.json."
            return
        }
    } catch { return }
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

Write-Host "========================================="
Write-Host "       [UHDC] GLOBAL NETWORK MAPPER      "
Write-Host "=========================================`n"
Write-Host " [UHDC] [!] Scope limited to: Active Windows 10/11 Workstations"
Write-Host " [UHDC] [!] Mode: Additive (Preserves History)"
Write-Host " [UHDC] [!] Security: AES-256 PII Encryption ENABLED"

# --- 1. Load Existing Database ---
$masterDB = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    Write-Host "`n [UHDC] [1/3] Loading Database..."

    # Only backup if the file is healthy (>100 bytes).
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    Wait-TrainingStep `
        -Desc "STEP 1: LOAD EXISTING DATABASE & SANITIZE`n`nWHEN TO USE THIS:`nThis tool is restricted to Master Admins and is typically run twice a week to build the global asset map.`n`nWHAT IT DOES:`nWe load the central 'UserHistory.json' database into memory. As part of our Zero-Trust architecture, if we detect any legacy plain-text usernames or PC names in the file, we instantly convert them to AES-256 encrypted strings in memory so they are sanitized upon the next save.`n`nIN-PERSON EQUIVALENT:`nTaking an old spreadsheet full of employee names, locking it inside a physical safe, and throwing away the original document." `
        -Code "`$raw = Get-Content `$HistoryFile -Raw | ConvertFrom-Json`nforeach (`$entry in `$raw) {`n    `$decUser = Unprotect-UHDCData `$entry.User`n    `$entry.User = Protect-UHDCData `$decUser`n    `$masterDB[`"`$(`$entry.User)-`$(`$entry.Computer)`"] = `$entry`n}"

    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        foreach ($entry in $raw) {
            if ($entry.User -and $entry.Computer) {
                # Decrypt to get the raw value (handles both legacy plain-text and existing encrypted data)
                $decUser = Unprotect-UHDCData $entry.User
                $decPC   = Unprotect-UHDCData $entry.Computer

                # Re-encrypt to ensure everything is uniformly protected
                $encUser = Protect-UHDCData $decUser
                $encPC   = Protect-UHDCData $decPC

                $entry.User = $encUser
                $entry.Computer = $encPC

                $uniqueKey = "$encUser-$encPC"
                $masterDB[$uniqueKey] = $entry
            }
        }
        $initialCount = $masterDB.Count
        Write-Host " [UHDC] [OK] Loaded $initialCount historical entries."
    } catch {
        Write-Host " [UHDC] [FATAL] Could not read existing history. Aborting to protect data."
        return
    }
}

# --- 2. Get Computers ---
Write-Host "`n [UHDC] [2/3] Fetching Computer List from AD..."

Wait-TrainingStep `
    -Desc "STEP 2: QUERY ACTIVE DIRECTORY FOR WORKSTATIONS`n`nWHAT IT DOES:`nWe are querying Active Directory for all enabled computer objects running Windows 10 or Windows 11. This LDAP filter ensures we only target active client endpoints, filtering out servers, disabled PCs, and stale objects so we don't waste time scanning them.`n`nNATIVE WINDOWS EQUIVALENT:`nOpening Active Directory Users and Computers (ADUC), creating a custom saved query for 'Operating System starts with Windows 10', and exporting the list to a CSV file to know which desks to check." `
    -Code "`$filter = `"Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')`"`n`$computers = Get-ADComputer -Filter `$filter | Select-Object -ExpandProperty Name"

try {
    $filter = "Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')"
    $computers = Get-ADComputer -Filter $filter -Properties OperatingSystem | Select-Object -ExpandProperty Name
} catch {
    Write-Host " [UHDC] [ERROR] AD Query Failed."
    return
}

$total = if ($computers) { $computers.Count } else { 0 }

if ($total -eq 0) {
    Write-Host " [UHDC] [!] No computers found matching scope."
    return
}
Write-Host " [UHDC] [OK] Found $total target workstations."
Start-Sleep 2

# --- 3. Scan Loop ---
$count = 0
$newFinds = 0
$updatedFinds = 0

Wait-TrainingStep `
    -Desc "STEP 3: PING SWEEP & WMI USER QUERY`n`nWHAT IT DOES:`nFor every computer found in AD, we send a fast ping. If it responds, we use WMI to query the 'Win32_ComputerSystem' class to see who is logged in. We then immediately encrypt both the username and the PC name before storing it in our memory dictionary to prevent PII leakage.`n`nNATIVE WINDOWS EQUIVALENT:`nWalking the floor, going desk to desk, wiggling the mouse on every active computer, and writing down the username displayed on the lock screen." `
    -Code "`$ping = New-Object System.Net.NetworkInformation.Ping`nif (`$ping.Send(`$pc, 500).Status -eq 'Success') {`n    `$compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName `$pc`n    `$encUser = Protect-UHDCData (`$compInfo.UserName -split `"\\`")[-1]`n}"

$pingSender = New-Object System.Net.NetworkInformation.Ping

foreach ($pc in $computers) {
    $count++
    $percent = "{0:N0}" -f (($count / $total) * 100)

    $isOnline = $false
    try {
        if ($pingSender.Send($pc, 500).Status -eq "Success") { $isOnline = $true }
    } catch {}

    if ($isOnline) {
        try {
            $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction Stop
            $rawUser = $compInfo.UserName

            if ($rawUser) {
                $cleanUser = ($rawUser -split "\\")[-1].Trim()

                # Encrypt the data for storage
                $encUser = Protect-UHDCData $cleanUser
                $encPC   = Protect-UHDCData $pc

                $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")
                $scanKey = "$encUser-$encPC"

                if ($masterDB.ContainsKey($scanKey)) {
                    $masterDB[$scanKey].LastSeen = $timeStamp
                    $updatedFinds++
                }
                else {
                    $masterDB[$scanKey] = [PSCustomObject]@{
                        User     = $encUser
                        Computer = $encPC
                        LastSeen = $timeStamp
                        Source   = "GlobalMap"
                    }
                    $newFinds++

                    # We display the plain text in the console for the admin, but only save the encrypted string
                    Write-Host " [UHDC] [$percent%] NEW: $cleanUser found on $pc"
                }
            }
        } catch {}
    }

    # Auto-Save (Every 50 items)
    if ($count % 50 -eq 0) {
        if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
            try {
                $finalList = @($masterDB.Values | Sort-Object User)
                $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

                if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
                    $jsonOutput = "[$jsonOutput]"
                }

                if (-not [string]::IsNullOrWhiteSpace($jsonOutput)) {
                    Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
                    Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop
                }
            } catch {}
        }
    }
}

# --- 4. Final Save ---
Write-Host "`n [UHDC] [3/3] Finalizing Database..."

Wait-TrainingStep `
    -Desc "STEP 4: DATABASE SAVE`n`nWHAT IT DOES:`nWe are converting our updated memory dictionary back into JSON format. To prevent database corruption if the script crashes or the network drops mid-save, we write the data to a '.tmp' file first, and then instantly swap it with the live 'UserHistory.json' file.`n`nNATIVE WINDOWS EQUIVALENT:`nSaving your updated Excel tracker as 'Tracker_New.xlsx', deleting the old 'Tracker.xlsx', and renaming the new file to replace it." `
    -Code "Set-Content -Path `$TempFile -Value `$jsonOutput -Force`nMove-Item -Path `$TempFile -Destination `$HistoryFile -Force"

if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
    try {
        $finalList = @($masterDB.Values | Sort-Object User)
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

        if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) { throw "Generated JSON string was completely empty." }

        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

        Write-Host " [UHDC SUCCESS] Map Complete!"
        Write-Host "             Total DB Entries: $($masterDB.Count)"
        Write-Host "             New Connections:  $newFinds"
        Write-Host "             Refreshed:        $updatedFinds"
    } catch {
        Write-Host " [UHDC] [ERROR] Could not save file: $($_.Exception.Message)"
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host " [UHDC] [PROTECTION] Scan resulted in data loss ($($masterDB.Count) vs $initialCount)."
    Write-Host "               Save aborted. Restoring backup..."
    Copy-Item $BackupFile $HistoryFile -Force
}