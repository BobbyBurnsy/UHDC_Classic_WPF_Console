# Enable-RemoteDesktop.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely enables RDP on the target machine by modifying the registry (fDenyTSConnections),
# opening the Windows Firewall for the Remote Desktop profile, and ensuring the TermService is running.
# Features an automated PsExec fallback if WinRM is blocked by the firewall.
# Optimized for PS 5.1 (.NET Ping, WPF Training Mode Fix, & PsExec Fallback).

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# --- TRAINING MODE HELPER (WPF Safe) ---
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
# ----------------------------

# ------------------------------------------------------------------
# BULLETPROOF CONFIG LOADER (Fallback if run standalone)
# ------------------------------------------------------------------
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
Write-Host " [UHDC] REMOTE DESKTOP CONFIGURATION"
Write-Host "========================================"

# 1. Fast Ping Check (.NET Ping for PS 5.1 Safety)
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

# 2. Execute RDP Enable Steps
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: REGISTRY MODIFICATION (WinRM)
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: ENABLE RDP IN REGISTRY`n`nWHEN TO USE THIS:`nUse this when you need to establish a Remote Desktop connection to a PC, but the feature is currently disabled in the system settings.`n`nWHAT IT DOES:`nWe are remotely modifying the 'fDenyTSConnections' registry key. Changing this value from 1 (Deny) to 0 (Allow) tells Windows to accept incoming Terminal Services (RDP) connections.`n`nIN-PERSON EQUIVALENT:`nOpen System Properties (sysdm.cpl) > Remote tab > Select 'Allow remote connections to this computer'." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 }"

    Write-Host "  > [1/3] Enabling RDP in Registry..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
    }

    # ------------------------------------------------------------------
    # STEP 2: FIREWALL CONFIGURATION (WinRM)
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 2: OPEN WINDOWS FIREWALL`n`nWHEN TO USE THIS:`nUse this when RDP is enabled in the registry, but connections are still timing out because the local Windows Defender Firewall is blocking port 3389.`n`nWHAT IT DOES:`nWe are using the NetSecurity module to enable the predefined 'Remote Desktop' firewall rule group across the active network profiles.`n`nIN-PERSON EQUIVALENT:`nOpen Windows Defender Firewall > 'Allow an app or feature through Windows Defender Firewall' > Check the box for 'Remote Desktop'." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' }"

    Write-Host "  > [2/3] Opening Windows Firewall for RDP (Port 3389)..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
    }

    # ------------------------------------------------------------------
    # STEP 3: SERVICE CONFIGURATION (WinRM)
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 3: START TERMINAL SERVICE`n`nWHEN TO USE THIS:`nUse this to ensure the underlying Remote Desktop Service is actually running and actively listening for connections.`n`nWHAT IT DOES:`nWe are configuring the 'TermService' to start automatically on boot, and then forcefully starting it right now.`n`nIN-PERSON EQUIVALENT:`nOpen Services (services.msc), locate 'Remote Desktop Services', right-click and select Properties, change Startup type to 'Automatic', and click 'Start'." `
        -Code "Invoke-Command -ComputerName `$Target -ScriptBlock { Set-Service -Name 'TermService' -StartupType Automatic; Start-Service -Name 'TermService' }"

    Write-Host "  > [3/3] Ensuring TermService is running..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Set-Service -Name "TermService" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    }

    Write-Host "`n [UHDC SUCCESS] RDP Enabled, Firewall Opened, and Service Started!"
    Write-Host " [UHDC] [i] You can try connecting using MSRA or RDP now."

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Remote Desktop Enabled (WinRM)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    # ------------------------------------------------------------------
    # PSEXEC FALLBACK
    # ------------------------------------------------------------------
    Write-Host "  > [i] WinRM Blocked by Firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): PSEXEC RDP ENABLE`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM query is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nWe use PsExec to bypass the WinRM block and execute a chained command directly on the target PC. It uses 'reg add' to modify the registry, 'netsh' to open the firewall, and 'sc'/'net start' to configure and start the service.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt and typing the equivalent native commands manually." `
            -Code "`$cmdChain = 'cmd /c `"reg add \`"HKLM\System\CurrentControlSet\Control\Terminal Server\`" /v fDenyTSConnections /t REG_DWORD /d 0 /f & netsh advfirewall firewall set rule group=\`"Remote Desktop\`" new enable=Yes & sc config TermService start= auto & net start TermService`"'`n& `$psExecPath /accepteula \\`$Target -s `$cmdChain"

        # Execute chained command via PsExec
        # Note: Escaping quotes inside the cmd string is critical here
        $cmdChain = 'cmd /c "reg add \"HKLM\System\CurrentControlSet\Control\Terminal Server\" /v fDenyTSConnections /t REG_DWORD /d 0 /f & netsh advfirewall firewall set rule group=\"Remote Desktop\" new enable=Yes & sc config TermService start= auto & net start TermService"'

        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "`n [UHDC SUCCESS] RDP Enabled, Firewall Opened, and Service Started via PsExec!"
        Write-Host " [UHDC] [i] You can try connecting using MSRA or RDP now."

        # --- AUDIT LOG INJECTION (Fallback) ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { 
                & $AuditHelper -Target $Target -Action "Remote Desktop Enabled (PsExec Fallback)" -SharedRoot $SharedRoot
            }
        }
    } else {
        Write-Host "  > [!] ERROR: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"