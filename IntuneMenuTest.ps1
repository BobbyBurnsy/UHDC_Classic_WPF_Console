# IntuneMenu.ps1
# A dedicated helper script for Microsoft Intune management.
# Takes the target user's email address or the computer's hostname and
# constructs the direct URL to open the Microsoft Endpoint Manager portal.
# Features cross-agency domain filtering to prevent unauthorized access.

param(
    [Parameter(Mandatory=$false)]
    [string]$TargetComputer,

    [Parameter(Mandatory=$false)]
    [string]$TargetUser,

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

# Load configuration and domain filtering
$OrgName = "IT"
try {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $RootFolder = Split-Path -Path $ScriptDir
    $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

    if (Test-Path $ConfigFile) {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $OrgName = $Config.OrganizationName
        if ([string]::IsNullOrWhiteSpace($SharedRoot)) { $SharedRoot = $Config.SharedNetworkRoot }
    }
} catch { }

# Resolve Technician's Domain
$TechUPN = whoami /upn 2>$null
if (-not $TechUPN) {
    try { $TechUPN = (Get-ADUser $env:USERNAME -Properties UserPrincipalName).UserPrincipalName } catch {}
}
$TechDomain = if ($TechUPN -match "@(.*)$") { $matches[1] } else { "" }

# Extract base domain (e.g., from it.contoso.com -> contoso.com) to prevent false positives on subdomains
$TechDomainBase = if ($TechDomain -match "([^\.]+\.[^\.]+)$") { $matches[1] } else { $TechDomain }

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

# Load required .NET assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Graph API authentication
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scopes = @(
    "User.Read.All",
    "DeviceManagementManagedDevices.ReadWrite.All",
    "DeviceManagementManagedDevices.PrivilegedOperations.All",
    "BitlockerKey.Read.All",
    "DeviceLocalCredential.Read.All",
    "UserAuthenticationMethod.ReadWrite.All"
)

if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    try { Connect-MgGraph -Scopes $scopes -ErrorAction Stop }
    catch {
        [System.Windows.MessageBox]::Show("Failed to authenticate to Microsoft Graph API. Ensure the Microsoft.Graph module is installed and you have internet access.", "UHDC Error", "OK", "Error")
        return
    }
}

