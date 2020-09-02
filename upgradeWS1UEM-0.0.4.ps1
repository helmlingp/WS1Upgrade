﻿<#
========================================================================
 Created on:    10 May 2019
 Created by:    Phil Helmling (adapted from installAirWatch-1.0.0.ps1 05/25/2018 by Tai Ratcliff)
 Organization:  VMware
 Filename:      upgradeWS1UEM-0.0.3.ps1
 Example:       upgradeWS1UEM-0.0.3.ps1 -WS1ConfigJson WS1Config.json
 Requirements:  needs VMware PowerCLI Module. From Powershell session run Install-Module -Name VMware.PowerCLI
                Powershell "set-executionpolicy unrestricted" & "Enable-PSRemoting -Force"
                needs Installer and Tools subdirectories which are configurable in config.json
                Place WS1 installer ZIP files in Installer subdirectory.
                Place 7-ZIP.exe in Tools subdirectory.
========================================================================
#>

$current_path = $PSScriptRoot;
if ($PSScriptRoot -eq "") {
    $current_path = "C:\Airwatch";
}

#Setup Logging
$logdate = '{0:yyymmddhhmm}' -f (Get-Date)
$logdate_WS1upgrade = $logdate + "_WS1upgrade.log"
$Logfile = Join-Path -Path $current_path -ChildPath $logdate_WS1upgrade
Start-Transcript -Path $Logfile -Force

#Get config from JSON file that was passed as a parameter
#$WS1ConfigJson = [String]$args
If(! $WS1ConfigJson){
    Write-Host "WS1Config JSON file is a required parameter" `n -ForegroundColor Red
    Exit
} Else {
    #Testing for JSON file and reading in config items
    If (!(Test-Path $WS1ConfigJson)) {
        throw "Could not validate the path provided for the Config JSON file!"
    }
    $WS1ConfigJsonPath = Join-Path -Path $current_path -ChildPath $WS1ConfigJson
    $WS1Config = Get-Content -Path $WS1ConfigJsonPath | ConvertFrom-Json
}

$error.Clear()

#Config Powershell Interface
$OriginalBackground = $Host.UI.RawUI.BackgroundColor
$NewBackground = "DarkGray"
$Host.UI.RawUI.BackgroundColor = $NewBackground
Clear-Host
# Set the PowerShell preference variables
$WarningPreference = "SilentlyContinue"
$ConfirmPreference = "None"
#$LogCommandHealthEvent = $true

# Remove any existing jobs that were not properly removed from previous executions
Remove-Job * | Out-Null

# Import PowerShell modules and test correct version of PowerCLI
Try {
    If (!(Get-Module VMware*)) {
        Write-Host "`n`n********Importing vCenter PowerShell modules********"
        Get-Module –ListAvailable VM* | Import-Module
    }
} Catch {
    throw "Failed to import the VMware PowerShell Modules for vCenter. You will need to import and install these modules manually before continuing."
}

#PowerCLI 6 is required due to OvfConfiguration commands.
[int]$PowerCliMajorVersion = (Get-PowerCLIVersion).major
if ( -not ($PowerCliMajorVersion -ge 6 ) ) { throw "PowerCLI version 6 or above is required" }

# Configure settings to allow connections to multiple vCenter Servers
$ErrorActionPreference = "SilentlyContinue"
#Set-PowerCLIConfiguration -DefaultVIServerMode multiple -Confirm:$false
Write-Host "Ignore the following notification block"
Set-PowerCLIConfiguration -InvalidCertificateAction ignore -Confirm:$false
# Disconnect from any existing vSphere or vCenter connections that were not properly disconnected from previous exections
Disconnect-VIServer * -Confirm:$false
$ErrorActionPreference = "Continue"

$Quit = $false
$error.Clear()

# Global variables from JSON
#$globalConfig = $WS1Config.globalConfig
$PrivCenter = $WS1Config.PrimaryWorkloadServers.vCenter.FQDN
$PridmzvCenter = $WS1Config.PrimaryDMZServers.vCenter.FQDN
$SecvCenter = $WS1Config.SecondaryWorkloadServers.vCenter.FQDN
$SecdmzvCenter = $WS1Config.SecondaryDMZServers.vCenter.FQDN

# Script specific variables from JSON
#Local Dirs
$toolsDir = Join-Path -Path $current_path -ChildPath $WS1Config.globalConfig.deploymentDirectories.toolsDir
$InstallerDir = Join-Path -Path $current_path -ChildPath $WS1Config.globalConfig.deploymentDirectories.InstallerDir
$PrereqsDir = $WS1Config.globalConfig.deploymentDirectories.PrereqsDir
$DBInstallerDir = $WS1Config.globalConfig.deploymentDirectories.DBInstallerDir
$AppInstallerDir = $WS1Config.globalConfig.deploymentDirectories.AppInstallerDir
#Remote Dirs
$destinationDir = $WS1Config.globalConfig.deploymentDirectories.destinationDir

# Import arrays of VMs to deploy
$priAppServers = $WS1Config.PrimaryWorkloadServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$secAppServers = $WS1Config.SecondaryWorkloadServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$priDMZAppServers = $WS1Config.PrimaryDMZServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$secDMZAppServers = $WS1Config.SecondaryDMZServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$PriDBServers = $WS1Config.PrimaryWorkloadServers.servers | Where-Object {$_.Role -like "DB"}
$secDBServers = $WS1Config.SecondaryWorkloadServers.servers | Where-Object {$_.Role -like "DB"}
$URLs = $WS1Config.PrimaryWorkloadServers.URLs

#ask for Credentials to connect to Windows VMs using PS-Execute
$Credential = $host.ui.PromptForCredential("Windows credentials", "Please enter your Windows user name and password for Windows VMs.", "", "NetBiosUserName")
#$VCPriCred = $host.ui.PromptForCredential("Primary site vC credentials", "Please enter your user name and password for the Primary Site vCenter.", "", "NetBiosUserName")
#$VCDMZPriCred = $host.ui.PromptForCredential("Primary site DMZ vC credentials", "Please enter your user name and password for the Primary Site DMZ vCenter.", "", "NetBiosUserName")
#$VCSecCred = $host.ui.PromptForCredential("Secondary site vC credentials", "Please enter your user name and password for the Secondary Site vCenter.", "", "NetBiosUserName")
#$VCDMZSecCred = $host.ui.PromptForCredential("Secondary site DMZ vC credentials", "Please enter your user name and password for the Secondary Site DMZ vCenter.", "", "NetBiosUserName")

Function Invoke-StageFiles {
    param(
        [Array] $vmArray,
        [String] $stagevCenter
        #[String] $vcCreds
    )
    #$completedVMs = @()
    
    For ($i = 0; $i -lt $vmArray.count; $i++) {
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)) { Continue }
        
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        $vmIP = $vmArray[$i].IP
        $vmRole = $vmArray[$i].Role
        Write-Host "--------------------------STAGING--------------------------"
        # First try to copy WS1 files with PowerShell because it is much faster. If this fails, use VMTools.
        $connectby = Invoke-CheckVMConnectivity -vmName $vmName -vmFqdn $vmFqdn -vmIP $vmIP -stagevCenter $stagevCenter
        if($connectby -eq "WinRMFQDN") {
            Invoke-PSCopy -vmName $vmName -vmFqdn $vmFqdn -vmRole $vmRole}
        elseif ($connectby -eq "WinRMIP") {
            Invoke-PSCopy -vmName $vmName -vmIP $vmIP -vmRole $vmRole}
        elseif ($connectby -eq "VMTOOLS") {
            Invoke-VMToolsCopy -vmName $vmName -vmFqdn $vmFqdn -vmRole $vmRole -stagevCenter $stagevCenter}
        else {
            Write-Host "Can't connect to $vmName over the network or VMTools. Please Stage files manually." -ForegroundColor Red
        }

        If ($i -eq $vmArray.Count) {
            #Done
            Write-Host "Completed staging Install files for $vmName" `n -ForegroundColor Yellow
        }
        Else {
            Continue
        }
    }
}

function UpgradeAirWatchDb{
    param(
        [String]$guestOsAccount,
        [String]$guestOsPassword,
        [String]$vmName
    )

    # Script Block to test network communication from CN server to DB server
    $dbAvailable = @"
        # Check if network is accessible
        Write-Host "Testing $IS_SQLSERVER_SERVER SQL server connection from $vmName"
        if(Test-Connection -ComputerName $IS_SQLSERVER_SERVER -Count 1 -Quiet -ErrorAction SilentlyContinue){
            `$dbAvailable = `$true	
            return `$dbAvailable
        } else {
            `$dbAvailable = `$false
            Write-Host "Unable to reach $IS_SQLSERVER_SERVER over the network!"
            return `$dbAvailable
        }
"@

    $dbSetupSuccessfullyCmd = @"
    Get-Item -Path $deploymentDestinationDirectory\AirWatch_Database_Publish.log | Select-String -Pattern "Update complete"
"@
    
    # Test DB network connectivity and stop execution if it can't be contacted over the network.
    $dbCheck = Invoke-VMScript -ScriptText $dbAvailable -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
    If(! $dbCheck){
        throw "The AirWatch DB is not accessible over the network from $vmName"
    }

    Write-Host "`nInstalling AirWatch DB. This may take a while." `n -ForegroundColor Yellow
	
	# Run the command to install the AirWatch DB  
    $installDbScriptBlock = [scriptblock]::Create("CMD /C $airwatchDbInstallDestinationPath /s /V`"/qn /lie $deploymentDestinationDirectory\AirWatch_Database_InstallLog.log AWPUBLISHLOGPATH=$deploymentDestinationDirectory\AirWatch_Database_Publish.log TARGETDIR=$INSTALLDIR INSTALLDIR=$INSTALLDIR  IS_SQLSERVER_AUTHENTICATION=$IS_SQLSERVER_AUTHENTICATION IS_SQLSERVER_SERVER=$IS_SQLSERVER_SERVER IS_SQLSERVER_USERNAME=$IS_SQLSERVER_USERNAME IS_SQLSERVER_PASSWORD=$IS_SQLSERVER_PASSWORD IS_SQLSERVER_DATABASE=$IS_SQLSERVER_DATABASE`"")

    Invoke-VMScript -ScriptText $installDbScriptBlock -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword

	#Check the install worked by looking for this line in the publish log file - "Updating database (Complete)"
    $dbSetupSuccessfully = Invoke-VMScript -ScriptText $dbSetupSuccessfullyCmd -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
    If($dbSetupSuccessfully -notlike "Update complete"){
        throw "Failed to setup database. Could not find a line in the Publish log that contains `"Update complete`""
    } Else {
        Write-Host "AirWatch database has been successfully installed" `n -ForegroundColor Green
    }
}

