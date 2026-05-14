# RemoteInstall.ps1
# Provides a themed GUI interface to manage and silently deploy software to a 
# remote target using PsExec. Supports saving commonly used application UNC paths.
# Universally stages ALL packages locally, generates an install.ps1 script on the target,
# and forces PsExec to wait synchronously while capturing a local transcript log.
# Includes an Execution Context dropdown to choose between SYSTEM, Technician, and Active User.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash,

    [Parameter(Mandatory=$false)]
    [string]$ThemeB64
)

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
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch { return }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

# Theme engine integration
$ActiveColors = @{
    BG_Main = "#1E1E1E"; BG_Sec  = "#111111"; BG_Con  = "#0C0C0C"
    BG_Btn  = "#2D2D30"; Acc_Pri = "#00A2ED"; Acc_Sec = "#00FF00"
}

if (-not [string]::IsNullOrWhiteSpace($ThemeB64)) {
    try {
        $ThemeBytes = [Convert]::FromBase64String($ThemeB64)
        $ThemeJson = [System.Text.Encoding]::UTF8.GetString($ThemeBytes)
        $parsed = $ThemeJson | ConvertFrom-Json

        $ActiveColors.BG_Main = $parsed.BG_Main
        $ActiveColors.BG_Sec  = $parsed.BG_Sec
        $ActiveColors.BG_Con  = $parsed.BG_Con
        $ActiveColors.BG_Btn  = $parsed.BG_Btn
        $ActiveColors.Acc_Pri = $parsed.Acc_Pri
        $ActiveColors.Acc_Sec = $parsed.Acc_Sec
    } catch {}
}

Write-Host "========================================"
Write-Host " [UHDC] Remote silent installer: $Target"
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

# Setup paths & library functions
$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\SoftwareLibrary.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        try {
            $raw = Get-Content $LibraryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $raw) { return @() }
            if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
        } catch { return @() }
    } else { 
        $default = @(
            [PSCustomObject]@{ ID=1; Name="Google Chrome (Enterprise)"; Path="\\server\share\Software\GoogleChromeStandaloneEnterprise64.msi"; Args="/qn /norestart" }
        )
        Save-Lib $default
        return $default
    }
}

function Save-Lib {
    param($d)
    try {
        $arr = @($d)
        $jsonOutput = $arr | ConvertTo-Json -Depth 2 -ErrorAction Stop
        if ($arr.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }
        Set-Content -Path $LibraryFile -Value $jsonOutput -Force
    } catch {
        Write-Host " [UHDC] [!] Failed to save software library." -ForegroundColor Red
    }
}

Add-Type -AssemblyName PresentationFramework

# Custom themed input box function
function Show-ThemedInputBox {
    param([string]$Title, [string]$Prompt, [string]$DefaultText = "")

    [string]$InputXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="$Title" SizeToContent="Height" Width="480" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize">
        <StackPanel Margin="15">
            <TextBlock Text="$Prompt" Foreground="White" FontSize="14" Margin="0,0,0,10" TextWrapping="Wrap"/>
            <TextBox Name="InputBox" Text="$DefaultText" Background="%%BG_SEC%%" Foreground="%%ACC_PRI%%" FontSize="14" Height="28" Padding="4" BorderBrush="#555"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
                <Button Name="BtnCancel" Content="Cancel" Width="80" Height="30" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
                <Button Name="BtnOK" Content="OK" Width="80" Height="30" Background="%%ACC_PRI%%" Foreground="%%BG_MAIN%%" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
            </StackPanel>
        </StackPanel>
    </Window>
"@
    $InputXAML = $InputXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $InputXAML = $InputXAML -replace '%%BG_SEC%%', $ActiveColors.BG_Sec
    $InputXAML = $InputXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

    $StringReader = New-Object System.IO.StringReader $InputXAML
    $XmlReader = [System.Xml.XmlReader]::Create($StringReader)
    $InputWin = [System.Windows.Markup.XamlReader]::Load($XmlReader)

    $InputBox = $InputWin.FindName("InputBox")
    $BtnOK = $InputWin.FindName("BtnOK")

    $InputWin.Add_Loaded({
        $InputBox.Focus()
        $InputBox.SelectAll()
    })

    $BtnOK.Add_Click({ 
        $InputWin.DialogResult = $true 
    })

    if ($InputWin.ShowDialog() -eq $true) { 
        return $InputBox.Text 
    }
    return $null
}

