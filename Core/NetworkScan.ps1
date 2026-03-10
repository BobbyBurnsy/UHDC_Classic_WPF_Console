# NetworkScan.ps1
# Locates a specific user on the network.
# Resolves AD identity, checks UserHistory.json, and falls back to an OU/Office scan.
# Updates the console target field and history database upon success.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$TargetUser,

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

if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Write-Host " [UHDC] [!] Error: No username provided. Please enter a username in the GUI target box."
    return
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
    } catch { return }
}

# --- Environment Setup ---
$CoreFolder   = Join-Path -Path $SharedRoot -ChildPath "Core"
$HistoryFile  = Join-Path -Path $CoreFolder -ChildPath "UserHistory.json"
$UpdateHelper = Join-Path -Path $CoreFolder -ChildPath "Helper_UpdateHistory.ps1"

Write-Host "========================================="
Write-Host "       [UHDC] FIND USER ON NETWORK       "
Write-Host "=========================================`n"
Write-Host " [UHDC] [!] Standard Scan (v9 Logic)"
Write-Host " [UHDC] [!] Global Scanning: DISABLED"

# --- 1. Resolve Identity ---
$ResolvedUser = $null
$office = $null
$dn = $null

Write-Host " [UHDC] Resolving identity for '$TargetUser'..."

Wait-TrainingStep `
    -Desc "STEP 1: RESOLVE AD IDENTITY`n`nWHEN TO USE THIS:`nThis happens automatically when you click 'Net Scan'. It ensures we are searching for the exact, correct user account before we start sweeping the network.`n`nWHAT IT DOES:`nWe query Active Directory for the provided username to retrieve their exact 'SamAccountName', 'Office' code, and 'DistinguishedName' (OU path). We will use this data to narrow down our search radius later.`n`nIN-PERSON EQUIVALENT:`nOpening ADUC, searching for the user, and checking the 'Organization' tab to see what building or department they work in so you know which floor to walk to." `
    -Code "`$exact = Get-ADUser -Identity `$TargetUser -Properties Office, DistinguishedName`n`$ResolvedUser = `$exact.SamAccountName"

try {
    $exact = Get-ADUser -Identity $TargetUser -Properties Office, DistinguishedName -ErrorAction SilentlyContinue
    if ($exact) {
        $ResolvedUser = $exact.SamAccountName
        $office = $exact.Office
        $dn = $exact.DistinguishedName
        Write-Host " [UHDC] [OK] Resolved: $($exact.Name)"
    }
} catch {}

if (-not $ResolvedUser) {
    Write-Host "`n [UHDC] [!] Ambiguous or invalid username: '$TargetUser'"
    Write-Host " [UHDC] [i] Please use the '1. AD User Lookup' button first to resolve the exact user."
    return
}

$foundPC = $null

# --- 2. Check History ---
if (Test-Path $HistoryFile) {
    Write-Host "`n [UHDC] Checking history for $ResolvedUser..."

    Wait-TrainingStep `
        -Desc "STEP 2: CHECK HISTORICAL DATABASE`n`nWHEN TO USE THIS:`nBefore we waste time scanning hundreds of computers, we check if we already know where this user usually sits.`n`nWHAT IT DOES:`nWe read the central 'UserHistory.json' file to find the last known PC this user logged into. We then send a quick WMI query to that specific PC to see if they are still there. If they are, the scan finishes instantly.`n`nIN-PERSON EQUIVALENT:`nChecking your personal notes or asking a coworker, 'Hey, doesn't John usually sit at desk 4B?' and walking straight there first." `
        -Code "`$match = `$raw | Where-Object { `$_.User -eq `$ResolvedUser } | Sort-Object LastSeen -Descending | Select-Object -First 1`n`$check = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName `$match.Computer"

    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        $match = $raw | Where-Object { $_.User -eq $ResolvedUser } | Sort-Object LastSeen -Descending | Select-Object -First 1

        if ($match) {
            $hPC = $match.Computer
            Write-Host "   Checking last known: $hPC..." -NoNewline

            $pingSender = New-Object System.Net.NetworkInformation.Ping
            $isOnline = $false
            try {
                if ($pingSender.Send($hPC, 500).Status -eq "Success") { $isOnline = $true }
            } catch {}

            if ($isOnline) {
                try {
                    $check = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $hPC -ErrorAction Stop
                    $rawUser = $check.UserName

                    if ($rawUser -and $rawUser -match $ResolvedUser) {
                        Write-Host " [MATCH] Confirmed!"
                        $foundPC = $hPC
                        try {
                            if (Test-Path $UpdateHelper) {
                                & $UpdateHelper -User $ResolvedUser -Computer $hPC -SharedRoot $SharedRoot
                            }
                        } catch {}
                    } else {
                        Write-Host " (User not logged in)"
                    }
                } catch {
                    Write-Host " (WMI Blocked)"
                }
            } else {
                Write-Host " (Offline)"
            }
        }
    } catch {}
}

