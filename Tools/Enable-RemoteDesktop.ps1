# Enable-RemoteDesktop.ps1
# Remotely enables RDP on the target machine by modifying the registry,
# opening the Windows Firewall, and ensuring the TermService is running.
# Includes a PsExec fallback if WinRM is blocked.

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
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] Remote Desktop Configuration"
Write-Host "========================================"

# Fast ping check to ensure the machine is actually online before we try connecting
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

# Execute RDP enable steps
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # Step 1: Registry Modification
    Wait-TrainingStep `
        -Desc "STEP 1: ENABLE RDP IN REGISTRY`n`nWHEN TO USE THIS:`nUse this when you need to establish a Remote Desktop connection to a PC, but the feature is currently disabled in the system settings.`n`nWHAT IT DOES:`nWe are using PsExec to run the native Windows 'reg.exe' tool as the SYSTEM account. We modify the 'fDenyTSConnections' registry key, changing its value from 1 (Deny) to 0 (Allow). This tells Windows to accept incoming Terminal Services (RDP) connections.`n`nIN-PERSON EQUIVALENT:`nOpen System Properties (sysdm.cpl) > Remote tab > Select 'Allow remote connections to this computer'." `
        -Code "psexec.exe \\$Target -s reg add `"HKLM\System\CurrentControlSet\Control\Terminal Server`" /v fDenyTSConnections /t REG_DWORD /d 0 /f"

    Write-Host "  > [1/3] Enabling RDP in registry..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
    }

    # Step 2: Firewall Configuration
    Wait-TrainingStep `
        -Desc "STEP 2: OPEN WINDOWS FIREWALL`n`nWHEN TO USE THIS:`nUse this when RDP is enabled in the registry, but connections are still timing out because the local Windows Defender Firewall is blocking port 3389.`n`nWHAT IT DOES:`nWe use PsExec to run the native 'netsh' (Network Shell) command. This command enables the predefined 'Remote Desktop' firewall rule group across all active network profiles, allowing traffic on port 3389.`n`nIN-PERSON EQUIVALENT:`nOpen Windows Defender Firewall > 'Allow an app or feature through Windows Defender Firewall' > Check the box for 'Remote Desktop'." `
        -Code "psexec.exe \\$Target -s netsh advfirewall firewall set rule group=`"Remote Desktop`" new enable=Yes"

    Write-Host "  > [2/3] Opening Windows Firewall for RDP (Port 3389)..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
    }

    # Step 3: Service Configuration
    Wait-TrainingStep `
        -Desc "STEP 3: START TERMINAL SERVICE`n`nWHEN TO USE THIS:`nUse this to ensure the underlying Remote Desktop Service is actually running and actively listening for connections.`n`nWHAT IT DOES:`nWe use PsExec to run the native 'sc.exe' (Service Control) and 'net.exe' commands. First, we configure the 'TermService' to start automatically on boot. Then, we forcefully start the service right now.`n`nIN-PERSON EQUIVALENT:`nOpen Services (services.msc), locate 'Remote Desktop Services', right-click and select Properties, change Startup type to 'Automatic', and click 'Start'." `
        -Code "psexec.exe \\$Target -s cmd /c `"sc config TermService start= auto & net start TermService`""

    Write-Host "  > [3/3] Ensuring TermService is running..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Set-Service -Name "TermService" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    }

    Write-Host "`n [UHDC] Success: RDP enabled, firewall opened, and service started."
    Write-Host " [UHDC] [i] You can try connecting using MSRA or RDP now."

    # Audit log
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Remote Desktop Enabled (WinRM)" -SharedRoot $SharedRoot
        }
    }

} catch {
    # PsExec Fallback
    Write-Host "  > [i] WinRM blocked by firewall. Attempting PsExec fallback..." -ForegroundColor DarkGray

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {

        Wait-TrainingStep `
            -Desc "STEP 1 (FALLBACK): CHAINED PSEXEC COMMAND`n`nWHEN TO USE THIS:`nThis triggers automatically if the standard WinRM connection is blocked by the target's Windows Firewall.`n`nWHAT IT DOES:`nInstead of running three separate commands, we chain them all together using the '&' operator inside a single 'cmd /c' block. This allows PsExec to connect once, execute the registry edit, open the firewall, and start the service all in one swift motion.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt and typing the entire chain manually." `
            -Code "psexec.exe \\$Target -s cmd /c `"reg add \`"HKLM\System\CurrentControlSet\Control\Terminal Server\`" /v fDenyTSConnections /t REG_DWORD /d 0 /f & netsh advfirewall firewall set rule group=\`"Remote Desktop\`" new enable=Yes & sc config TermService start= auto & net start TermService`""

        # Execute chained command via PsExec
        $cmdChain = 'cmd /c "reg add \"HKLM\System\CurrentControlSet\Control\Terminal Server\" /v fDenyTSConnections /t REG_DWORD /d 0 /f & netsh advfirewall firewall set rule group=\"Remote Desktop\" new enable=Yes & sc config TermService start= auto & net start TermService"'

        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "`n [UHDC] Success: RDP enabled, firewall opened, and service started via PsExec."
        Write-Host " [UHDC] [i] You can try connecting using MSRA or RDP now."

        # Audit log (Fallback)
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { 
                & $AuditHelper -Target $Target -Action "Remote Desktop Enabled (PsExec Fallback)" -SharedRoot $SharedRoot
            }
        }
    } else {
        Write-Host "  > [!] Error: psexec.exe missing from \Core. Cannot attempt fallback."
    }
}

Write-Host "========================================`n"