# Main menu loop
$installer = $null
$runContext = "SYSTEM"

while ($true) {
    $lib = Load-Lib

    $MenuOptions = @()
    foreach ($app in $lib) {
        $MenuOptions += [PSCustomObject]@{ Action = "INSTALL"; Name = $app.Name; Path = $app.Path; Args = $app.Args; ID = $app.ID }
    }
    $MenuOptions += [PSCustomObject]@{ Action = "CUSTOM"; Name = "[*] Custom one-off install"; Path = "---"; Args = "---"; ID = "" }
    $MenuOptions += [PSCustomObject]@{ Action = "ADD";    Name = "[+] Add new app to library"; Path = "---"; Args = "---"; ID = "" }
    $MenuOptions += [PSCustomObject]@{ Action = "DELETE"; Name = "[-] Delete app from library";Path = "---"; Args = "---"; ID = "" }

    [string]$MenuXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="UHDC: Remote Installer - $Target" Height="450" Width="750" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" Topmost="True">
        <Grid Margin="15">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Text="Select Software Action for $Target" Foreground="%%ACC_PRI%%" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>

            <ListView Name="AppList" Grid.Row="1" Background="%%BG_BTN%%" Foreground="White" BorderBrush="#555" FontSize="14" Margin="0,0,0,15">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="Action" DisplayMemberBinding="{Binding Action}" Width="80"/>
                        <GridViewColumn Header="Application Name" DisplayMemberBinding="{Binding Name}" Width="220"/>
                        <GridViewColumn Header="UNC Path" DisplayMemberBinding="{Binding Path}" Width="380"/>
                    </GridView>
                </ListView.View>
            </ListView>

            <Grid Grid.Row="2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Run As:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <ComboBox Name="ComboContext" Width="200" Height="26" Background="%%BG_SEC%%" Foreground="Black" FontSize="13">
                        <ComboBoxItem IsSelected="True">SYSTEM (Machine-Wide)</ComboBoxItem>
                        <ComboBoxItem>Active User (Per-User Apps)</ComboBoxItem>
                        <ComboBoxItem>Technician (Your Creds)</ComboBoxItem>
                    </ComboBox>
                </StackPanel>

                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button Name="BtnCancel" Content="Cancel" Width="100" Height="35" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
                    <Button Name="BtnExecute" Content="Execute Selection" Width="140" Height="35" Background="#28A745" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
                </StackPanel>
            </Grid>
        </Grid>
    </Window>
"@
    $MenuXAML = $MenuXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $MenuXAML = $MenuXAML -replace '%%BG_SEC%%', $ActiveColors.BG_Sec
    $MenuXAML = $MenuXAML -replace '%%BG_BTN%%', $ActiveColors.BG_Btn
    $MenuXAML = $MenuXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

    $StringReader = New-Object System.IO.StringReader $MenuXAML
    $XmlReader = [System.Xml.XmlReader]::Create($StringReader)
    $MenuWin = [System.Windows.Markup.XamlReader]::Load($XmlReader)

    $AppList = $MenuWin.FindName("AppList")
    $BtnExecute = $MenuWin.FindName("BtnExecute")
    $ComboContext = $MenuWin.FindName("ComboContext")

    foreach ($item in $MenuOptions) { $AppList.Items.Add($item) | Out-Null }

    $BtnExecute.Add_Click({
        if ($AppList.SelectedItem) { $MenuWin.DialogResult = $true } 
        else { [System.Windows.MessageBox]::Show("Please select an item from the list.", "Selection Required", "OK", "Warning") }
    })

    if ($MenuWin.ShowDialog() -eq $true) {
        $Selection = $AppList.SelectedItem

        if ($ComboContext.Text -match "Technician") { $runContext = "TECH" } 
        elseif ($ComboContext.Text -match "Active User") { $runContext = "USER" } 
        else { $runContext = "SYSTEM" }

        if ($Selection.Action -eq "ADD") {
            $n = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "Enter display name (e.g., Google Chrome):"
            if (-not $n) { continue }

            $p = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "Enter UNC path to installer:" -DefaultText "\\server\share\installer.exe"
            if (-not $p) { continue }

            $cleanPath = $p.Trim(" `"'")
            if ($cleanPath -match '\.(msix|appx|msixbundle|appxbundle)$') {
                $a = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "MSIX Detected. Enter extra PowerShell parameters (e.g. -DependencyPackagePath) or leave blank:`n(Note: -Online and -SkipLicense are applied automatically)"
            } else {
                $a = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "Enter silent switches (e.g., /S /q):" -DefaultText "/S"
            }

            $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
            $lib += [PSCustomObject]@{ID=$newID; Name=$n.Trim(); Path=$p.Trim(); Args=$a.Trim()}
            Save-Lib $lib
            Write-Host " [UHDC] [+] Added '$n' to library."
            continue 
        }
        elseif ($Selection.Action -eq "DELETE") {
            if ($lib.Count -eq 0) { Write-Host " [UHDC] [i] Library is already empty."; continue }

            $StringReaderDel = New-Object System.IO.StringReader $MenuXAML
            $XmlReaderDel = [System.Xml.XmlReader]::Create($StringReaderDel)
            $DelWin = [System.Windows.Markup.XamlReader]::Load($XmlReaderDel)

            $DelWin.Title = "UHDC: Delete App from Library"
            $DelWin.FindName("BtnExecute").Content = "Delete Selected"
            $DelWin.FindName("BtnExecute").Background = "#DC3545"
            $DelList = $DelWin.FindName("AppList")
            $DelWin.FindName("ComboContext").Visibility = "Collapsed"
            foreach ($item in $lib) { $DelList.Items.Add($item) | Out-Null }

            $DelWin.FindName("BtnExecute").Add_Click({
                if ($DelList.SelectedItem) { $DelWin.DialogResult = $true }
            })

            if ($DelWin.ShowDialog() -eq $true) {
                $delSel = $DelList.SelectedItem
                $lib = $lib | Where-Object { $_.ID -ne $delSel.ID }
                Save-Lib $lib
                Write-Host " [UHDC] [-] Removed '$($delSel.Name)' from library."
            }
            continue 
        }
        elseif ($Selection.Action -eq "CUSTOM") {
            $path = Show-ThemedInputBox -Title "UHDC Custom Install" -Prompt "Enter UNC path to installer:" -DefaultText "\\server\share\installer.exe"
            if (-not $path) { continue }

            $cleanPath = $path.Trim(" `"'")
            if ($cleanPath -match '\.(msix|appx|msixbundle|appxbundle)$') {
                $args = Show-ThemedInputBox -Title "UHDC Custom Install" -Prompt "MSIX Detected. Enter extra PowerShell parameters (e.g. -DependencyPackagePath) or leave blank:`n(Note: -Online and -SkipLicense are applied automatically)"
            } else {
                $args = Show-ThemedInputBox -Title "UHDC Custom Install" -Prompt "Enter silent switches (e.g., /S /q):"
            }

            $installer = [PSCustomObject]@{Name="Custom App"; Path=$path.Trim(); Args=$args.Trim()}
            break 
        }
        elseif ($Selection.Action -eq "INSTALL") {
            $installer = $Selection
            break 
        }
    } else {
        Write-Host " [UHDC] [i] Installation aborted by user."
        Write-Host "========================================`n"
        return
    }
}

# Execute installation
if ($installer) {
    Write-Host "`n [UHDC] [i] Deploying $($installer.Name) to $Target..."
    Write-Host "      Path: $($installer.Path)"
    if ($installer.Args) { Write-Host "      Args: $($installer.Args)" }
    Write-Host "      Context: $runContext"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {
        try {
            $cleanPath = $installer.Path.Trim(" `"'")
            $isMsix = $cleanPath -match '\.(msix|appx|msixbundle|appxbundle)$'
            $isMsi  = $cleanPath -match '\.msi$'

            # 1. Validate Source File
            if (-not (Test-Path $cleanPath)) {
                throw "Source file cannot be found or accessed: $cleanPath"
            }
            $sourceSize = (Get-Item $cleanPath).Length

            # 2. Setup Staging Variables
            $stagingDir = "\\$Target\c$\Temp\UHDC_Staging"
            $fileName = Split-Path $cleanPath -Leaf
            $stagingFile = "$stagingDir\$fileName"
            $localTargetFile = "C:\Temp\UHDC_Staging\$fileName"

            # 3. Create Directory and Copy File
            if (-not (Test-Path $stagingDir)) { New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null }

            $fileSizeMB = [math]::Round($sourceSize / 1MB, 2)
            Write-Host "  > [UHDC] Transferring $fileName ($fileSizeMB MB) to target..."

            $transferTime = Measure-Command {
                Copy-Item -Path $cleanPath -Destination $stagingFile -Force -ErrorAction Stop
            }

            # 4. Strict Byte-for-Byte Verification
            if (-not (Test-Path $stagingFile)) {
                throw "Verification failed: The file did not successfully copy to $stagingFile"
            }
            $targetSize = (Get-Item $stagingFile).Length
            if ($sourceSize -ne $targetSize) {
                throw "Verification failed: Source file is $sourceSize bytes, but transferred file is $targetSize bytes."
            }

            Write-Host "  > [UHDC] Transfer complete and verified in $($transferTime.TotalSeconds.ToString('0.0')) seconds."

            # 5. Build the PowerShell execution payload script
            $argString = if (-not [string]::IsNullOrWhiteSpace($installer.Args)) { $installer.Args } else { "" }
            $scriptContent = ""

            # Determine the log path based on context to ensure proper Write permissions
            if ($runContext -eq "USER") {
                $logPath = "`$env:TEMP\UHDC_install_log.txt"
            } else {
                $logPath = "C:\Temp\UHDC_Staging\install_log.txt"
            }

            if ($isMsix) {
                # Strip legacy exe/msi silent switches if accidentally provided for MSIX
                $argString = $argString -replace '(?i)^/([Sqx]|qn|quiet|norestart)\s*', ''

                $scriptContent = @"
Start-Transcript -Path "$logPath" -Force
`$ErrorActionPreference = 'Stop'
try {
    Write-Output "Starting MSIX Provisioning..."
    Write-Output "Verifying local file size on target..."
    `$size = [math]::Round((Get-Item "$localTargetFile").Length / 1MB, 2)
    Write-Output "File size: `$size MB"

    Add-AppxProvisionedPackage -Online -PackagePath "$localTargetFile" -SkipLicense $argString | Out-Null
    Write-Output "[SUCCESS] MSIX Provisioned Successfully."
} catch {
    Write-Output "[ERROR] MSIX Install Failed: `$(`$_.Exception.Message)"
}
Stop-Transcript
"@
            } elseif ($isMsi) {
                $scriptContent = @"
Start-Transcript -Path "$logPath" -Force
`$ErrorActionPreference = 'Stop'
try {
    Write-Output "Starting MSI Installation..."
    Write-Output "Verifying local file size on target..."
    `$size = [math]::Round((Get-Item "$localTargetFile").Length / 1MB, 2)
    Write-Output "File size: `$size MB"

    `$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `\`"$localTargetFile`\`" $argString" -Wait -PassThru -NoNewWindow
    if (`$proc.ExitCode -eq 0 -or `$proc.ExitCode -eq 3010) {
        Write-Output "[SUCCESS] MSI Installed Successfully (Exit Code: `$(`$proc.ExitCode))."
    } else {
        Write-Output "[ERROR] MSI Install returned Exit Code: `$(`$proc.ExitCode)"
    }
} catch {
    Write-Output "[ERROR] MSI Install Failed: `$(`$_.Exception.Message)"
}
Stop-Transcript
"@
            } else {
                $scriptContent = @"
Start-Transcript -Path "$logPath" -Force
`$ErrorActionPreference = 'Stop'
try {
    Write-Output "Starting EXE Installation..."
    Write-Output "Verifying local file size on target..."
    `$size = [math]::Round((Get-Item "$localTargetFile").Length / 1MB, 2)
    Write-Output "File size: `$size MB"

    `$proc = Start-Process -FilePath "$localTargetFile" -ArgumentList "$argString" -Wait -PassThru -NoNewWindow
    if (`$proc.ExitCode -eq 0 -or `$proc.ExitCode -eq 3010) {
        Write-Output "[SUCCESS] EXE Installed Successfully (Exit Code: `$(`$proc.ExitCode))."
    } else {
        Write-Output "[ERROR] EXE Install returned Exit Code: `$(`$proc.ExitCode)"
    }
} catch {
    Write-Output "[ERROR] EXE Install Failed: `$(`$_.Exception.Message)"
}
Stop-Transcript
"@
            }

            # 6. Save the install script to the target
            $scriptPath = "$stagingDir\install.ps1"
            $localScriptPath = "C:\Temp\UHDC_Staging\install.ps1"
            Set-Content -Path $scriptPath -Value $scriptContent -Force

            # 7. Execution Context Routing
            if ($runContext -eq "USER") {
                Write-Host "  > [UHDC] Querying active user session for Per-User deployment..."
                $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Target -ErrorAction Stop
                $activeUser = $compInfo.UserName

                if (-not $activeUser) {
                    throw "Cannot install as Active User: No user is currently logged into $Target."
                }
                Write-Host "  > [UHDC] Active user detected: $activeUser"
                Write-Host "  > [UHDC] Building Scheduled Task bridge to bypass UAC..."

                # Build a launcher script that creates a Scheduled Task to run the install as the Active User
                $launcherContent = @"
`$TaskName = "UHDC_Install_`$((Get-Date).Ticks)"
`$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Temp\UHDC_Staging\install.ps1"
`$Principal = New-ScheduledTaskPrincipal -UserId "$activeUser" -LogonType Interactive
`$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
Register-ScheduledTask -TaskName `$TaskName -Action `$Action -Trigger `$Trigger -Principal `$Principal -Force | Out-Null
Start-ScheduledTask -TaskName `$TaskName
while ((Get-ScheduledTask -TaskName `$TaskName).State -eq 'Running') { Start-Sleep -Seconds 2 }
Unregister-ScheduledTask -TaskName `$TaskName -Confirm:`$false | Out-Null

`$logPath = "C:\Users\$($activeUser.Split('\')[-1])\AppData\Local\Temp\UHDC_install_log.txt"
if (Test-Path `$logPath) {
    Get-Content `$logPath | Where-Object { `$_ -match "\[SUCCESS\]|\[ERROR\]" } | Write-Output
}
"@
                $launcherPath = "$stagingDir\launcher.ps1"
                Set-Content -Path $launcherPath -Value $launcherContent -Force

                Wait-TrainingStep `
                    -Desc "STEP 1: PER-USER SCHEDULED TASK INJECTION`n`nWHEN TO USE THIS:`nUse this to silently deploy per-user .exe apps (like Canva, Spotify, WebEx) directly into the active user's AppData folder without needing their password.`n`nWHAT IT DOES:`nWe use PsExec as SYSTEM to dynamically build and register a Scheduled Task on the target PC. We set the task to run as the logged-in user (Interactive Token), trigger it immediately, wait for the installation to finish in their hidden background session, and then delete the task to clean up.`n`nIN-PERSON EQUIVALENT:`nSitting at the user's desk while they are logged in, downloading the .exe, and double-clicking it." `
                    -Code "psexec.exe \\$Target -s -w `"C:\Temp\UHDC_Staging`" powershell.exe -File launcher.ps1"

                # Use -w to set the working directory to the local C: drive, preventing UNC path errors
                $psexecArgs = @("/accepteula", "\\$Target", "-s", "-w", "C:\Temp\UHDC_Staging", "cmd.exe", "/c", "powershell.exe", "-ExecutionPolicy", "Bypass", "-NoProfile", "-NonInteractive", "-File", "C:\Temp\UHDC_Staging\launcher.ps1")

            } elseif ($runContext -eq "TECH") {
                Wait-TrainingStep `
                    -Desc "STEP 1: TECHNICIAN CONTEXT EXECUTION`n`nWHEN TO USE THIS:`nUse this when an installer explicitly blocks the SYSTEM account from running it, but you still want to install it silently in the background.`n`nWHAT IT DOES:`nWe use PsExec WITHOUT the '-s' switch. Because we already staged the file locally to the C: drive, we bypass the Double-Hop network block, allowing PsExec to execute the installer using your delegated network credentials.`n`nIN-PERSON EQUIVALENT:`nOpening an elevated Command Prompt on the user's PC and running the installer." `
                    -Code "psexec.exe \\$Target -w `"C:\Temp\UHDC_Staging`" powershell.exe -File `"$localScriptPath`""

                $psexecArgs = @("/accepteula", "\\$Target", "-w", "C:\Temp\UHDC_Staging", "cmd.exe", "/c", "powershell.exe", "-ExecutionPolicy", "Bypass", "-NoProfile", "-NonInteractive", "-File", $localScriptPath)

            } else {
                Wait-TrainingStep `
                    -Desc "STEP 1: SYSTEM CONTEXT EXECUTION`n`nWHEN TO USE THIS:`nUse this for 95% of enterprise deployments (Chrome, Adobe, Office) to install the software machine-wide for all users.`n`nWHAT IT DOES:`nWe use PsExec with the '-s' switch to connect as the 'SYSTEM' account and execute the staged install script. The script suppresses progress bars (which crash PsExec), executes the installer, waits for it to finish, and captures the exit code.`n`nIN-PERSON EQUIVALENT:`nCopying the installer to the C: drive, double-clicking it, typing in your admin credentials when prompted by UAC, and clicking 'Next' through the installation wizard." `
                    -Code "psexec.exe \\$Target -s -w `"C:\Temp\UHDC_Staging`" powershell.exe -File `"$localScriptPath`""

                $psexecArgs = @("/accepteula", "\\$Target", "-s", "-w", "C:\Temp\UHDC_Staging", "cmd.exe", "/c", "powershell.exe", "-ExecutionPolicy", "Bypass", "-NoProfile", "-NonInteractive", "-File", $localScriptPath)
            }

            Write-Host "  > [UHDC] Executing installer... (Please wait)"

            # Execute via call operator to pipe output directly to the UHDC console
            $execOutput = & $psExecPath $psexecArgs 2>&1

            foreach ($line in $execOutput) {
                $strLine = [string]$line
                # Filter out standard PsExec noise
                if ($strLine -match "PsExec v" -or $strLine -match "Sysinternals" -or $strLine -match "Copyright" -or $strLine -match "starting on" -or $strLine -match "exited with error code") { continue }

                if (-not [string]::IsNullOrWhiteSpace($strLine)) {
                    if ($strLine -match "\[ERROR\]") {
                        Write-Host "    $strLine" -ForegroundColor Red
                    } elseif ($strLine -match "\[SUCCESS\]") {
                        Write-Host "    $strLine" -ForegroundColor Green
                    } else {
                        Write-Host "    $strLine"
                    }
                }
            }

            Write-Host " [UHDC] Deployment sequence finished."
            Write-Host " [UHDC] [i] Check \\$Target\c$\Temp\UHDC_Staging\install_log.txt for the exact results." -ForegroundColor Yellow

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action "Deployed Software: $($installer.Name) ($runContext)" -SharedRoot $SharedRoot
                }
            }
        } catch {
            Write-Host " [UHDC] [!] Error: Execution failed. $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host " [UHDC] [!] Error: psexec.exe not found at $psExecPath"
    }
}

Write-Host "========================================`n"