function Invoke-InstallPrereqs {
    param(
        [String]$guestOsAccount,
        [String]$guestOsPassword,
        [switch]$installPfxFile,
        [string]$commonName,
        [array]$vmArray,
        [String] $stagevCenter
    )

    #$completedVMs = @()

    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        $vmRole = $vmArray[$i].Role

<#         If( ! (checkVmTools $vmName)){
            Write-Error "$vmName VMTools is not responding on $vmName!!"
            break
        }

        $completedVMs += (Get-VM -Name $vmName) #>

        Write-Host "--------------------------PREREQS--------------------------"
        # First try to copy WS1 files with PowerShell because it is much faster. If this fails, use VMTools.
        $connectby = Invoke-CheckVMConnectivity -vmName $vmName -vmFqdn $vmFqdn -vmIP $vmIP -stagevCenter $stagevCenter
<#         if($connectby -eq "WinRMFQDN") {
            Invoke-PSCopy -vmName $vmName -vmFqdn $vmFqdn -vmRole $vmRole}
        elseif ($connectby -eq "WinRMIP") {
            Invoke-PSCopy -vmName $vmName -vmIP $vmIP -vmRole $vmRole}
        elseif ($connectby -eq "VMTOOLS") {
            Invoke-VMToolsCopy -vmName $vmName -vmFqdn $vmFqdn -vmRole $vmRole -stagevCenter $stagevCenter}
        else {
            Write-Host "Can't connect to $vmName over the network or VMTools. Please Stage files manually." -ForegroundColor Red
        } #>
        if ($connectby -eq "NOVM" -Or $connectby -eq "NOVMTOOLS") {
            Write-Host "Can't connect to $vmName over the network or VMTools. Please install prereqs manually." -ForegroundColor Red
        }

        # The AirWatch DS server required an external trusted SSL certificate to be used
$importPfxScript = @"
CertUtil -f -p "$pfxPassword" -importpfx "$pfxDestinationFilePath"
"@
# AirWatch Prerequisites install script here-string
$airwatchPreRequisitesScript = @"
# Add server roles
Install-WindowsFeature Web-Server, Web-WebServer, Web-Common-Http, Web-Default-Doc, Web-Dir-Browsing, Web-Http-Errors, Web-Static-Content, Web-Http-Redirect, Web-Health, Web-Http-Logging, Web-Custom-Logging, Web-Log-Libraries, Web-Request-Monitor, Web-Http-Tracing, Web-Performance, Web-Stat-Compression, Web-Dyn-Compression, Web-Security, Web-Filtering, Web-IP-Security, Web-App-Dev, Web-Net-Ext, Web-Net-Ext45, Web-AppInit, Web-ASP, Web-Asp-Net, Web-Asp-Net45, Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Includes, Web-Mgmt-Tools, Web-Mgmt-Console, Web-Mgmt-Compat, Web-Metabase -Source $windowsDestinationSxsFolderPath

# Add server features
Install-WindowsFeature NET-Framework-Features, NET-Framework-Core, NET-Framework-45-Features, NET-Framework-45-Core, NET-Framework-45-ASPNET, NET-WCF-Services45, NET-WCF-HTTP-Activation45, NET-WCF-MSMQ-Activation45, NET-WCF-Pipe-Activation45, NET-WCF-TCP-Activation45, NET-WCF-TCP-PortSharing45, MSMQ, MSMQ-Services, MSMQ-Server, Telnet-Client

# Get the certificate thumbprint
`$certThumbprint = (Get-ChildItem Cert:\LocalMachine\My | Where {`$_.Subject -like "*CN=$commonName*"} | Select-Object -First 1).Thumbprint

# IIS site mapping ip/hostheader/port to cert - also maps certificate if it exists for the particular ip/port/hostheader combo
New-WebBinding -name "$iisSite" -Protocol https -HostHeader $commonName -Port 443 -SslFlags 1 #-IP "*"

