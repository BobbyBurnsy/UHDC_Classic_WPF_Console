# Get-SmartWarranty.ps1
# Queries the target computer's WMI/CIM repository for its Make and Serial Number,
# then automatically opens the correct vendor support/warranty webpage.

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
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] Warranty lookup: $Target"
Write-Host "========================================"

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

# Hardware query
try {
    Write-Host " [UHDC] [i] Querying hardware info..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY HARDWARE INFORMATION`n`nWHEN TO USE THIS:`nUse this when a user reports physical hardware damage (e.g., cracked screen, failing drive, swollen battery) or when preparing to order replacement parts and you need to verify if the device is still covered under the manufacturer's active warranty or accidental damage protection plan.`n`nWHAT IT DOES:`nWe use PsExec to run the native 'wmic' (Windows Management Instrumentation Command-line) utility. We query the motherboard (bios) for its embedded Serial Number/Service Tag, and the system enclosure (computersystem) for the Manufacturer (Make).`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would flip the laptop over and read the tiny printed sticker on the bottom chassis, or open an elevated Command Prompt and type 'wmic bios get serialnumber'." `
        -Code "psexec.exe \\$Target -s cmd /c `"wmic bios get serialnumber & wmic computersystem get manufacturer`""

    $bios = Get-CimInstance -ComputerName $Target -ClassName Win32_BIOS -ErrorAction Stop
    $cs   = Get-CimInstance -ComputerName $Target -ClassName Win32_ComputerSystem -ErrorAction Stop

    $make   = $cs.Manufacturer.Trim()
    $serial = $bios.SerialNumber.Trim()

    Write-Host "  > Make:   $make"
    Write-Host "  > Serial: $serial"

    $url = ""

    if ($make -match "Dell") {
        $url = "https://www.dell.com/support/home/en-us/product-support/servicetag/$serial/overview"
    }
    elseif ($make -match "Lenovo") {
        $url = "https://pcsupport.lenovo.com/us/en/search?query=$serial"
    }
    elseif ($make -match "HP|Hewlett-Packard") {
        $url = "https://support.hp.com/us-en/check-warranty"
    }
    elseif ($make -match "Microsoft") {
        Write-Host "  > [UHDC] Note: Microsoft usually requires a login to view Surface warranties." -ForegroundColor Yellow
        $url = "https://mybusinessservice.surface.com/"
    }

    if ($url) {

        Wait-TrainingStep `
            -Desc "STEP 2: LAUNCH VENDOR WARRANTY PORTAL`n`nWHEN TO USE THIS:`nImmediately after retrieving the serial number to check the exact expiration date and entitlement level (e.g., Next Business Day Onsite vs. Depot Repair).`n`nWHAT IT DOES:`nWe use the retrieved Manufacturer name to automatically determine the correct vendor support portal (Dell, Lenovo, HP, or Microsoft). We then inject the Serial Number directly into the URL and launch it in your local default web browser using the native 'start' command.`n`nIN-PERSON EQUIVALENT:`nYou would open a web browser, search for 'Dell Warranty Check' (or the respective vendor), navigate to their support page, manually type the alphanumeric serial number into the search box, and click Submit." `
            -Code "start `"$url`""

        Write-Host " [UHDC] Success: Opening warranty page in your default browser..."
        Start-Process $url

        # Audit log
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Checked Warranty ($make - Serial: $serial)" -SharedRoot $SharedRoot
            }
        }

    } else {
        Write-Host " [UHDC] [i] Auto-detect failed for vendor: $make"
        Write-Host "      (Serial number $serial is available for manual lookup)"
    }

} catch {
    Write-Host "`n [UHDC] [!] Error: Could not query CIM/WMI."
    Write-Host "      Possible cause: Firewall, RPC error, or Access Denied."
    Write-Host "      Details: $($_.Exception.Message)"
}

Write-Host "========================================`n"