# --- 3. Network Scan ---
if (-not $foundPC) {
    $searchBase = $null
    $filter = $null

    Wait-TrainingStep `
        -Desc "STEP 3: CONTEXT-AWARE TARGETING`n`nWHEN TO USE THIS:`nIf the user isn't at their usual desk (or they are a new hire with no history), we need to scan the network. But scanning 5,000 PCs takes too long.`n`nWHAT IT DOES:`nWe use the 'Office' attribute or the Organizational Unit (OU) we gathered in Step 1 to pivot our search. If the user is in the 'Accounting' OU, we only pull a list of computers that are also in the 'Accounting' OU. This reduces our scan target from thousands of PCs down to just a few dozen.`n`nIN-PERSON EQUIVALENT:`nKnowing the user works in Accounting, so you only walk the floor of the Accounting department looking for them, rather than checking every desk in the entire building." `
        -Code "if (`$dn -match `"OU=Users,(.+)`$`") {`n    `$searchBase = `"OU=Computers,`$(`$matches[1])`"`n    `$computers = Get-ADComputer -Filter * -SearchBase `$searchBase`n}"

    if (-not [string]::IsNullOrWhiteSpace($office)) {
        Write-Host "`n [UHDC] [!] Office Code Detected: '$office'. Narrowing scan..."
        $filter = "$office*"
    } elseif ($dn -match "OU=Users,(.+)$") {
        $rootDN = $matches[1]
        $searchBase = "OU=Computers,$rootDN"
        Write-Host "`n [UHDC] [!] OU Pivot: Scanning subnet $($searchBase)..."
    } else {
        Write-Host "`n [UHDC] [X] ABORTING: User context (Office/OU) not found."
        Write-Host "      Global Scanning is disabled for performance/safety."
        return
    }

    Write-Host " [UHDC] [!] Gathering computer list..."
    try {
        if ($searchBase) {
            $computers = Get-ADComputer -Filter * -SearchBase $searchBase -ErrorAction Stop | Select-Object -ExpandProperty Name
        } elseif ($filter) {
            $computers = Get-ADComputer -Filter "Name -like '$filter'" -ErrorAction Stop | Select-Object -ExpandProperty Name
        }
    } catch {
        Write-Host " [UHDC] [X] Error fetching computers from context Scope: $($_.Exception.Message)"
        return
    }

    if (-not $computers) {
        Write-Host " [UHDC] [!] No computers found in the target scope."
        return
    }

    $total = $computers.Count
    Write-Host " [UHDC] [!] Scanning $total computers... (This may take a moment)"

    Wait-TrainingStep `
        -Desc "STEP 4: EXECUTE WMI SWEEP`n`nWHAT IT DOES:`nWe iterate through our narrowed list of computers. We send a 500ms ping to see if the PC is turned on. If it is, we use WMI to ask the PC 'Who is logged in right now?'. As soon as we find a match for our target user, we break the loop, update the history database, and send the PC name back to the GUI.`n`nIN-PERSON EQUIVALENT:`nWalking down the row of desks in the Accounting department, wiggling the mouse on every active computer, and reading the lock screen until you find the user you are looking for." `
        -Code "foreach (`$pc in `$computers) {`n    if (`$pingSender.Send(`$pc, 500).Status -eq 'Success') {`n        `$compInfo = Get-CimInstance Win32_ComputerSystem -ComputerName `$pc`n        if (`$compInfo.UserName -match `$ResolvedUser) { break }`n    }`n}"

    $pingSender = New-Object System.Net.NetworkInformation.Ping
    $scannedCount = 0

    :ScanLoop foreach ($pc in $computers) {
        $scannedCount++

        if ($scannedCount % 10 -eq 0) {
            Write-Host -NoNewline "."
        }

        $isOnline = $false
        try {
            if ($pingSender.Send($pc, 500).Status -eq "Success") { $isOnline = $true }
        } catch {}

        if ($isOnline) {
            try {
                $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction Stop
                $rawUser = $compInfo.UserName

                if ($rawUser -and $rawUser -match $ResolvedUser) {
                    Write-Host "`n [UHDC] [MATCH] $pc ($rawUser)"
                    $foundPC = $pc

                    try {
                        if (Test-Path $UpdateHelper) {
                            & $UpdateHelper -User $ResolvedUser -Computer $pc -SharedRoot $SharedRoot
                        }
                    } catch {}

                    [console]::Beep(1000, 100)
                    break ScanLoop
                }
            } catch {}
        }
    }
}

# --- 4. Update GUI ---
if ($foundPC) {
    Write-Host "`n [UHDC SUCCESS] Scan complete. Updating GUI..."
    Write-Host "[GUI:UPDATE_TARGET:$foundPC]"
} else {
    Write-Host "`n [UHDC] [!] Scan exhausted. Login not found for $ResolvedUser."
}