# Bind certificate to IIS site
`$bind = Get-WebBinding -Name "$iisSite" -Protocol https -HostHeader $commonName
`$bind.AddSslCertificate(`$certThumbprint, "My")
"@

$unzipCMD = @"
Add-Type -assembly "system.io.compression.filesystem"
[System.IO.Compression.ZipFile]::ExtractToDirectory("$windowsDestinationSxsZipPath", "$deploymentDestinationDirectory")
"@

$servicesTimeoutRegistryCmd = @'
$registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control"
$dwordName = "ServicesPipeTimeout"
$dwordValue = "180000"

New-ItemProperty -Path $registryPath -Name $dwordName -Value $dwordValue -Type DWORD -Force | Out-Null
'@

        If($cnInstall){
            Copy-VMGuestfile -LocalToGuest -source $cnConfigXmlPath -destination $destinationConfigFilesDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }
        If($dsInstall){
            Copy-VMGuestfile -LocalToGuest -source $dsConfigXmlPath -destination $destinationConfigFilesDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }
        If($apiInstall){    
            Copy-VMGuestfile -LocalToGuest -source $apiConfigXmlPath -destination $destinationConfigFilesDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }

        $dotNetInstallCMD = "CMD /C `"$dotNetDestinationPath /q /norestart`""
        $JavaInstallCMD = "CMD /C `"jre-8u261-windows-x64.exe INSTALL_SILENT=Enable SPONSORS=0`""
        
        $createDestinationDirectoryCMD = "If(!(Test-Path -Path $deploymentDestinationDirectory)){New-Item -Path $deploymentDestinationDirectory -ItemType Directory | Out-Null}"
        $createDestinationConfigDirectoryCMD = "If(!(Test-Path -Path $destinationConfigFilesDirectory)){New-Item -Path $destinationConfigFilesDirectory -ItemType Directory | Out-Null}"

        # Create a Windows registry key to extend the timeout value to start services. The AirWatch services can often take longer than 30 seconds to start.
        Invoke-VMScript -ScriptText $servicesTimeoutRegistryCmd -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell

        Write-Host "Copying AirWatch prerequisite files to $vmName" -ForegroundColor Yellow `n
        # Check the destination directory exists on the VM and if not, create it.
        Invoke-VMScript -ScriptText $createDestinationDirectoryCMD -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
        # Create the destination directory for the AirWatch install files
        Write-Host "Copying AirWatch install files to $vmName" -ForegroundColor Yellow `n
        Invoke-VMScript -ScriptText $createDestinationConfigDirectoryCMD -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell

        # Copy pfx files and windows source\sxs files to the guest
        If($installPfxFile){
            Copy-VMGuestfile -LocalToGuest -source $pfxSourceFilePath -destination $deploymentDestinationDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
            Write-Host "Importing the PFX certificate on $vmName" `n -ForegroundColor Yellow
            Invoke-VMScript -ScriptText $importPfxScript -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }
        # Copy the required files to the destination VM
        Write-Host "Copying the Windows source sxs folder to $deploymentDestinationDirectory on $vmName" -ForegroundColor Yellow
        Copy-VMGuestfile -LocalToGuest -source $windowsSourceSxsZipPath -destination $deploymentDestinationDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        Write-Host "Copying the .Net 4.6.2 offline install files to $deploymentDestinationDirectory" -ForegroundColor Yellow
        Copy-VMGuestfile -LocalToGuest -source $dotNetSourcePath -destination $deploymentDestinationDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword

        # Unzip the windows sxs file to the local deployment directory
        Write-Host "Extracting the Windows source sxs folder to $deploymentDestinationDirectory on $vmName" `n -ForegroundColor Yellow
        Invoke-VMScript -ScriptText $unzipCMD -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword

        # Run the AirWatch prerequisite install script
        Write-Host "Running the AirWatch prequisite installation script on $vmName" `n -ForegroundColor Yellow
        Invoke-VMScript -ScriptText $airwatchPreRequisitesScript -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        
        # Run the .NET install CMD
        Write-Host "Install .Net on $vmName" `n -ForegroundColor Yellow
        Invoke-VMScript -ScriptText $dotNetInstallCMD -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType powershell
        
        # Run the Java install CMD
        Write-Host "Install .Net on $vmName" `n -ForegroundColor Yellow
        Invoke-VMScript -ScriptText $JavaInstallCMD -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType powershell
        
        # First try to copy AirWatch files with PowerShell because it is much faster. If this fails, use VMTools.
        If(checkVMNetwork $vmFqdn){
            $psSession = CreatePsSession -ServerFqdn $vmFqdn -ServerUser $guestOsAccount -ServerPass $guestOsPassword
            Write-Host "Using PoweShell remote session to copy files to $vmName" `n -ForegroundColor Yellow
            Copy-Item -ToSession $psSession -Path $airwatchInstallSourceFolderPath -Destination $deploymentDestinationDirectory -Recurse -Force -Confirm:$false
        }
        
        # Check if the AirWatch install files are already in the destination directory. This allows them to be copied with PowerShell or manually copied across before being forced to use VMTools to copy the files.
        $airwatchInstallFolderExistsCMD = [ScriptBlock]::Create("Test-Path -Path $airwatchAppInstallDestinationBinary")
        $airwatchInstallFolderExists = (Invoke-VMScript -ScriptText $airwatchInstallFolderExistsCMD -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType powershell).ScriptOutput
        If(! $airwatchInstallFolderExists){
            Write-Host "The AirWatch Install files were not found on the destination server. Now using VMTools to copy the files, which will take a long time!" `n -ForegroundColor Red
            # Use 7zip to compress the AirWatch installation files into separate 200MB files that aren't too big to copy with VMTools. 
            If(! $airwatchZipFiles){
                Write-Host "Zipping the AirWatch install files into 200MB files that can be copied with VMTools to $vmName" `n -ForegroundColor Yellow
                $zipOutput = Invoke-Expression -Command "$7zipSourceFolderPath\7z.exe a -y -mx1 -v200m $deploymentSourceDirectory\AirWatch_Install.7z $airwatchInstallSourceFolderPath"
                If ($zipOut -like "*Error:*"){
                    throw "7zip failed to zip the AirWatch install files"
                }
            }

            # Capture each of the AirWatch zip files and copy them to the destionation server
            $airwatchZipFiles = Get-ChildItem -Path $deploymentSourceDirectory | Where-Object {$_ -like "AirWatch_Install.7z*"}        
        
            # Copy each of the zip files to the destination VM. This takes a long time to use VMTools, but it means we can copy the files to VMs located in the DMZ that don't have direct network access
            foreach($file in $airwatchZipFiles){
                Write-Host "Copying $file of $($airwatchZipFiles.count) total files to $vmName" -ForegroundColor Yellow            
                Copy-VMGuestfile -LocalToGuest -source $file.FullName -destination $deploymentDestinationDirectory -Force -vm $vmName -guestuser "$guestOsAccount" -guestpassword "$guestOsPassword"
            }

            # Copy 7zip files to destination VM so that the zip files can be unzipped
            Write-Host "Copying 7-zip to $vmName" `n -ForegroundColor Yellow
            Copy-VMGuestfile -LocalToGuest -source $7zipSourceFolderPath -destination $deploymentDestinationDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword

            # Unzip the AirWatch files on the destination server
            Write-Host "Unzipping the AirWatch install files on $vmName" `n -ForegroundColor Yellow
            $unzipAirWatch = [ScriptBlock]::Create("CMD /C `"$7zipDestinationFolderPath\7z.exe x $deploymentDestinationDirectory\AirWatch_Install.7z.001 -o$deploymentDestinationDirectory -y`"")
            Invoke-VMScript -ScriptText $unzipAirWatch -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
        }

        # Copy the Config files to the destination server
        Write-Host "Copying the AirWatch config XML files to $vmName" `n -ForegroundColor Yellow
        If($cnInstall){
            Copy-VMGuestfile -LocalToGuest -source $cnConfigXmlPath -destination $destinationConfigFilesDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }
        If($dsInstall){
            Copy-VMGuestfile -LocalToGuest -source $dsConfigXmlPath -destination $destinationConfigFilesDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }
        If($apiInstall){    
            Copy-VMGuestfile -LocalToGuest -source $apiConfigXmlPath -destination $destinationConfigFilesDirectory -Force:$true -vm $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
        }

        # Restart the VM 
        Write-Host "Restarting $vmName to complete the prerquisite install" `n -ForegroundColor Yellow
        Restart-VMGuest -VM $vmName -Confirm:$false

        Write-Host "Finished the AirWatch prerequisite installs" `n -ForegroundColor Green
    }
    return $completedVMs
}

function Invoke-InstallPhase1 {
    param(
        [String]$guestOsAccount,
        [String]$guestOsPassword,
        [Array]$vmArray,
        [Parameter(ParameterSetName='CN_Install')]
        [Switch]$CnInstall,
        [Parameter(ParameterSetName='DS_Install')]
        [Switch]$DsInstall,
        [Parameter(ParameterSetName='API_Install')]
        [Switch]$ApiInstall
    )

    $awSetupSuccessfullyCmd = @"
    Get-Item -Path $deploymentDestinationDirectory\AppInstall.log | Select-String -Pattern "Installation operation completed successfully"
"@

    for($i = 0; $i -lt $vmArray.count; $i++){ 
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name

	    Write-Host "Installing AirWatch on $($vmName). This will take a while."
        If($CnInstall){
            $ConfigFile = $cnConfigXmlDestinationPath
        }
        If($DsInstall){
            $ConfigFile = $dsConfigXmlDestinationPath
        }
        If($ApiInstall){
            $ConfigFile = $apiConfigXmlDestinationPath
        }

        # Run the command to install the AirWatch App  
        $installAppScriptBlock = [scriptblock]::Create("CMD /C $airwatchAppInstallDestinationBinary /s /V`"/qn /lie $deploymentDestinationDirectory\AppInstall.log TARGETDIR=$INSTALLDIR INSTALLDIR=$INSTALLDIR AWIGNOREBACKUP=true AWSTAGEAPP=true AWSETUPCONFIGFILE=$ConfigFile`"")
        Invoke-VMScript -ScriptText $installAppScriptBlock -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell

        #Check the install worked by looking for this line in the publish log file - "Updating database (Complete)"
        $awSetupSuccessfully = Invoke-VMScript -ScriptText $awSetupSuccessfullyCmd -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
        If($awSetupSuccessfully -notlike "*Installation operation completed successfully*"){
            #throw "Failed to setup AirWatch App. Could not find a line in the Publish log that contains `"Installation operation completed successfully`""
        } Else {
            Write-Host "AirWatch App has been successfully installed" `n -ForegroundColor Green
        }

        # Restart IIS to start AirWatch
        Invoke-VMScript -ScriptText "iisreset" -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell

            <# If($installCn){ 
        # Snapshot the CN VMs before starting the install
        snapshotVMs -vmArray $airwatchCnServers -snapshotName "Installing AirWatch"
    
        # Start the AirWatch prerequisite installs on the CN Servers
        installAirWatchPrereqs -vmArray $airwatchCnServers -commonName $airwatchCnCommonName -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword -cnInstall
        waitForVMs -vmArray $airwatchCnServers
    }
    
    If($installDb){
        # Install the AirWatch DB from the first CN Server
        InstallAirWatchDb -vmName $dbInstallVM -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword    
    }
    
    If($installCn){    
        Write-Host "Install the AirWatch CN Servers in the internal environment" `n -ForegroundColor Yellow
    
        # Install AirWatch on the CN Servers.
        InstallAirwatch -vmArray $airwatchCnServers -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword -CnInstall
        
        # Check the install was successfull by use the Web API to see if it responds before continuing
        Check-Web -URL $cnUrl
    } #>
    }
}