# UI definition (XAML)
[string]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UHDC: $OrgName Device Manager" Height="580" Width="720" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen">

    <Window.Resources>
        <Style x:Key="StdBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="%%ACC_SEC%%"/>
                                <Setter Property="Foreground" Value="%%ACC_SEC%%"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="%%ACC_SEC%%" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="%%ACC_SEC%%"/>
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ActionBtn" TargetType="Button" BasedOn="{StaticResource StdBtn}">
            <Setter Property="Foreground" Value="%%ACC_SEC%%"/>
        </Style>

        <Style x:Key="DangerBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF4444"/>
                                <Setter Property="Foreground" Value="#FF4444"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#FF4444" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF4444"/>
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="WarningBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FFD700"/>
                                <Setter Property="Foreground" Value="#FFD700"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#FFD700" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FFD700"/>
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="MasterBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#B366FF"/>
                                <Setter Property="Foreground" Value="#B366FF"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#B366FF" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#B366FF"/>
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Name="HeaderTitle" Text="UHDC Intune: Scanning Azure..." FontSize="18" Foreground="%%ACC_PRI%%" FontWeight="Bold" Margin="0,0,0,15" TextWrapping="Wrap"/>

        <WrapPanel Grid.Row="1" Name="ActionPanel" Orientation="Horizontal" Visibility="Collapsed" Margin="0,0,0,15">
            <Button Name="BtnBitLocker" Content="Get BitLocker Key" Width="130" Height="30" Margin="5" Style="{StaticResource ActionBtn}" Visibility="Collapsed"/>
            <Button Name="BtnLAPS" Content="Get LAPS Pass" Width="130" Height="30" Margin="5" Style="{StaticResource WarningBtn}" Visibility="Collapsed"/>
            <Button Name="BtnUnlock" Content="Remove Passcode" Width="130" Height="30" Margin="5" Style="{StaticResource WarningBtn}" Visibility="Collapsed"/>
            <Button Name="BtnRemoteLock" Content="Remote Lock" Width="130" Height="30" Margin="5" Style="{StaticResource WarningBtn}" Visibility="Collapsed"/>
            <Button Name="BtnWipe" Content="Remote Wipe" Width="130" Height="30" Margin="5" Style="{StaticResource DangerBtn}" Visibility="Collapsed"/>
            <Button Name="BtnSync" Content="Force Sync" Width="130" Height="30" Margin="5" Style="{StaticResource StdBtn}" Visibility="Collapsed"/>
            <Button Name="BtnReboot" Content="Reboot Device" Width="130" Height="30" Margin="5" Style="{StaticResource DangerBtn}" Visibility="Collapsed"/>
        </WrapPanel>

        <ListBox Grid.Row="2" Name="DeviceList" Background="%%BG_SEC%%" Foreground="%%ACC_PRI%%" FontSize="14" BorderBrush="#555555" BorderThickness="1" Margin="0,0,0,10" SelectionMode="Single"/>

        <TextBlock Grid.Row="3" Name="OutputText" Text="Select a device to see available actions." Foreground="%%ACC_SEC%%" TextWrapping="Wrap" Margin="0,10,0,10"/>

        <GroupBox Grid.Row="4" Header="User Authentication Methods (MFA)" Foreground="#AAAAAA" BorderBrush="#333333" Padding="0">
            <Border BorderThickness="4,0,0,0" BorderBrush="%%ACC_PRI%%" Background="%%BG_SEC%%" Padding="10">
                <StackPanel Orientation="Horizontal" Margin="5">
                    <Button Name="BtnMFA" Content="View MFA" Width="90" Height="30" Style="{StaticResource MasterBtn}" Margin="0,0,10,0"/>
                    <Button Name="BtnClearMFA" Content="Clear MFA" Width="90" Height="30" Style="{StaticResource DangerBtn}" Margin="0,0,10,0"/>
                    <TextBlock Text="Add Cell (+1 format):" Foreground="White" VerticalAlignment="Center" Margin="0,0,5,0"/>
                    <TextBox Name="InputPhone" Width="120" Height="25" Background="%%BG_MAIN%%" Foreground="%%ACC_PRI%%" BorderBrush="#555555" Padding="2" Margin="0,0,5,0"/>
                    <Button Name="BtnAddPhone" Content="Add SMS" Width="80" Height="30" Style="{StaticResource ActionBtn}"/>
                </StackPanel>
            </Border>
        </GroupBox>
    </Grid>
</Window>
"@

$XAML = $XAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
$XAML = $XAML -replace '%%BG_SEC%%',  $ActiveColors.BG_Sec
$XAML = $XAML -replace '%%BG_CON%%',  $ActiveColors.BG_Con
$XAML = $XAML -replace '%%BG_BTN%%',  $ActiveColors.BG_Btn
$XAML = $XAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri
$XAML = $XAML -replace '%%ACC_SEC%%', $ActiveColors.Acc_Sec

$StringReader = New-Object System.IO.StringReader $XAML
$XmlReader = [System.Xml.XmlReader]::Create($StringReader)
$Form = [Windows.Markup.XamlReader]::Load($XmlReader)

$HeaderTitle = $Form.FindName("HeaderTitle")
$DeviceList  = $Form.FindName("DeviceList")
$ActionPanel = $Form.FindName("ActionPanel")
$OutputText  = $Form.FindName("OutputText")

$BtnBitLocker  = $Form.FindName("BtnBitLocker")
$BtnLAPS       = $Form.FindName("BtnLAPS")
$BtnUnlock     = $Form.FindName("BtnUnlock")
$BtnRemoteLock = $Form.FindName("BtnRemoteLock")
$BtnWipe       = $Form.FindName("BtnWipe")
$BtnSync       = $Form.FindName("BtnSync")
$BtnReboot     = $Form.FindName("BtnReboot")
$BtnMFA        = $Form.FindName("BtnMFA")
$BtnClearMFA   = $Form.FindName("BtnClearMFA")
$InputPhone    = $Form.FindName("InputPhone")
$BtnAddPhone   = $Form.FindName("BtnAddPhone")

