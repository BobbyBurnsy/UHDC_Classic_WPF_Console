# SmartUserSearch.ps1
# Queries Active Directory for account details, or accepts a Computer name
# to cross-reference the central UserHistory.json database.
# Uses AES-256 encryption to read the sanitized database.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash,

    [Parameter(Mandatory=$false)]
    [string]$ThemeB64
)

# AES-256 encryption engine
# Static Key and IV for internal tool encryption
$global:UHDCKey = [byte[]](0x5A, 0x2B, 0x3C, 0x4D, 0x5E, 0x6F, 0x7A, 0x8B, 0x9C, 0xAD, 0xBE, 0xCF, 0xD0, 0xE1, 0xF2, 0x03, 0x14, 0x25, 0x36, 0x47, 0x58, 0x69, 0x7A, 0x8B, 0x9C, 0xAD, 0xBE, 0xCF, 0xD0, 0xE1, 0xF2, 0x03)
$global:UHDCIV  = [byte[]](0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10)

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

# Training mode helper
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

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
        } else {
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found." -ForegroundColor Red
            return
        }
    } catch { return }
}

if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Write-Host " [UHDC] [!] Error: No target provided. Please enter a username or PC name."
    return
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"

# 1. Generate history report
$userHistory = @()
$computerHistory = @()
$dbStatus = "OK"

Wait-TrainingStep `
    -Desc "STEP 1: CORRELATE USER TO COMPUTER`n`nWHEN TO USE THIS:`nThis is the first step in any remote support scenario. A user calls in with an issue, but they don't know their computer name, making it impossible to remote in or push fixes.`n`nWHAT IT DOES:`nWe parse the central 'UserHistory.json' database. Because the database is encrypted to protect PII, we decrypt the entries in memory and check if your input matches a known username or PC name. If it matches, we pull the data and use a special GUI tag to automatically fill the 'Target PC' boxes on the right side of the console.`n`nIN-PERSON EQUIVALENT:`nWithout a database, you would have to ask the user for their PC name, or use PsExec to query a suspected PC to see if they are logged into it." `
    -Code "psexec.exe \\TARGET-PC quser"

if (Test-Path $HistoryFile) {
    $fItem = Get-Item $HistoryFile
    if ($fItem.Length -lt 100) {
        $dbStatus = "EMPTY"
    } else {
        try {
            $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json
            if ($raw -isnot [System.Array]) { $raw = @($raw) }

            $seenPC = @{}
            $seenUser = @{}

            foreach ($entry in $raw) {
                # Decrypt the stored values
                $decryptedUser = Unprotect-UHDCData $entry.User
                $decryptedPC   = Unprotect-UHDCData $entry.Computer

                # Check if the input is a User
                if ($decryptedUser.Trim() -eq $TargetUser.Trim()) {
                    if (-not $seenPC.ContainsKey($decryptedPC)) {
                        $entry.Computer = $decryptedPC # Swap encrypted for plain text for display
                        $userHistory += $entry
                        $seenPC[$decryptedPC] = $true
                    }
                }

                # Check if the input is a Computer
                if ($decryptedPC.Trim() -match $TargetUser.Trim()) {
                    if (-not $seenUser.ContainsKey($decryptedUser)) {
                        $entry.User = $decryptedUser # Swap encrypted for plain text for display
                        $entry.Computer = $decryptedPC
                        $computerHistory += $entry
                        $seenUser[$decryptedUser] = $true
                    }
                }
            }
        } catch { $dbStatus = "ERROR READING DB" }
    }
} else {
    $dbStatus = "NO FILE"
}

# 2. Active Directory query
$adObj = $null

Wait-TrainingStep `
    -Desc "STEP 2: QUERY AD ACCOUNT STATUS`n`nWHEN TO USE THIS:`nUse this to instantly verify if an account is locked out, disabled, or if their password is about to expire. It also checks if they have the correct security groups (like VPN or Admin access).`n`nWHAT IT DOES:`nWe query Active Directory to pull the account details, calculate their password expiration date based on the domain policy, and list their security groups.`n`nIN-PERSON EQUIVALENT:`nYou can pull all of this information natively using the built-in 'net user' command in the Windows Command Prompt." `
    -Code "net user $TargetUser /domain"

try {
    # If this fails, the script assumes the input is a Computer Name
    $adObj = Get-ADUser -Identity $TargetUser -Properties Office, Title, Department, EmailAddress, PasswordLastSet, LastLogonDate, LockedOut, Enabled, MemberOf, PasswordNeverExpires -ErrorAction Stop
} catch {}

# 3. Output generation