function Invoke-InstallPhase2 {
    param(
        [String]$guestOsAccount,
        [String]$guestOsPassword,
        [Array]$vmArray,
        [Parameter(ParameterSetName='CN_Install')]
        [Switch]$CnInstall,
        [Parameter(ParameterSetName='DS_Install')]
        [Switch]$DsInstall,
        [Parameter(ParameterSetName='API_Install')]
        [Switch]$ApiInstall
    )

    $awSetupSuccessfullyCmd = @"
    Get-Item -Path $deploymentDestinationDirectory\AppInstall.log | Select-String -Pattern "Installation operation completed successfully"
"@

    for($i = 0; $i -lt $vmArray.count; $i++){ 
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name

	    Write-Host "Running Phase 2 install of AirWatch on $($vmName). This will take a while."
        If($CnInstall){
            $ConfigFile = $cnConfigXmlDestinationPath
        }
        If($DsInstall){
            $ConfigFile = $dsConfigXmlDestinationPath
        }
        If($ApiInstall){
            $ConfigFile = $apiConfigXmlDestinationPath
        }

        # Run the command to install the AirWatch App  
        $installAppScriptBlock = [scriptblock]::Create("CMD /C $airwatchAppInstallDestinationBinary /s /V`"/qn /lie $deploymentDestinationDirectory\AppInstall.log TARGETDIR=$INSTALLDIR INSTALLDIR=$INSTALLDIR AWIGNOREBACKUP=true AWSTAGEAPP=true AWSETUPCONFIGFILE=$ConfigFile`"")
        Invoke-VMScript -ScriptText $installAppScriptBlock -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell

        #Check the install worked by looking for this line in the publish log file - "Updating database (Complete)"
        $awSetupSuccessfully = Invoke-VMScript -ScriptText $awSetupSuccessfullyCmd -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
        If($awSetupSuccessfully -notlike "*Installation operation completed successfully*"){
            #throw "Failed to setup AirWatch App. Could not find a line in the Publish log that contains `"Installation operation completed successfully`""
        } Else {
            Write-Host "AirWatch App has been successfully installed" `n -ForegroundColor Green
        }

        # Restart IIS to start AirWatch
        Invoke-VMScript -ScriptText "iisreset" -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
    }
}

Function Invoke-VMToolsCopy {
    param(
        [String] $vmName,
        [String] $vmFqdn,
        [String] $stagevCenter
        #[String] $vcCreds
    )
    
    If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
        $vcCreds = Get-Credential
        New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
        Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
        }
    Else{
        Connect-VIServer $stagevCenter -SaveCredentials
    }
    
    #Check if VMtools installed and we can talk to the VM
    If ( ! (Invoke-CheckVmTools $vmName)) {
        Write-Error "$vmName VMTools is not responding on $vmName!! Can't stage files to this VM.";Continue
    }
    Else {
        #Check if enough free disk space
        $destDrive = $destinationDir.Substring(0,1)
        $script = @'

        $drive = Get-PSDrive #$destDrive#
        $drivefree = $drive.Free/1GB
'@
        # Get the correct value in the variables, then replace the marker in the string with that value
        $testfreespaceScriptBlock = $script.Replace('#$destDrive#',$destDrive)
        $testfreespace = Invoke-VMScript -ScriptText $testfreespaceScriptBlock -VM $vmName -GuestCredential $Credential -ScriptType Powershell
        Write-Host "current free disk space is $testfreespace"

        If ( $testfreespace -lt 10) {
            Write-Host "Target server $vmName does not have more than 10GB free disk space. Cannot continue."; `n 
            Continue
        }
        Else {                    
            #Check if $destinationDir exists
            $destinationFolderExists = (Invoke-VMScript -ScriptText {Test-Path -Path $destinationDir} -VM $vmName  -GuestCredential $Credential -ScriptType Powershell)
            
            If ( ! $destinationFolderExists) {
                #Create destination folder
                Write-Host "Creating $destinationDir folder path to $vmName" -ForegroundColor Yellow
                
                $newdestinationDirCMD = "New-Item -Path $destinationDir -ItemType Directory"
                Invoke-VMScript -ScriptText $newdestinationDirCMD -VM $vmName -GuestCredential $Credential
                $desttoolsDirCMD = "New-Item -Path $desttoolsDir -ItemType Directory"
                Invoke-VMScript -ScriptText $desttoolsDirCMD -VM $vmName -GuestCredential $Credential
            }
<#             write-host "Check if $destinationDir exists first"
            $existsdestinationDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:destinationDir}            
            If (! $existsdestinationDir) {
                #Create base destination folders
                Write-Host "Creating destination base folder $destinationDir on $vmName" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:destinationDir -ItemType Directory}
                }
            Else {
                #Base Directory exists
            }
            
            $existsdestInstallerDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:destInstallerDir}
            If (! $existsdestInstallerDir) {
                #Create destination Installer folders
                Write-Host "Creating $destInstallerDir folder in $destinationDir path to $vmName" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock {Get-Item -Path $using:destinationDir | New-Item -Name $destInstallerDir -Path $_.FullName -ItemType Directory}
                #Invoke-Command -Session $Session -ScriptBlock {New-Item -Name $using:InstallerDir -Path $using:destinationDir -ItemType Directory}
                }
            Else {
                #Installer Directory exists
            }

            $existsdesttoolsDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:desttoolsDir}
            If (! $existsdesttoolsDir) {
                #Create destination Tools folders
                Write-Host "Creating $desttoolsDir folder in $destinationDir path to $vmName" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock {Get-Item -Path $using:destinationDir | New-Item -Name $desttoolsDir -Path $_.FullName -ItemType Directory}
                #Invoke-Command -Session $Session -ScriptBlock {New-Item -Name $using:toolsDir -Path $using:destinationDir -ItemType Directory}
                }
            Else {
                #Tools Directory exists
            } #>

            Else {
                # Use 7zip to compress the WS1 installation files into separate 200MB files that aren't too big to copy with VMTools.
                Write-Host "Zipping the WS1 install files into 200MB files on local machine that can be copied with VMTools to $vmName" -ForegroundColor Yellow
                $7zipsplitCMD = {"$toolsDir\7z.exe a -y -mx1 -v200m $InstallerDir\WS1_Install.7z $InstallerDir"}
                $zipsplitOutput = Invoke-Command -ScriptBlock $7zipsplitCMD
                If ($zipsplitOutput -like "*Error:*") {
                    throw "7zip failed to zip the WS1 install files"
                }
                
                # Capture each of the WS1 zip files and copy them to the destination server
                $7zipsplitFiles = Get-ChildItem -Path $InstallerDir | Where-Object { $_ -like "WS1_Install.7z*" }
                
                # Copy each of the zip files to the destination VM. This takes a long time to use VMTools, but it means we can copy the files to VMs located in the DMZ that don't have direct network access
                foreach ($file in $7zipsplitFiles) {
                    Write-Host "Copying $file of $($7zipsplitFiles.count) total files to $vmName" -ForegroundColor Yellow
                    Copy-VMGuestFile -LocalToGuest -source $file.FullName -destination $destinationDir -Force -vm $vmName -GuestCredential $Credential 
                }
                Copy-Item -ToSession $session -Path $toolsDir -Destination $destinationDir -Recurse -Force -Confirm:$false

                # Copy Tools directory containing 7zip to destination VM so that the zip files can be unzipped
                Write-Host "Copying 7-zip to $vmName" -ForegroundColor Yellow
                Copy-VMGuestFile -LocalToGuest -source $toolsDir -destination $desttoolsDir -Force:$true -vm $vmName -GuestCredential $Credential

                # Unzip the WS1 files on the destination server
                Write-Host "Unzipping the WS1 install files on $vmName" -ForegroundColor Yellow
                $unzip7zipsplitFiles = "CMD /C $desttoolsDir\7z.exe x $destinationDir\WS1_Install.7z.001 -o$destinationDir -y"
                Invoke-VMScript -ScriptText $unzip7zipsplitFiles -VM $vmName -GuestCredential $Credential -ScriptType PowerShell
                
                Disconnect-VIServer * -Force -Confirm:$false
                
                $CheckVMToolsCopy =  $true
                return $CheckVMToolsCopy
            }
        }
    }
}