# Explicitly scope these so the button click handlers can access them
$script:ResolvedUser = $null
$script:GlobalDevices = @()

# Initialization
$Form.Add_Loaded({
    if ([string]::IsNullOrWhiteSpace($TargetUser) -and [string]::IsNullOrWhiteSpace($TargetComputer)) {
        $HeaderTitle.Text = "Error: No user or computer provided from GUI."
        return
    }

    $HeaderString = "UHDC Search:"
    $RawDeviceList = @()

    try {
        if (-not [string]::IsNullOrWhiteSpace($TargetComputer)) {
            $HeaderTitle.Text = "Scanning Intune for device: $TargetComputer..."
            [System.Windows.Forms.Application]::DoEvents()

            $SafeComp = $TargetComputer -replace "'","''"
            $deviceMatch = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$SafeComp'" -ErrorAction Stop

            if ($deviceMatch) {
                $devices = if ($deviceMatch -is [System.Array]) { $deviceMatch } else { @($deviceMatch) }

                foreach ($dev in $devices) {
                    $upn = $dev.UserPrincipalName
                    $domainMatch = $false

                    if (-not $TechDomainBase) { $domainMatch = $true }
                    elseif ([string]::IsNullOrWhiteSpace($upn)) { $domainMatch = $true } # Fail open if API doesn't return UPN
                    elseif ($upn -notmatch "@") { $domainMatch = $true } # Local/Malformed account bypass
                    elseif ($upn -match [regex]::Escape($TechDomainBase)) { $domainMatch = $true }

                    if (-not $domainMatch) {
                        [System.Windows.MessageBox]::Show("Access Denied: The requested device ($($dev.DeviceName)) is assigned to a different agency/domain ($upn).", "Cross-Agency Block", "OK", "Error")
                    } else {
                        $RawDeviceList += $dev
                        $HeaderString += " [Device Found]"
                    }
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($TargetUser)) {
            $HeaderTitle.Text = "Scanning Azure AD for user: $TargetUser..."
            [System.Windows.Forms.Application]::DoEvents()

            $SafeUser = $TargetUser -replace "'","''"
            $users = @(Get-MgUser -Filter "userPrincipalName eq '$SafeUser' or mail eq '$SafeUser' or mailNickname eq '$SafeUser'" -ErrorAction Stop)

            if ($users.Count -gt 0) {
                $script:ResolvedUser = $users[0]
                $upn = $script:ResolvedUser.UserPrincipalName
                $mail = $script:ResolvedUser.Mail

                $domainMatch = $false
                if (-not $TechDomainBase) { $domainMatch = $true }
                elseif ([string]::IsNullOrWhiteSpace($upn) -and [string]::IsNullOrWhiteSpace($mail)) { $domainMatch = $true } # Fail open
                elseif ($upn -and $upn -match [regex]::Escape($TechDomainBase)) { $domainMatch = $true }
                elseif ($mail -and $mail -match [regex]::Escape($TechDomainBase)) { $domainMatch = $true }
                elseif ($upn -and $upn -notmatch "@") { $domainMatch = $true } # Local/Malformed account bypass

                if (-not $domainMatch) {
                    $displayId = if ($upn) { $upn } else { $script:ResolvedUser.DisplayName }
                    [System.Windows.MessageBox]::Show("Access Denied: The requested user ($displayId) belongs to a different agency/domain.", "Cross-Agency Block", "OK", "Error")
                    $script:ResolvedUser = $null
                } else {
                    $HeaderString += " [$($script:ResolvedUser.DisplayName)]"

                    $userDevices = @(Get-MgUserManagedDevice -UserId $script:ResolvedUser.Id -ErrorAction Stop)

                    if ($userDevices.Count -gt 0) { 
                        $RawDeviceList += $userDevices 
                    }
                }
            } else {
                $HeaderString += " [User Not Found]"
            }
        }

        $HeaderTitle.Text = $HeaderString

        if ($RawDeviceList.Count -gt 0) {
            $script:GlobalDevices = @($RawDeviceList | Sort-Object -Property Id -Unique | Sort-Object deviceName)

            foreach ($dev in $script:GlobalDevices) {
                $status = if ($dev.ComplianceState -eq "compliant") { "[OK]" } else { "[X]" }
                $DeviceList.Items.Add("$status [$($dev.OperatingSystem)] $($dev.DeviceName) - $($dev.SerialNumber)") | Out-Null
            }
        } else {
            $DeviceList.Items.Add("No managed devices found for this user or PC.") | Out-Null
            $DeviceList.IsEnabled = $false
        }
    } catch {
        $HeaderTitle.Text = "API Error: $($_.Exception.Message)"
    }
})

$DeviceList.Add_SelectionChanged({
    if ($DeviceList.SelectedIndex -ge 0 -and $script:GlobalDevices) {
        $ActionPanel.Visibility = "Visible"
        $OutputText.Text = "Ready..."
        $selectedDev = $script:GlobalDevices[$DeviceList.SelectedIndex]

        # Reset all buttons to hidden
        $BtnBitLocker.Visibility  = "Collapsed"
        $BtnLAPS.Visibility       = "Collapsed"
        $BtnUnlock.Visibility     = "Collapsed"
        $BtnRemoteLock.Visibility = "Collapsed"
        $BtnWipe.Visibility       = "Collapsed"
        $BtnSync.Visibility       = "Collapsed"
        $BtnReboot.Visibility     = "Collapsed"

        if ($selectedDev) {
            # Windows Devices
            if ($selectedDev.OperatingSystem -match "Windows") {
                $BtnBitLocker.Visibility = "Visible"
                $BtnLAPS.Visibility      = "Visible"
                $BtnReboot.Visibility    = "Visible"
            }
            # Mobile Devices (iOS, Android, iPadOS, Mac)
            else {
                $BtnUnlock.Visibility     = "Visible"
                $BtnRemoteLock.Visibility = "Visible"
                $BtnSync.Visibility       = "Visible"
                $BtnReboot.Visibility     = "Visible"
                $BtnWipe.Visibility       = "Visible"
            }
        }
    }
})

$BtnBitLocker.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP 2: RETRIEVE BITLOCKER KEY`n`nWHEN TO USE THIS:`nUse this when a user reboots their laptop and is prompted with a blue BitLocker recovery screen.`n`nWHAT IT DOES:`nWe query the Microsoft Graph API (Entra ID) for the specific device ID to retrieve its escrowed BitLocker recovery key. We explicitly append '`$select=key' to force the API to transmit the actual password string.`n`nIN-PERSON EQUIVALENT:`nLogging into the Azure Portal, searching for the device, and clicking 'Recovery Keys'." `
        -Code "Invoke-MgGraphRequest -Method GET -Uri `"https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '`$(`$dev.AzureAdDeviceId)'&`$select=key`""

    $OutputText.Text = "UHDC: Querying Entra ID for keys..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        # Added &$select=key to force the API to return the actual password string
        $uri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$($dev.AzureAdDeviceId)'&`$select=key"
        $res = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop

        if ($res.value -and $res.value.Count -gt 0) {
            $keyStr = $res.value[0].key
            if (-not $keyStr) { $keyStr = $res.value[0].Key } # Fallback casing just in case

            if ($keyStr) {
                $OutputText.Text = "RECOVERY KEY: $keyStr" 
            } else {
                $OutputText.Text = "Key property was blank. Ensure you have the BitLockerKey.Read.All permission."
            }
        } else { 
            $OutputText.Text = "No keys found for this device." 
        }
    } catch { 
        $OutputText.Text = "BitLocker retrieval failed: $($_.Exception.Message)" 
    }
})