if ($adObj) {
    # Output AD user report
    $expiryDate = "N/A"; $daysLeftStr = "N/A"

    if ($adObj.PasswordNeverExpires) {
        $expiryDate = "Never (Exempt)"; $daysLeftStr = "Infinite"
    } else {
        try {
            $policy = Get-ADDefaultDomainPasswordPolicy
            $maxAge = $policy.MaxPasswordAge.Days
            if ($adObj.PasswordLastSet) {
                $exp = $adObj.PasswordLastSet.AddDays($maxAge)
                $expiryDate = $exp.ToString("MM/dd/yyyy HH:mm")
                $span = New-TimeSpan -Start (Get-Date) -End $exp
                $daysLeft = $span.Days

                if ($daysLeft -lt 0) {
                    $daysLeftStr = "!!! EXPIRED ($([math]::Abs($daysLeft)) days ago) !!!"
                } elseif ($daysLeft -le 3) {
                    $daysLeftStr = "!!! $daysLeft (EXPIRING SOON) !!!"
                } else {
                    $daysLeftStr = "$daysLeft"
                }
            }
        } catch { $expiryDate = "Unknown" }
    }

    Write-Host "`n========================================================"
    Write-Host " [UHDC] Account report: $($adObj.SamAccountName)"
    Write-Host "========================================================"

    Write-Host " Name:       $($adObj.Name)"
    Write-Host " Title:      $($adObj.Title)"
    Write-Host " Dept:       $($adObj.Department)"
    Write-Host " Email:      $($adObj.EmailAddress)"
    Write-Host " Office:     $($adObj.Office)"

    Write-Host " Status:     " -NoNewline
    if ($adObj.Enabled) { Write-Host "Active" } else { Write-Host "DISABLED" }

    Write-Host " Locked:     " -NoNewline
    if ($adObj.LockedOut) { Write-Host "YES (LOCKED)" } else { Write-Host "No" }

    Write-Host "`n--- Key access groups ---"
    if ($adObj.MemberOf) {
        $allGroups = $adObj.MemberOf | ForEach-Object { ($_ -split ",")[0].Replace("CN=","") } | Sort-Object
        $keywords = "M365|Airwatch|VPN|Admin|Polaris"
        $shownGroups = $allGroups | Where-Object { $_ -match $keywords }
        $hiddenCount = $allGroups.Count - $shownGroups.Count

        if ($shownGroups) {
            foreach ($g in $shownGroups) { Write-Host " - $g" }
        } else {
            Write-Host " (No key groups found)"
        }
        if ($hiddenCount -gt 0) { Write-Host " ...plus $hiddenCount other standard groups." }
    } else { Write-Host " (No groups found)" }

    Write-Host "`n--- Password & logon ---"
    Write-Host " Password set:  $($adObj.PasswordLastSet)"
    Write-Host " Last logon:    $($adObj.LastLogonDate)"
    Write-Host " Days to expiry: $daysLeftStr"

    Write-Host "`n--- Known locations ---"

    if ($dbStatus -ne "OK") {
         Write-Host " [UHDC] [!] Database issue: $dbStatus"
    } elseif ($userHistory.Count -gt 0) {
        $i = 1
        foreach ($loc in $userHistory) {
            Write-Host " [$i] $($loc.Computer) " -NoNewline
            $seenTime = if ($loc.LastSeen) { $loc.LastSeen } else { "Unknown" }
            Write-Host "(Seen: $seenTime)"
            $i++
        }

        # Update GUI target
        Write-Host "`n[GUI:UPDATE_TARGET:$($userHistory[0].Computer)]"

    } else {
        Write-Host " (No history found)"
    }
    Write-Host "`n========================================================`n"

} elseif ($computerHistory.Count -gt 0) {
    # Output computer history report
    Write-Host "`n========================================================"
    Write-Host " [UHDC] Device history report"
    Write-Host "========================================================"
    Write-Host " Target PC: $($computerHistory[0].Computer)"
    Write-Host " AD Profile: (Is a device)"

    Write-Host "`n--- Known users on this device ---"
    $i = 1
    foreach ($loc in $computerHistory) {
        Write-Host " [$i] $($loc.User) " -NoNewline
        $seenTime = if ($loc.LastSeen) { $loc.LastSeen } else { "Unknown" }
        Write-Host "(Seen: $seenTime)"
        $i++
    }

    # Update GUI target
    Write-Host "`n[GUI:UPDATE_TARGET:$($computerHistory[0].Computer)]"
    Write-Host "`n========================================================`n"

} else {
    # No matches found
    Write-Host "`n========================================================"
    Write-Host " [UHDC] Search result: $TargetUser"
    Write-Host "========================================================"
    Write-Host " [!] No matching user found in Active Directory."
    Write-Host " [!] No matching computer or user found in UserHistory.json."
    Write-Host "`n========================================================`n"
}