Function Invoke-PSCopy {
    param(
        [String] $vmName,
        [String] $vmFqdn,
        [String] $vmRole,
        [Switch] $dbInstall,
        [Parameter(ParameterSetName='CN_Install')]
        [Switch] $cnInstall,
        [Parameter(ParameterSetName='DS_Install')]
        [Switch] $dsInstall,
        [Parameter(ParameterSetName='API_Install')]
        [Switch] $apiInstall
    )

    $Session = Invoke-CreatePsSession -ServerFqdn $vmFqdn


    #Check if we can connect via Powershell
    If ( $Session -is [System.Management.Automation.Runspaces.PSSession] ) {
        Write-Host "Using PowerShell remote session to copy files to $vmName" -ForegroundColor Yellow
        #Check if enough free disk space
        $destDrive = $destinationDir.SubString(0,1)
        $remoteServerDrive = Invoke-Command -Session $Session -ScriptBlock { Get-PSDrive $using:destDrive }
        $testfreespace = $($remoteServerDrive.Free/1GB)
        
        $desttoolsDir = $destinationDir + "\" + $WS1Config.globalConfig.deploymentDirectories.toolsDir
        $destInstallerDir = $destinationDir + "\" + $WS1Config.globalConfig.deploymentDirectories.InstallerDir

        #Write-Host "current free disk space is $testfreespace"        
        If ( $testfreespace -lt 10) {
            Write-Host "Target server $vmName does not have more than 10GB free disk space. Cannot continue." `n -ForegroundColor Red;Continue
            }
        Else {
            write-host "Check if $destinationDir exists first"
            $existsdestinationDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:destinationDir}            
            If (! $existsdestinationDir) {
                #Create base destination folders
                Write-Host "Creating destination base folder $destinationDir on $vmName" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:destinationDir -ItemType Directory}
                }
            Else {
                #Base Directory exists
            }
            
            $existsdestInstallerDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:destInstallerDir}
            If (! $existsdestInstallerDir) {
                #Create destination Installer folders
                Write-Host "Creating $destInstallerDir folder in $destinationDir to $vmName" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:destInstallerDir -ItemType Directory}
                }
            Else {
                #Installer Directory exists
            }

            $existsdesttoolsDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:desttoolsDir}
            If (! $existsdesttoolsDir) {
                #Create destination Tools folders
                Write-Host "Creating $desttoolsDir folder in $destinationDir to $vmName" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:desttoolsDir -ItemType Directory}
                }
            Else {
                #Tools Directory exists
            }

            #Copy files
            write-host "Copying ToolsDir files to $vmName"
            Copy-Item -ToSession $session -Path $toolsDir -Destination $desttoolsDir -Recurse -Force -Confirm:$false
                        
            #Copy installer zip file to destination $BaseInstallerDir
            $WS1InstallerZipFiles = Get-ChildItem -Path $InstallerDir | Where-Object { $_ -like "*.zip" }
            foreach ($file in $WS1InstallerZipFiles) {
                Write-Host "Copying $file of a $($WS1InstallerZipFiles.count) total files to $vmName" -ForegroundColor Yellow
                Copy-Item -ToSession $Session -Path $file.FullName -Destination $destinationDir -Recurse -Force -Confirm:$false
                $destzipfile = $destinationDir + "\" + $file
                write-host "Expanding $destzipfile to $destInstallerDir"
                Invoke-Command -session $Session -ScriptBlock {Expand-Archive -Path "$using:destzipfile" -DestinationPath "$using:destInstallerDir" -Force}
            }
        #Disconnect from Windows Server
        Remove-PSSession $Session
        
        $CheckPSCopy =  $true
        return $CheckPSCopy
        }
    else {
        $CheckPSCopy =  $false
        return $CheckPSCopy
        }
    }
}

Function Invoke-StartSleep($seconds) {
    $doneDT = (Get-Date).AddSeconds($seconds)
    while ($doneDT -gt (Get-Date)) {
        $secondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $percent = ($seconds - $secondsLeft) / $seconds * 100
        Write-Progress -Activity "Sleeping" -Status "Sleeping..." -SecondsRemaining $secondsLeft -PercentComplete $percent
        [System.Threading.Thread]::Sleep(500)
    }
    Write-Progress -Activity "Sleeping" -Status "Sleeping..." -SecondsRemaining 0 -Completed
}

function Invoke-CheckVMConnectivity{
	param(
        [string]$vmName,
        [string]$stagevCenter,
        [string]$vmFqdn,
        [string]$vmIP
	) 
    #called by other functions before their action - eg Pre-req,Staging,Phase1 Install, Phase 2 DB cmds, Phase App cmds
    # Check if PSRemoting is enabled and functional
    if((Test-NetConnection -ComputerName $Computer -Port 5986).TcpTestSucceeded -eq $true)
				{
                        $result.stdout += "WinRM enabled successfully.`n"}
                        
    if (Test-WsMan -ComputerName $vmFqdn -Credential $Credential) {
        Write-Host "Connected to $vmFqdn over the network!" `n -ForegroundColor Green
		$connection = "WinRMFQDN"}
    elseif (Test-WsMan -ComputerName $vmIP -Credential $Credential){ 
        Write-Host "Connected to $vmName ($vmIP) via IP over the network!" `n -ForegroundColor Green
        $connection = "WinRMIP"} 
    elseif (Test-Connection -TargetName $vmFqdn -Count 1 -Quiet) {
        Write-Host "$vmFqdn responding via IP on the network!" `n -ForegroundColor Yellow
        $connection = "FQDN"}
    elseif (Test-Connection -TargetName $vmIP -Count 1 -Quiet) {
        Write-Host "$vmName ($vmIP) responding via IP on the network!" `n -ForegroundColor Yellow
        $connection = "IP"}
    else {
        # Confirm the VM exists in vCenter
        Invoke-ConnecttovCenter -stagevCenter $stagevCenter
        $VM = Get-VM $vmName -ErrorAction 'silentlycontinue'
        If (! $VM){
            Write-Host "Unable to find $vmName in vCenter! Skipping VM." `n -ForegroundColor Red
            $connection = "NOVM"
        } else {
            if (Invoke-CheckVMTools -vmName $vmName -stagevCenter $stagevCenter){
                Write-Host "$vmName VMTools active but VM not on the Network. Pausing 5 minutes so you can fix this!" `n -ForegroundColor Red
                Pause

                $checkVMTools = Invoke-CheckVMTools -vmName $vmName -stagevCenter $stagevCenter
                while($checkVMTools -eq $false) {
                    Start-Sleep -Seconds 300
                    $checkVMTools = Invoke-CheckVMTools -vmName $vmName -stagevCenter $stagevCenter
                }
                $connection = "VMTOOLS"
            } else {
                Write-Host "VMTools are not running on $vmName. Pausing 5 minutes so you can fix this!" -ForegroundColor Red
                Pause

                $checkVMTools = Invoke-CheckVMTools -vmName $vmName -stagevCenter $stagevCenter
                while($checkVMTools -eq $false) {
                    Start-Sleep -Seconds 300
                    $checkVMTools = Invoke-CheckVMTools -vmName $vmName -stagevCenter $stagevCenter
                }
                $connection = "VMTOOLS"
            }
        }
    }
    #Try to enable Powershell Remoting to make copying and running commands more efficient
    if($connection -eq "FQDN" -Or $connection -eq "IP") {

        if (Invoke-enablePSRemoting -vmName $vmName -stagevCenter $stagevCenter){
            #test if PSRemoting is now enabled
            if (Test-WsMan -ComputerName $vmFqdn -Credential $Credential) {
                Write-Host "Connected to $vmFqdn over the network!" `n -ForegroundColor Green
                $connection = "WinRMFQDN"}
            elseif (Test-WsMan -ComputerName $vmIP -Credential $Credential){ 
                Write-Host "Connected to $vmName ($vmIP) via IP over the network!" `n -ForegroundColor Green
                $connection = "WinRMIP"}
            else {
                Write-Host "Enabling PSRemoting for $vmName failed. Using VMTools to access VM." `n -ForegroundColor Red
                $connection = "VMTOOLS"}
        } else {
            Write-Host "Enabling PSRemoting for $vmName failed. Using VMTools to access VM." `n -ForegroundColor Red
            $connection = "VMTOOLS"
        }
    }
    return $connection
}

function Invoke-ConnecttovCenter {
    param (
        [string]$stagevCenter
    )
    If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
        $vcCreds = Get-Credential
        New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
        Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
        }
    Else{
        Connect-VIServer $stagevCenter -SaveCredentials
    }
}

function Invoke-CheckVMNetwork{
	param(
		[string]$vmFqdn
	) 
    
    # Check if network is accessible
    if(Test-Connection -ComputerName $vmFqdn -Count 1 -Quiet){
        #Write-Host "Connected to $vmFqdn over the network!" `n -ForegroundColor Yellow
		return $true
	} else {
        Write-Host "Unable to reach $vmFqdn over the network!" `n -ForegroundColor Red
		return $false
    }
}

Function Invoke-CheckVMTools {
    param(
        [string]$vmName,
        [string]$stagevCenter
    )
    #DO WE NEED TO CONNECT TO VI HERE????
    Invoke-ConnecttovCenter -stagevCenter $stagevCenter
    $VM = Get-VM $vmName

    # Check if VM Tools is running
    if ($VM.ExtensionData.Guest.ToolsRunningStatus -ne "GUESTTOOLSRUNNING") {
        
        return $false
    }
    else {
        return $true
    }

}

Function Invoke-enablePSRemoting {
    param(
        [String] $vmName,
        [String] $stagevCenter
    )
    
    If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
        $vcCreds = Get-Credential
        New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
        Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
        }
    Else{
        Connect-VIServer $stagevCenter -SaveCredentials
    }
    
    #Check if VMtools installed and we can talk to the VM
    If ( ! (Invoke-CheckVmTools $vmName)) {
        Write-Host "$vmName VMTools is not responding on $vmName!! Can't do any automation on this VM." -ForegroundColor Red
        $CheckPSRemoting =  $false
        return $CheckPSRemoting
    }
    Else {
        #Enable Powershell Remoting
        Write-Host "Enabling Powershell remoting on $vmName" -ForegroundColor Yellow

        #Check if $destinationDir exists
        $destinationFolderExists = (Invoke-VMScript -ScriptText {Test-Path -Path $destinationDir} -VM $vmName  -GuestCredential $Credential -ScriptType Powershell)
            
        If ( ! $destinationFolderExists) {
            #Create destination folder
            Write-Host "Creating $destinationDir folder path to $vmName" -ForegroundColor Yellow
            
            $newdestinationDirCMD = "New-Item -Path $destinationDir -ItemType Directory"
            Invoke-VMScript -ScriptText $newdestinationDirCMD -VM $vmName -GuestCredential $Credential
            $desttoolsDirCMD = "New-Item -Path $desttoolsDir -ItemType Directory"
            Invoke-VMScript -ScriptText $desttoolsDirCMD -VM $vmName -GuestCredential $Credential
        }

        $enablepsremotingscript = @'

        Set-ExecutionPolicy undefined
        Enable-PSRemoting -Force
'@
        #Create PS script in current directory
        $enablepsremotingscriptfile = $current_path + "\" + "enablepsremoting.ps1"
        Out-File -FilePath $enablepsremotingscriptfile -InputObject $enablepsremotingscript -Force -Confirm
        
        #Copy PS script to VM
        Copy-VMGuestFile -LocalToGuest -source $enablepsremotingscriptfile -destination $destinationDir -Force:$true -vm $vmName -GuestCredential $Credential
        
        $destenablepsremotingscriptfile = $destinationDir + "\" + "enablepsremoting.ps1"

        #Execute PS script to enable PS Remoting
        $executeenablepsremotingscript = "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -NoLogo -NonInteractive -NoProfile -File #destenablepsremotingscriptfile#' -Verb RunAs"
        $executeenablepsremotingscriptBlock = $executeenablepsremotingscript.Replace('#destenablepsremotingscriptfile#',$destenablepsremotingscriptfile)
        #Write-Host $executeenablepsremotingscriptBlock
        Invoke-VMScript -ScriptText $executeenablepsremotingscriptBlock -VM $vmName -GuestCredential $Credential -ScriptType Powershell
        
        #Write-Host $enablePSRemoting
        #$CheckPSRemoting =  $true
        #return $CheckPSRemoting
    }
}

Function Invoke-CheckURLs {
    param(
        [Array] $URLArray
        )

    # Build an Array of VM Name strings
    #$completedVMs = @()

    for ($i = 0; $i -lt $URLArray.count; $i++) {
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($URLArray[$i].URL)) { Continue }
        $URL = $URLArray[$i].URL
    
        If ($URL) {
            #This will allow self-signed certificates to work
            $CheckWebStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            #Define the total time to wait for a response
            $CheckWebTimeOut = New-TimeSpan -Minutes 5
            Write-Host "Waiting until $URL is available" -ForegroundColor Yellow
            $Response = Invoke-WebRequest $URL -ErrorAction SilentlyContinue
            While (($Response.StatusCode -ne "200") -and ($CheckWebStopWatch.Elapsed -le $CheckWebTimeOut)) {
                Try {
                    $Response = Invoke-WebRequest $URL -ErrorAction SilentlyContinue
                }
                Catch {
                    Invoke-StartSleep 10
                }
            }
            If ($Response.StatusCode -eq "200") {
                Write-Host "$URL is now responding" -ForegroundColor Green
                return $true
            }
            Else {
                Write-Host "Timed out while waiting for $URL to respond" -ForegroundColor Red
                return $false
            }
        }
    }
}

Function Invoke-CreateVMs {
    param(
        [array] $vmArray,
        [String] $stagevCenter
        #[SecureString] $vcCreds
        )

    # Connect to vCenter and create VMs
    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name

        If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
            $vcCreds = Get-Credential
            New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
            Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
            #Export-Clixml   
            }
        Else{
            Connect-VIServer $stagevCenter -SaveCredentials
        }
        
        # Get the OS CustomizationSpec and clone

$OSCusSpec = Get-OSCustomizationSpec -Name 'RHEL VM' | New-OSCustomizationSpec -Name 'temp1' -Type NonPersistent

#Update Spec with IP information

Get-OSCustomizationNicMapping -OSCustomizationSpec $OSCusSpec |

    Set-OSCustomizationNicMapping -IPMode UseStaticIP `

    -IPAddress '192.168.1.101' `

    -SubnetMask '255.255.254.0' `

    -DefaultGateway '192.168.1.2' `

    #-Dns '192.168.1.2'

 

 

#Get updated Spec Object
$OSCusSpec = Get-OSCustomizationSpec -Name 'temp1'

# Get source Template
$Template = Get-Template -Name 'RHEL 6.9'

#Get Cluster
$tgtClusterName = 'CLUSTER7'
$cluster = Get-Cluster -Name $tgtClusterName

# Get a host within cluster
$VMHost = Get-Cluster $cluster | Get-VMHost | Get-Random

# Get datastore
$dsName = 'ds*-store7*'

# Find a datastore with most space
$Datastore = Get-Datastore -Name $dsName | Sort-Object -Property FreeSpaceGB -Descending | Select -First 1

# Deploy Virtual Machine and remove temp custom spec
$VM = New-VM -Name 'testvm1p02' -Template $Template -VMHost $VMHost -Datastore $Datastore -OSCustomizationSpec $OSCusSpec | Start-VM
Remove-OSCustomizationSpec $OSCusSpec -Confirm
        # Check the VM is working
        If( ! ( Invoke-CheckVmTools -vmName $vmName ) ) {
            throw "Unable to find $vmName. The VM is either not in the inventory or VMTools is not responding"
        }

        # Take a snapshot of the VM before attempting to install anything
        Write-Host "Taking snapshot of $vmName VMs to provide a rollback" -ForegroundColor Yellow
        $Snapshot = Get-Snapshot $vmName | Select-Object Name

        If ( $Snapshot.Name -ne $snapshotName ) {
            New-Snapshot -VM $vmName -Name $snapshotName -Confirm:$false -WarningAction silentlycontinue | Out-Null
        } 
        Else {
            Write-Host "A Snapshot for $vmName already exists. There is no need to take a new snapshot!" -ForegroundColor Yellow
        }

        #Disconnect from vCenter Server
        Disconnect-VIServer * -Force -Confirm:$false

        # If the AirWatch VMs are set to $true, Clone the VMs
If($deployAirWatch){
    Write-Host "Deploying AirWatch CN VMs" `n -ForegroundColor Yellow
    # Use Start-Job to deploy VM groups in parallel
    createVmFolders -vmFolders $vmFolders.airwatch -datacenterName $mgmtDatacenterName
    cloneVMs -vmArray $airwatchCnServers -vmFolder $vmFolders.airwatch -network $mgmtNetwork -clusterName $mgmtClusterName -datastoreName $mgmtDatastoreName -ramGB $airwatchCnRamGb -numCPU $airwatchCnNumCpu
    newAffinityRule -ruleName $airwatchCnAffinityRuleName -cluster $mgmtClusterName -vmArray $airwatchCnServers
    addLocalAdmin -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword -serviceAccount $airwatchServiceAccountName -domainName $domainName -vmArray $airwatchCnServers
    If($requestAirWatchSslCert){
        Write-Host "Requesting CA signed SSL Certificates for the AirWatch CS VMs" `n -ForegroundColor Yellow
        requestCaCerts -commonName $airwatchCnCommonName -friendlyName $airwatchCnFriendlyName -templatename $airwatchTemplateName -vmArray $airwatchCnServers -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword
    }
}

Disconnect-VIServer * -Force -Confirm:$false

# Connect to DMZ vCenter Servers
if($global:defaultVIServers.Name -notcontains $dmzvCenterName){
    Connect-VIServer -Server $dmzvCenterName -User $dmzvCenterAccount -Password $dmzvCenterPassword -Force | Out-Null
}
if($global:defaultVIServers.Name -contains $dmzvCenterName){
    Write-Host "Successfully connected to $dmzvCenterName" -ForegroundColor Green `n
} Else {
    Write-Error "Unable to connect to Management vCenter Server"
}

# If the AirWatch VMs are set to $true, Clone the VMs
If($deployAirWatch){
    Write-Host "Deploying AirWatch DS VMs" `n -ForegroundColor Yellow
    # Use Start-Job to deploy VM groups in parallel
    createVmFolders -vmFolders $vmFolders.airwatch -datacenterName $dmzDatacenterName
    cloneVMs -vmArray $airwatchDsServers -vmFolder $vmFolders.airwatch -network $dmzInternetNetwork -clusterName $dmzClusterName -datastoreName $dmzDatastoreName -ramGB $airwatchDsRamGb -numCPU $airwatchDsNumCpu
    newAffinityRule -ruleName $airwatchDsAffinityRuleName -cluster $dmzClusterName -vmArray $airwatchDsServers
    # If a local admin account is not configured (because the DMZ VM isn't on a domain) this will still run anyway. 

    addLocalAdmin -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword -serviceAccount $airwatchServiceAccountName -domainName $domainName -vmArray $airwatchDsServers
}

    }
}

function cloneVMs {
    param(
        [Array]$vmArray,
        [String]$vmFolder,
        [Array]$network,
        [String]$clusterName,
        [String]$datastoreName,
        [Int]$ramGB,
        [Int]$numCPU
    )

    $newVmArray = @()

    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        
        # Guest Customization
        $vmName = $vmArray[$i].Name
        $ipAddress = If($vmArray[$i].IP){$vmArray[$i].IP} Else {Write-Error "$vmName IP not set"}
        $osCustomizationSpecName = "$vmName-CustomizationSpec"
        $subnetmask = $network.netmask
        $gateway = $network.gateway
        $networkPortGroup = Get-VDPortgroup -Name $network.name

        Write-Host "Now provisioning $vmName" -BackgroundColor Blue -ForegroundColor Black `n
        
        # Check if VM already exists in vCenter. If it does, skip to the next VM
        If(Get-VM -Name $vmName -ErrorAction Ignore){
            Write-Host "$vmName already exists. Moving on to next VM" -ForegroundColor Yellow `n
            $newVM = $false
            Continue
        } Else {
            $newVM = $true
        }
    
        # If a Guest Customization with the same name already exists then we will remove it. This will make sure that we get the correct settings applied to the VM
        If(Get-OSCustomizationSpec -Name $osCustomizationSpecName -ErrorAction Ignore){
            Remove-OSCustomizationSpec -OSCustomizationSpec $osCustomizationSpecName -Confirm:$false
        }
        
        # Create a new Guest Customization for each VM so that we can configure each OS with the correct details like a static IP    
        New-OSCustomizationSpec -Name $osCustomizationSpecName -Type NonPersistent -OrgName $orgName -OSType Windows -ChangeSid -DnsServer $dnsServer -DnsSuffix $domainName -AdminPassword $localDomainAdminPassword -TimeZone $timeZone -Domain $domainName -DomainUsername $domainJoinUser -DomainPassword $domainJoinPassword -ProductKey $windowsLicenseKey -NamingScheme fixed -NamingPrefix $vmName -LicenseMode Perserver -LicenseMaxConnections 5 -FullName $fullAdministratorName | Out-Null
        Get-OSCustomizationSpec -Name $osCustomizationSpecName | Get-OSCustomizationNicMapping | Set-OSCustomizationNicMapping -IpMode UseStaticIP -IpAddress $ipAddress -SubnetMask $subnetMask -DefaultGateway $gateway -Dns $dnsServer | Out-Null
        
        If(Get-OSCustomizationSpec -Name $osCustomizationSpecName -ErrorAction Ignore){
            Write-Host "$osCustomizationSpecName profile has been created for $vmName" -ForegroundColor Green `n
        } Else {
            Write-Host "$osCustomizationSpecName failed to create for $vmName" -ForegroundColor Red `n
        }
    
        # For testing purposes Linked Clones can be used. For Production full clones must be used. 
        If($deployLinkedClones){
            Write-Host "Deploying $vmName as a Linked Clone VM"
            New-VM -LinkedClone -ReferenceSnapshot $referenceSnapshot -Name $vmName -ResourcePool $clusterName -Location $vmFolder -Datastore $datastoreName -OSCustomizationSpec $osCustomizationSpecName -DiskStorageFormat $diskFormat -VM $referenceVmName -ErrorAction Stop | Out-Null
            If(Get-VM -Name $vmName -ErrorAction Ignore){
                Write-Host "$vmName has been provisioned as a Linked Clone VM" -ForegroundColor Green `n
            }
        } Else {
            Write-Host "Deploying $vmName as a full clone VM" -ForegroundColor Green `n
            New-VM -Name $vmName -Datastore $datastoreName -DiskStorageFormat $diskFormat -OSCustomizationSpec $osCustomizationSpecName -Location $vmFolder -VM $referenceVmName -ResourcePool $clusterName | Out-Null
            If(Get-VM -Name $vmName -ErrorAction Ignore){
                Write-Host "$vmName has been provisioned as a Full Clone VM" -ForegroundColor Green `n
            }
        }
    
        # Adding each VM to an array of VM Objects that can be used for bulk modifications.
        If($newVM){    
            If(Get-VM -Name $vmName){
                $newVmArray += (Get-VM -Name $vmName)
            } Else {
                Write-Error "$vmName failed to be created, it may already exist."
                Continue
            }
        }

        # After the VM is cloned, wait 1 sec (without displaying a sleep timer) before making changes to the VM.
        [System.Threading.Thread]::Sleep(1000)

        #Make sure the new server is provisioned to the correct network/portgroup and set to "Connected"
        Write-Host "Changing network of VM to $($networkPortGroup.Name)"
        $networkAdapter = Get-VM $vmName | Get-NetworkAdapter -Name "Network adapter 1"
        Set-NetworkAdapter -NetworkAdapter $networkAdapter -Portgroup $networkPortGroup -Confirm:$false
        Set-NetworkAdapter -NetworkAdapter $networkAdapter -StartConnected:$true -Confirm:$false

        # Reconfigure the VM with the correct CPU and RAM
        Get-VM -Name $vmName | Set-VM -MemoryGB $ramGB -NumCpu $numCPU -confirm:$false

        # Power on the VMs after they are cloned so that the Guest Customizations can be applied
        Start-VM -VM $vmName -Confirm:$false | Out-Null
        Write-Host "Powering on $vmName VM" -ForegroundColor Yellow `n

        # After the VM has started, confirm the network adapter is connected
        Set-NetworkAdapter -NetworkAdapter $networkAdapter -Connected:$true -Confirm:$false
    }

    # Wait for a while to ensre the OS Guest Customization is compute and VMTools has started
    If($newVmArray){
        Write-Host "`nPausing the script while we wait until the VMs are ready to execute in-guest operations." -ForegroundColor Yellow
        Write-Host "This will take up to 5 minutes for Guest Opimization to complete and VMTools is ready.  " `n -ForegroundColor Yellow
        Start-Sleep -Seconds (60*5)
    } Else {
        Write-Host "No new VMs were created..." `n -ForegroundColor Yellow
    }

    # Check the newly provisioned VMs exist and wait for VMTools to respond
    for($i = 0; $i -lt 5; $i++){
        foreach($VM in $newVmArray){
            If(checkVM -vmName $VM){
                # If the VM is responding them remove it from the array so it doesn't get checked again.
                $newVmArray = $newVmArray | Where-Object {$_ -ne $VM}
            }
        }
        If(! $newVmArray){Break}
        Write-Host "$($newVmArray -join ", ") are not responding. Wait 1 minute and try again...." `n -ForegroundColor Yellow
        Start-Sleep 60
    }
}
function newAffinityRule{
    param(
        [String]$ruleName,
        [String]$cluster,
        [array]$vmArray
    )

    $vmObjectArray = @()
    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmObjectArray += (Get-VM -Name $vmArray[$i].Name)
    }

    if(!(Get-DrsRule -Cluster $cluster -Name $ruleName -ErrorAction Ignore)){
        If($vmArray){ 
            New-DrsRule -Name $ruleName -Cluster $cluster -VM $vmObjectArray -KeepTogether $false -Enabled $true | Out-Null
        }
        if(Get-DrsRule -Cluster $cluster -Name $ruleName -ErrorAction Ignore){
            Write-Host "Created a DRS anti-affinity rule for the Connection Servers: $ruleName" -ForegroundColor Green `n
        } Else {
            Write-Error "Failed to create DRS anti-affinity rule!" `n
        }
    } Else {
        Write-Error "Affinity rule name already exists!"
    }
}
function addLocalAdmin{
    param(
        [String]$guestOsAccount,
        [String]$guestOsPassword,
        [String]$serviceAccount,
        [String]$domainName,
        [array]$vmArray
    )

    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
       
        $vmName = $vmArray[$i].Name

$addAdminScriptText = @"
`$localAdminGroup = [ADSI]"WinNT://$vmName/Administrators,group"
`$userName = [ADSI]"WinNT://$domainName/$serviceAccount,user"
`$localAdminGroup.Add(`$userName.Path)
"@
        Write-Host "Adding $serviceAccount to the local Administrator group on $vmName" `n -ForegroundColor Yellow
        $Output = Invoke-VMScript -ScriptText $addAdminScriptText -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
        $Output | Select-Object -ExpandProperty ScriptOutput
    }
}

Function Invoke-ShutdownVMs {
    param(
        [array] $vmArray,
        [String] $stagevCenter
        )

    # Take Snapshots of each of the servers for rollback.
    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name

        If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
            $vcCreds = Get-Credential
            New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
            Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
            }
        Else{
            Connect-VIServer $stagevCenter -SaveCredentials
        }

        # Shutdown VM
        Get-VM $vmName | Shutdown-VMGuest
    }
    
    #Disconnect from vCenter Server
    Disconnect-VIServer * -Force -Confirm:$false
}