$BtnLAPS.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP 3: RETRIEVE CLOUD LAPS`n`nWHEN TO USE THIS:`nUse this when you need local administrator rights on an Entra-joined (cloud-only) machine to install software or change system settings.`n`nWHAT IT DOES:`nWe query the Microsoft Graph API for the device's rotating Local Administrator Password Solution (LAPS) credentials. We must use the /directory/ endpoint and pass a ConsistencyLevel header for the filter to work.`n`nIN-PERSON EQUIVALENT:`nLogging into the Intune/Entra portal, locating the device, and clicking 'Local administrator password'." `
        -Code "Invoke-MgGraphRequest -Method GET -Uri `"https://graph.microsoft.com/beta/directory/deviceLocalCredentials?`$filter=deviceId eq '`$(`$dev.AzureAdDeviceId)'&`$select=credentials`" -Headers @{ `"ConsistencyLevel`" = `"eventual`" }"

    $OutputText.Text = "UHDC: Retrieving Cloud LAPS..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        # Fixed endpoint to /directory/deviceLocalCredentials and added ConsistencyLevel header
        $uri = "https://graph.microsoft.com/beta/directory/deviceLocalCredentials?`$filter=deviceId eq '$($dev.AzureAdDeviceId)'&`$select=credentials"
        $lapsData = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ "ConsistencyLevel" = "eventual" } -ErrorAction Stop

        if ($lapsData.value -and $lapsData.value.Count -gt 0) { 
            $creds = $lapsData.value[0].credentials
            $pwd = if ($creds -is [array]) { $creds[0].password } else { $creds.password }
            $OutputText.Text = "CLOUD LAPS: $pwd" 
        } else { 
            $OutputText.Text = "No Cloud LAPS data available." 
        }
    } catch { 
        $OutputText.Text = "LAPS retrieval failed: $($_.Exception.Message)" 
    }
})

