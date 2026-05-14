# RemoteInstall.ps1
# Provides a themed GUI interface to manage and silently deploy software to a 
# remote target using PsExec (SYSTEM context). Supports saving commonly used 
# application UNC paths and silent installation arguments to a central JSON library.
# Universally stages ALL packages locally, executes via Base64-encoded PowerShell,
# and catches remote errors to prevent CLIXML serialization issues.

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

            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnCancel" Content="Cancel" Width="100" Height="35" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
                <Button Name="BtnExecute" Content="Execute Selection" Width="140" Height="35" Background="#28A745" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
            </StackPanel>
        </Grid>
    </Window>
"@
    $MenuXAML = $MenuXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $MenuXAML = $MenuXAML -replace '%%BG_BTN%%', $ActiveColors.BG_Btn
    $MenuXAML = $MenuXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

    $StringReader = New-Object System.IO.StringReader $MenuXAML
    $XmlReader = [System.Xml.XmlReader]::Create($StringReader)
    $MenuWin = [System.Windows.Markup.XamlReader]::Load($XmlReader)

    $AppList = $MenuWin.FindName("AppList")
    $BtnExecute = $MenuWin.FindName("BtnExecute")

    foreach ($item in $MenuOptions) { $AppList.Items.Add($item) | Out-Null }

    $BtnExecute.Add_Click({
        if ($AppList.SelectedItem) { $MenuWin.DialogResult = $true } 
        else { [System.Windows.MessageBox]::Show("Please select an item from the list.", "Selection Required", "OK", "Warning") }
    })

    if ($MenuWin.ShowDialog() -eq $true) {
        $Selection = $AppList.SelectedItem

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

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {
        try {
            $cleanPath = $installer.Path.Trim(" `"'")
            $isMsix = $cleanPath -match '\.(msix|appx|msixbundle|appxbundle)$'
            $isMsi  = $cleanPath -match '\.msi$'

            Write-Host "  > [UHDC] Staging package to target's local drive (Bypassing Double-Hop)..."

            # Setup staging paths
            $stagingDir = "\\$Target\c$\Temp\UHDC_Staging"
            $fileName = Split-Path $cleanPath -Leaf
            $stagingFile = "$stagingDir\$fileName"
            $localTargetFile = "C:\Temp\UHDC_Staging\$fileName"

            # Copy file over the network using the technician's credentials
            if (-not (Test-Path $stagingDir)) { New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null }

            Write-Host "  > [UHDC] Transferring file over network (This may take a moment for large files)..."
            Copy-Item -Path $cleanPath -Destination $stagingFile -Force

            # Build the PowerShell command wrapped in a Try/Catch to prevent CLIXML errors
            # We pipe the installation commands to Out-Null to suppress the success objects that cause the CLIXML crash
            if ($isMsix) {
                $psCommand = "try { Add-AppxProvisionedPackage -Online -PackagePath `"$localTargetFile`" -SkipLicense"
                if (-not [string]::IsNullOrWhiteSpace($installer.Args) -and $installer.Args -notmatch '^/([Sqx]|qn|quiet|norestart)') {
                    $psCommand += " $($installer.Args)"
                }
                $psCommand += " -ErrorAction Stop | Out-Null; Write-Output '[SUCCESS] MSIX Provisioned Successfully.' } catch { Write-Output `"[ERROR] MSIX Install Failed: `$(`$_.Exception.Message)`" }; Start-Sleep -Seconds 5; Remove-Item -Path `"$localTargetFile`" -Force -ErrorAction SilentlyContinue"

                Wait-TrainingStep `
                    -Desc "STEP 1: STAGE & PROVISION MSIX`n`nWHEN TO USE THIS:`nUse this when deploying modern Windows Store apps (.msix or .appx) to a remote machine in an enterprise environment.`n`nWHAT IT DOES:`nFirst, we copy the .msix file to the target's C:\Temp folder. This bypasses the 'Double-Hop' issue where the remote SYSTEM account gets blocked from accessing network shares. Then, we use PsExec to launch a hidden PowerShell session as SYSTEM and execute 'Add-AppxProvisionedPackage'. This provisions the app into the Windows image so all current and future users get it. Finally, it deletes the temp file.`n`nIN-PERSON EQUIVALENT:`nCopying the file to the C: drive, opening an elevated PowerShell window, and typing 'Add-AppxProvisionedPackage -Online -PackagePath `"C:\Temp\app.msix`" -SkipLicense'." `
                    -Code "Copy-Item `"$cleanPath`" `"\\$Target\c$\Temp\`"`npsexec.exe \\$Target -s powershell.exe -Command `"$psCommand`""

            } else {
                if ($isMsi) {
                    $psCommand = "try { Start-Process -FilePath `"msiexec.exe`" -ArgumentList `"/i `\`"$localTargetFile`\`" $($installer.Args)`" -Wait -NoNewWindow | Out-Null; Write-Output '[SUCCESS] MSI Installed Successfully.' } catch { Write-Output `"[ERROR] MSI Install Failed: `$(`$_.Exception.Message)`" }; Start-Sleep -Seconds 5; Remove-Item -Path `"$localTargetFile`" -Force -ErrorAction SilentlyContinue"
                } else {
                    $psCommand = "try { Start-Process -FilePath `"$localTargetFile`" -ArgumentList `"$($installer.Args)`" -Wait -NoNewWindow | Out-Null; Write-Output '[SUCCESS] EXE Installed Successfully.' } catch { Write-Output `"[ERROR] EXE Install Failed: `$(`$_.Exception.Message)`" }; Start-Sleep -Seconds 5; Remove-Item -Path `"$localTargetFile`" -Force -ErrorAction SilentlyContinue"
                }

                Wait-TrainingStep `
                    -Desc "STEP 1: STAGE & SILENT INSTALL`n`nWHEN TO USE THIS:`nUse this when a user needs a standard application (like Chrome or Zoom) installed, but they do not have local administrator rights, or you want to install it in the background without interrupting their work.`n`nWHAT IT DOES:`nFirst, we copy the installer to the target's C:\Temp folder to bypass 'Double-Hop' network blocks. We then use PsExec to connect as the 'SYSTEM' account and launch a hidden PowerShell session. This session executes the installer using 'silent' command-line switches (like /S or /qn), waits for the installation to finish, and then deletes the temporary file.`n`nIN-PERSON EQUIVALENT:`nCopying the installer to the C: drive, double-clicking it, typing in your admin credentials when prompted by UAC, and clicking 'Next' through the installation wizard." `
                    -Code "Copy-Item `"$cleanPath`" `"\\$Target\c$\Temp\`"`npsexec.exe \\$Target -s powershell.exe -Command `"$psCommand`""
            }

            Write-Host "  > [UHDC] Installing in background... (Please wait)"

            # Encode the command to prevent cmd.exe from mangling quotes
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($psCommand))

            # Use an array for arguments to pass to the call operator (&)
            $psexecArgs = @("/accepteula", "\\$Target", "-s", "powershell.exe", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded)

            # Execute via call operator to pipe output directly to the UHDC console (prevents flashing windows)
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

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action "Deployed Software: $($installer.Name)" -SharedRoot $SharedRoot
                }
            }
        } catch {
            Write-Host " [UHDC] [!] Error: Execution failed. $($_.Exception.Message)"
        }
    } else {
        Write-Host " [UHDC] [!] Error: psexec.exe not found at $psExecPath"
    }
}

Write-Host "========================================`n"