Function Invoke-CreatePsSession ($ServerFqdn) {
    #Write-Host "Attempting to create remote PowerShell session on $ServerFqdn."
    $ReturnValue = New-PSSession -computername $ServerFqdn -credential $Credential -ErrorAction SilentlyContinue
    return $ReturnValue
}

Function Invoke-vIDMUpg {
    #script to take all vIDM nodes out of load balancer pools
    #script to add the first vIDM node into the load balancer pool
    #script to ssh to vidm node, su to root and run the following commands
    # /usr/local/horizon/update/updatemgr.hzn updateinstaller
    # /usr/local/horizon/update/updatemgr.hzn check
    # /usr/local/horizon/update/updatemgr.hzn update
    # reboot when done
    #script to add next vIDM node back into load balancer pool and run commands
}

Function Invoke-RemoteConsole {
    param(
        [Array] $vmArray,
        [String] $stagevCenter
        #[String] $vcCreds
    )
    #$completedVMs = @()
    
    For ($i = 0; $i -lt $vmArray.count; $i++) {
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)) { Continue }
        
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        Write-Host "----------------------------------------------------------------------------"

        # First check if the VM is on the network
        If ( ! (Invoke-CheckVMNetwork $vmFqdn)) {
        
            Write-Host "Can't connect to the $vmFqdn over the network. Opening web console" -ForegroundColor Yellow
            #write-host "Will try using VMTools" -ForegroundColor Yellow
            #Write-Host `n
            
            If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
                $vcCreds = Get-Credential
                New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
                Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
                }
            Else{
                Connect-VIServer $stagevCenter -SaveCredentials
            }
        
            Open-VMConsoleWindow -VM $vmName -Server $stagevCenter
            
            #Disconnect-VIServer * -Force -Confirm:$false
            }
        Else {
            #Try to use Powershell to open RDP session
            $user = $Credential.UserName
            $pass = $Credential.GetNetworkCredential().Password
            $CMDKEY = "$($env:SystemRoot)\system32\cmdkey.exe /generic:$vmFqdn /user:$user /pass:$pass"
            $RDPCMD = "$($env:SystemRoot)\system32\mstsc.exe /v:$vmFqdn"
            Invoke-Command -ScriptBlock $CMDKEY
            Invoke-Command -ScriptBlock $RDPCMD
        }
    }

}