$BtnUnlock.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP 4: REMOVE MOBILE PASSCODE`n`nWHEN TO USE THIS:`nUse this when a user forgets the PIN/passcode to their company-issued iOS or Android device.`n`nWHAT IT DOES:`nWe send an MDM command through Intune to forcefully clear the lock screen passcode on the mobile device.`n`nIN-PERSON EQUIVALENT:`nLogging into the Intune portal, finding the mobile device, and clicking 'Remove passcode'." `
        -Code "Invoke-MgGraphRequest -Method POST -Uri `"https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/`$(`$dev.Id)/removeDevicePasscode`" -Body @{}"

    if ([System.Windows.MessageBox]::Show("Remove passcode from this mobile device?", "UHDC Confirm", "YesNo") -eq "Yes") {
        $OutputText.Text = "UHDC: Sending unlock command..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            # Fixed endpoint from /removePasscode to /removeDevicePasscode
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($dev.Id)/removeDevicePasscode" -Body @{} -ErrorAction Stop
            $OutputText.Text = "UHDC: Mobile unlock command dispatched."
        } catch {
            $OutputText.Text = "Unlock failed: $($_.Exception.Message)"
        }
    }
})

$BtnRemoteLock.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP X: REMOTE LOCK`n`nWHEN TO USE THIS:`nUse this when a user misplaces their mobile device but isn't sure if it's permanently lost yet.`n`nWHAT IT DOES:`nWe send an MDM command to instantly lock the device screen, requiring the PIN/Biometrics to unlock it.`n`nIN-PERSON EQUIVALENT:`nPressing the power/sleep button on the side of the phone." `
        -Code "Invoke-MgGraphRequest -Method POST -Uri `"https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/`$(`$dev.Id)/remoteLock`" -Body @{}"

    if ([System.Windows.MessageBox]::Show("Send remote lock command to $($dev.DeviceName)?", "UHDC Confirm", "YesNo") -eq "Yes") {
        $OutputText.Text = "UHDC: Sending lock command..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($dev.Id)/remoteLock" -Body @{} -ErrorAction Stop
            $OutputText.Text = "UHDC: Remote lock command dispatched."
        } catch {
            $OutputText.Text = "Lock failed: $($_.Exception.Message)"
        }
    }
})

$BtnWipe.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP 5: REMOTE WIPE`n`nWHEN TO USE THIS:`nUse this when a device is reported lost or stolen, or when an employee leaves and the device needs to be factory reset for the next user.`n`nWHAT IT DOES:`nWe send a destructive MDM command to the device instructing it to immediately factory reset and wipe all data.`n`nIN-PERSON EQUIVALENT:`nBooting into the recovery partition and selecting 'Wipe data/factory reset'." `
        -Code "Invoke-MgGraphRequest -Method POST -Uri `"https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/`$(`$dev.Id)/wipe`" -Body @{}"

    $msg = "WARNING: You are about to issue a REMOTE FACTORY RESET for $($dev.DeviceName).`n`nThis will permanently erase all data on the device. Are you absolutely sure?"
    if ([System.Windows.MessageBox]::Show($msg, "UHDC Danger: Wipe Device", "YesNo", "Warning") -eq "Yes") {
        $OutputText.Text = "UHDC: Sending wipe command..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($dev.Id)/wipe" -Body @{} -ErrorAction Stop
            $OutputText.Text = "[UHDC] Success: Wipe command dispatched to $($dev.DeviceName)."
        } catch {
            $OutputText.Text = "Wipe failed: $($_.Exception.Message)"
        }
    }
})

$BtnMFA.Add_Click({
    if (-not $script:ResolvedUser) {
        $OutputText.Text = "MFA requires a successfully linked user account."
        return
    }
    Wait-TrainingStep `
        -Desc "STEP 6: VIEW MFA METHODS`n`nWHEN TO USE THIS:`nUse this when a user claims they aren't receiving their text messages or calls for multi-factor authentication.`n`nWHAT IT DOES:`nWe query Entra ID to list all phone numbers currently registered to the user's account for authentication.`n`nIN-PERSON EQUIVALENT:`nLogging into the Entra ID portal, finding the user, and clicking 'Authentication methods'." `
        -Code "Get-MgUserAuthenticationPhoneMethod -UserId `$script:ResolvedUser.Id"

    $OutputText.Text = "UHDC: Fetching registered MFA phones..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $methods = Get-MgUserAuthenticationPhoneMethod -UserId $script:ResolvedUser.Id
        if ($methods) {
            $msg = "Registered Methods:`n"
            foreach ($m in $methods) { $msg += "- $($m.PhoneType): $($m.PhoneNumber)`n" }
            $OutputText.Text = $msg
        } else { $OutputText.Text = "No MFA phone methods found." }
    } catch { $OutputText.Text = "Failed to access authentication methods." }
})