function Invoke-StartServices {
    param(
        [Array] $vmArray,
        [String] $stagevCenter
        #[Securestring] $vcCreds
        )

    # Build an Array of VM Name strings
    #$completedVMs = @()

    for ($i = 0; $i -lt $vmArray.count; $i++) {
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)) { Continue }
        $serverName = $vmArray[$i].Name
        $serverfqdn = $vmArray[$i].fqdn
    
        Try {
            #Connect to Windows Server
            $session = Invoke-CreatePsSession $serverfqdn
            If ($session -is [System.Management.Automation.Runspaces.PSSession]) {
                #Stop WS1 Services
                Write-Host "Starting Workspace ONE services on $serverfqdn via Powershell" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock { Get-Service bits,*airwatch* | Start-Service -PassThru | Set-Service -StartupType Automatic }
                #Disconnect from Windows Server
                Remove-PSSession $Session }
            Else
                { Write-Host "Remote test failed: $serverfqdn  via Powershell." }
        }
        Catch {
            If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
                $vcCreds = Get-Credential
                New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
                Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
                }
            Else{
                Connect-VIServer $stagevCenter -SaveCredentials
            }
            #Connect to VIServer
            #Connect-VIServer $stagevCenter $vcCreds

            #Stop WS1 Services
            Write-Host "Starting Workspace ONE services on $serverName" -ForegroundColor Yellow
            Invoke-VMScript -ScriptText "Get-Service bits,*airwatch* | Start-Service -PassThru | Set-Service -StartupType Automatic" -GuestCredential $vcsession
            #Disconnect from vCenter Server
            Disconnect-VIServer * -Force -Confirm:$false
        }
    }

    #$completedVMs += (Get-VM -Name $vmName)
}

Function Invoke-StopServices {
    param(
        [Array] $vmArray,
        [String] $stagevCenter
        #[SecureString] $vcCreds
        )

    # Build an Array of VM Name strings
    #$completedVMs = @()

    for ($i = 0; $i -lt $vmArray.count; $i++) {
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)) { Continue }
        $serverName = $vmArray[$i].Name
        $serverfqdn = $vmArray[$i].fqdn
    
        Try {
            #Connect to Windows Server
            $session = Invoke-CreatePsSession $serverfqdn
            If ($session -is [System.Management.Automation.Runspaces.PSSession]) {
                #Stop WS1 Services
                Write-Host "Stopping Workspace ONE services on $serverfqdn via Powershell" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock { Get-Service GooglePlayS*,w3sv*,bits,*airwatch* | Stop-Service -PassThru | Set-Service -StartupType Manual }
                #Disconnect from Windows Server
                Remove-PSSession $Session }
            Else
                { Write-Host "Remote test failed: $serverfqdn  via Powershell." }
        }
        Catch {
            If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
                $vcCreds = Get-Credential
                New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
                Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
                #Export-Clixml   
                }
            Else{
                Connect-VIServer $stagevCenter -SaveCredentials
            }

            #Stop WS1 Services
            Write-Host "Stopping Workspace ONE services on $serverName via VMTools" -ForegroundColor Yellow
            Invoke-VMScript -ScriptText "Get-Service GooglePlayS*,w3sv*,bits,*airwatch* | Stop-Service -PassThru | Set-Service -StartupType Manual" -GuestCredential $vcsession
            #Disconnect from vCenter Server
            Disconnect-VIServer * -Force -Confirm:$false
        }
    }

    #$completedVMs += (Get-VM -Name $vmName)
}
#need work on checkAirwatchService. look for specific service instead of wsbroker
function Invoke-checkAirWatchService{
	param(
		[string]$vmName,
		[String]$guestOsAccount,
        [String]$guestOsPassword
	)
	# Check the VM is working
    If(!(checkVM -vmName $vmName)){throw "Unable to find $vmName. The VM is either not in the inventory or VMTools is not responding"}
	
	# Validate the connection server is installed and running by checking the service is running on the destination VM using Get-Service
	Write-Host "Waiting for the service to start on $vmName" -ForegroundColor Yellow
	$checkStatusStatusTimeOut = (Get-Date).AddMinutes(1)
	
	While(($serviceStatus -ne "Running") -and ($checkStatusStatusTimeOut -gt (Get-Date))){
		$serviceStatusOutput = Invoke-VMScript -ScriptText '(Get-Service | Where{$_.Name -eq "wsbroker"}).Status' -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -scripttype Powershell -ErrorAction SilentlyContinue
		$serviceStatus = [string]$serviceStatusOutput.Trim()
		[System.Threading.Thread]::Sleep(1000*10)
		$Status = $False
	}
	If ($serviceStatus -eq "Running"){
		$Status = $True
	}
	return $Status
}

Function Invoke-SnapshotVMs {
    param(
        [array] $vmArray,
        [String] $stagevCenter
        #[SecureString] $vcCreds
        )
    
    $snapshotName = "$logdate Upgrading WS1"

    # Take Snapshots of each of the servers for rollback.
    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name

        If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
            $vcCreds = Get-Credential
            New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
            Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
            #Export-Clixml   
            }
        Else{
            Connect-VIServer $stagevCenter -SaveCredentials
        }
        #Connect to VIServer
        #Connect-VIServer $stagevCenter #vcCreds

        # Check the VM is working
        If( ! ( Invoke-CheckVmTools -vmName $vmName ) ) {
            throw "Unable to find $vmName. The VM is either not in the inventory or VMTools is not responding"
        }

        # Take a snapshot of the VM before attempting to install anything
        Write-Host "Taking snapshot of $vmName VMs to provide a rollback" -ForegroundColor Yellow
        $Snapshot = Get-Snapshot $vmName | Select-Object Name

        If ( $Snapshot.Name -ne $snapshotName ) {
            New-Snapshot -VM $vmName -Name $snapshotName -Confirm:$false -WarningAction silentlycontinue | Out-Null
        } 
        Else {
            Write-Host "A Snapshot for $vmName already exists. There is no need to take a new snapshot!" -ForegroundColor Yellow
        }

        #Disconnect from vCenter Server
        Disconnect-VIServer * -Force -Confirm:$false
    }
}

#####################################################################################
######################           SCRIPT STARTS HERE            ######################
#####################################################################################

Write-Host "Process started $logdate"

Function Invoke-Menu {
    #Clear-Host
    Write-Host `n
    Write-Host "                                                              " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "          VMware Workspace ONE Blue / Green Upgrade Script    " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "                                                              " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host `n
    Write-Host "The following tasks can be exectued from this tool" -ForegroundColor Cyan
    Write-Host `n
    Write-Host "1: PHASE 1 - Create Application Server VMs" -ForegroundColor Cyan `n
    Write-Host "2: PHASE 1 - Install Pre-Reqs / Config Application Servers" -ForegroundColor Cyan `n
    Write-Host "3: PHASE 1 - Stage installer binaries to Application & DB servers" -ForegroundColor Cyan `n
    Write-Host "4: PHASE 1 - Run installer (staging mode) on Application Servers" -ForegroundColor Cyan `n
    Write-Host "5: PHASE 2 - Shutdown Application Server VMs" -ForegroundColor Cyan `n
    Write-Host "6: PHASE 2 - Run installer on DB Server *** CAREFUL ***" -ForegroundColor Cyan `n
    Write-Host "7: PHASE 2 - Run PHASE 2 components on Application Servers" -ForegroundColor Cyan `n
    Write-Host "8: PHASE 2 - Add Application Servers into NSX LB Pools" -ForegroundColor Cyan `n
    Write-Host "9: Test Site URLs" -ForegroundColor Cyan `n
    Write-Host "Type 'x' to exit" -ForegroundColor Yellow
    Write-Host `n
    $Selection = (Read-Host "Select the task you would like to execute").ToLower()
    return $Selection
}

#Invoke-Menu

$Quit = $false

While(! $Quit){
    $Selection = Invoke-Menu

    switch 
    ($Selection) {
    1 {
        Write-Host "PHASE 1 - Create Application Server VMs"
        Invoke-CreateVMs -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-CreateVMs -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-CreateVMs -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-CreateVMs -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    2 {
        Write-Host "PHASE 1 - Install Pre-Reqs / Config Primary Application Servers"
        Invoke-InstallPrereqs -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-InstallPrereqs -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPrereqs -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-InstallPrereqs -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    3 {
        Write-Host "PHASE 1 - Stage installer binaries to Application & DB servers"
        Invoke-StageFiles -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-StageFiles -vmArray $priDBServers $PrivCenter #$VCPriCred
        Invoke-StageFiles -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-StageFiles -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-StageFiles -vmArray $secDBServers $SecvCenter #$VCSecCred
            Invoke-StageFiles -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    4 {
        Write-Host "PHASE 1 - Run PHASE 1 components on Application Servers"
        Invoke-InstallPhase1
        Invoke-InstallPhase1 -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-InstallPhase1 -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPhase1 -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-InstallPhase1 -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    5 {
        Write-Host "PHASE 2 - Shutdown Application Server VMs"
        #ARE YOU SURE
        Invoke-ShutdownVMs -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-ShutdownVMs -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-ShutdownVMs -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-ShutdownVMs -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    6 {
        Write-Host "PHASE 2 - Run installer on DB Server *** CAREFUL ***"
        #ARE YOU SURE
        Invoke-InstallPhase2 -vmArray $priDBServers $PrivCenter #$VCPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPhase2 -vmArray $secDBServers $SecvCenter #$VCPriCred
        }
    }
    7 {
        Write-Host "PHASE 2 - Run PHASE 2 components on Application Servers"
        #ARE YOU SURE
        Invoke-InstallPhase2 -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-InstallPhase2 -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPhase2 -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-InstallPhase2 -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    8 {
        Write-Host "PHASE 2 - Add Application Servers into NSX LB Pools"
    }
    9 {
        Write-Host "Check the install was successfull by use the Web API to see if it responds"
        Invoke-CheckURLs -URL $URLs
    }
    x {
        $Quit = $true
        Write-Host "Existing Script" -ForegroundColor Green `n
        Stop-Transcript  #Before closing off the script
    }
    Default {}
    }
}



$Host.UI.RawUI.BackgroundColor = $OriginalBackground