$BtnClearMFA.Add_Click({
    if (-not $script:ResolvedUser) {
        $OutputText.Text = "MFA requires a successfully linked user account."
        return
    }
    Wait-TrainingStep `
        -Desc "STEP 7: CLEAR MFA METHODS`n`nWHEN TO USE THIS:`nUse this when a user gets a new phone number and is locked out of their account because the MFA prompts are going to their old phone.`n`nWHAT IT DOES:`nWe iterate through and delete all registered phone methods for the user. The next time they log in, Microsoft will force them to register a new method.`n`nIN-PERSON EQUIVALENT:`nClicking 'Require re-register MFA' in the Entra ID portal." `
        -Code "`$methods = Get-MgUserAuthenticationPhoneMethod -UserId `$script:ResolvedUser.Id`nforeach (`$m in `$methods) { Remove-MgUserAuthenticationPhoneMethod -UserId `$script:ResolvedUser.Id -PhoneAuthenticationMethodId `$m.Id }"

    if ([System.Windows.MessageBox]::Show("Are you sure you want to DELETE all registered MFA phone numbers for $($script:ResolvedUser.DisplayName)? They will be forced to re-register on next login.", "Clear MFA", "YesNo", "Warning") -eq "Yes") {
        $OutputText.Text = "UHDC: Clearing MFA methods..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $methods = Get-MgUserAuthenticationPhoneMethod -UserId $script:ResolvedUser.Id
            $cleared = 0
            foreach ($m in $methods) {
                Remove-MgUserAuthenticationPhoneMethod -UserId $script:ResolvedUser.Id -PhoneAuthenticationMethodId $m.Id -ErrorAction Stop
                $cleared++
            }
            $OutputText.Text = "[UHDC] Success: Cleared $cleared MFA methods. User must re-register."
        } catch { $OutputText.Text = "Failed to clear MFA: $($_.Exception.Message)" }
    }
})

$BtnAddPhone.Add_Click({
    if (-not $script:ResolvedUser) {
        $OutputText.Text = "MFA requires a successfully linked user account."
        return
    }
    $newPhone = $InputPhone.Text.Trim()
    if ($newPhone -match "^\+1") {
        Wait-TrainingStep `
            -Desc "STEP 8: ADD SMS MFA`n`nWHEN TO USE THIS:`nUse this to manually add a new phone number to a user's account so they can receive SMS codes.`n`nWHAT IT DOES:`nWe use the Graph API to inject a new 'mobile' phone authentication method directly into the user's Entra ID profile.`n`nIN-PERSON EQUIVALENT:`nHaving the user log into mysignins.microsoft.com and manually adding a phone number." `
            -Code "New-MgUserAuthenticationPhoneMethod -UserId `$script:ResolvedUser.Id -PhoneType `"mobile`" -PhoneNumber `$newPhone"

        $OutputText.Text = "UHDC: Adding $newPhone to account..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            New-MgUserAuthenticationPhoneMethod -UserId $script:ResolvedUser.Id -PhoneType "mobile" -PhoneNumber $newPhone -ErrorAction Stop
            $OutputText.Text = "[UHDC] Success: $newPhone added as primary SMS MFA."
            $InputPhone.Text = ""
        } catch { $OutputText.Text = "Error: $($_.Exception.Message)" }
    } else {
        $OutputText.Text = "Error: Use international format (+15550001111)"
    }
})

$BtnSync.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP X: FORCE SYNC`n`nWHEN TO USE THIS:`nUse this when you just pushed a new app or configuration profile in Intune and want the device to check in immediately instead of waiting 8 hours.`n`nWHAT IT DOES:`nWe send an MDM command to the device instructing it to check in with the Intune service.`n`nIN-PERSON EQUIVALENT:`nOpening Company Portal and clicking 'Sync'." `
        -Code "Invoke-MgGraphRequest -Method POST -Uri `"https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/`$(`$dev.Id)/syncDevice`" -Body @{}"

    $OutputText.Text = "UHDC: Sending sync command..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($dev.Id)/syncDevice" -Body @{} -ErrorAction Stop
        $OutputText.Text = "UHDC: Sync command dispatched."
    } catch {
        $OutputText.Text = "Sync failed: $($_.Exception.Message)"
    }
})

$BtnReboot.Add_Click({
    $dev = $script:GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep `
        -Desc "STEP X: REBOOT DEVICE`n`nWHEN TO USE THIS:`nUse this when a remote device is frozen or needs a reboot to apply an update.`n`nWHAT IT DOES:`nWe send an MDM command to the device instructing it to restart immediately.`n`nIN-PERSON EQUIVALENT:`nClicking Start > Power > Restart." `
        -Code "Invoke-MgGraphRequest -Method POST -Uri `"https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/`$(`$dev.Id)/rebootNow`" -Body @{}"

    if ([System.Windows.MessageBox]::Show("Send reboot command to $($dev.DeviceName)?", "UHDC Confirm", "YesNo") -eq "Yes") {
        $OutputText.Text = "UHDC: Sending reboot command..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($dev.Id)/rebootNow" -Body @{} -ErrorAction Stop
            $OutputText.Text = "UHDC: Reboot command dispatched."
        } catch {
            $OutputText.Text = "Reboot failed: $($_.Exception.Message)"
        }
    }
})

$Form.ShowDialog() | Out-Null
