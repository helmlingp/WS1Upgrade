<#	
  .Synopsis
    This powershell script automates stages of a WS1 UEM upgrade using a menu selection for each phase.
    It requires a JSON file with configuration of the environment.
    Requirements include:
     * VMware PowerCLI Module (will be imported automatically)
     * env.json file
     * Subfolders
        \Installer
            \Application - contains the extracted Application Server installer files
            \Cert - contains the certificate used for application servers
            \Configs - contains WS1 UEM installer config.xml files with role based names (CN_ConfigScript.xml, API_ConfigScript.xml, AWCM_ConfigScript.xml, DS_ConfigScript.xml)
            \DB - contains the extracted DB Server installer files
            \Prereqs - contains Java runtime (jre*.exe) and dotNET Framework runtime (ndp*.exe) versions that are specified by WS1 UEM version you are upgrading to
        \Tools - containing 7z1900-x64.exe
  .NOTES
	  Created:   	    May, 2019
	  Created by:	    Phil Helmling, @philhelmling
	  Organization:   VMware, Inc.
	  Filename:       upgradeWS1UEM-0.0.4.ps1
	.DESCRIPTION
	  This powershell script automates stages of a WS1 UEM upgrade using a menu selection for each phase.
  .EXAMPLE
    powershell.exe -ep bypass -file .\upgradeWS1UEM-0.0.4.ps1 WS1Config.json
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
$WS1ConfigJson = [String]$args
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
$certDir = $WS1Config.globalConfig.deploymentDirectories.certDir
$configDir = $WS1Config.globalConfig.deploymentDirectories.configDir
$PrereqsDir = $WS1Config.globalConfig.deploymentDirectories.PrereqsDir
$DBInstallerDir = $WS1Config.globalConfig.deploymentDirectories.DBInstallerDir
$AppInstallerDir = $WS1Config.globalConfig.deploymentDirectories.AppInstallerDir
#Remote Dirs
$destinationDir = $WS1Config.globalConfig.deploymentDirectories.destinationDir
# CA SSL Certificate config
$pfxFileName = $WS1Config.globalConfig.sslCertificates.airwatch.pfxFileName
$pfxPassword = $WS1Config.globalConfig.sslCertificates.airwatch.pfxPassword
$pfxCommonName = $WS1Config.globalConfig.sslCertificates.airwatch.pfxCommonName

# Import arrays of VMs to deploy
$priAppServers = $WS1Config.PrimaryWorkloadServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$secAppServers = $WS1Config.SecondaryWorkloadServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$priDMZAppServers = $WS1Config.PrimaryDMZServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$secDMZAppServers = $WS1Config.SecondaryDMZServers.servers | Where-Object {($_.Role -ne "DB") -and ($_.Role -ne "vIDM")}
$PriDBServers = $WS1Config.PrimaryWorkloadServers.servers | Where-Object {$_.Role -like "DB"}
$secDBServers = $WS1Config.SecondaryWorkloadServers.servers | Where-Object {$_.Role -like "DB"}
$URLs = $WS1Config.PrimaryWorkloadServers.URLs

#ask for Credentials to connect to Windows VMs using PS-Execute
$Credential = $host.ui.PromptForCredential("Windows credentials", "Please enter your Windows user name and password for Windows VMs.", "", "")

Function Invoke-StageFiles {
    param(
        [Array] $vmArray,
        [String] $stagevCenter
    )
    Write-Host "--------------------------STAGING--------------------------" `n -ForegroundColor Yellow

    For ($i = 0; $i -lt $vmArray.count; $i++) {
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)) { Continue }
        
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        $vmIP = $vmArray[$i].IP
        $vmRole = $vmArray[$i].Role
        
        # First try to copy WS1 files with PowerShell because it is much faster. If this fails, use VMTools.
        $connectby = Invoke-CheckVMConnectivity -vmName $vmName -vmFqdn $vmFqdn -vmIP $vmIP -stagevCenter $stagevCenter
        if($connectby -eq "WinRMFQDN") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmFqdn
        } elseif ($connectby -eq "WinRMIP") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmIP
        } elseif ($connectby -eq "VMTOOLS") {
            Invoke-ConnecttovCenter -stagevCenter $stagevCenter
        }

        if($connectby -eq "WinRMFQDN" -Or $connectby -eq "WinRMIP") {
            Invoke-PSCopy -vmName $vmName -Session $Session}
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

function UpgradeAirWatchDb {
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
    Get-Item -Path $destinationDir\AirWatch_Database_Publish.log | Select-String -Pattern "Update complete"
"@
                <#
    
    If($installDb){
        # Install the AirWatch DB from the first CN Server
        InstallAirWatchDb -vmName $dbInstallVM -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword    
    }

    } #>
    # Test DB network connectivity and stop execution if it can't be contacted over the network.
    $dbCheck = Invoke-VMScript -ScriptText $dbAvailable -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword -ScriptType PowerShell
    If(! $dbCheck){
        throw "The AirWatch DB is not accessible over the network from $vmName"
    }

    Write-Host "`nInstalling AirWatch DB. This may take a while." `n -ForegroundColor Yellow
	
	# Run the command to install the AirWatch DB  
    $installDbScriptBlock = [scriptblock]::Create("CMD /C $airwatchDbInstallDestinationPath /s /V`"/qn /lie $destinationDir\AirWatch_Database_InstallLog.log AWPUBLISHLOGPATH=$destinationDir\AirWatch_Database_Publish.log TARGETDIR=$INSTALLDIR INSTALLDIR=$INSTALLDIR  IS_SQLSERVER_AUTHENTICATION=$IS_SQLSERVER_AUTHENTICATION IS_SQLSERVER_SERVER=$IS_SQLSERVER_SERVER IS_SQLSERVER_USERNAME=$IS_SQLSERVER_USERNAME IS_SQLSERVER_PASSWORD=$IS_SQLSERVER_PASSWORD IS_SQLSERVER_DATABASE=$IS_SQLSERVER_DATABASE`"")

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
        [array] $vmArray,
        [String] $stagevCenter
    )
    Write-Host "--------------------------PREREQS--------------------------" `n -ForegroundColor Yellow

    $destcertDir = $destinationDir + "\" + $InstallerDir + "\" + $certDir
    $destprereqsDir = $destinationDir + "\" + $InstallerDir + "\" + $PrereqsDir
    $pfxDestinationFilePath = $destprereqsDir + "\" + $InstallerDir + "\" + $pfxFileName
    # Trusted SSL certificate install script
$importPfxScript = @"
CMD /C CertUtil -f -p "$pfxPassword" -importpfx "$pfxDestinationFilePath"
"@

    # WS1 Prereqs install script
$airwatchPreRequisitesScript = @"
# Add server roles
Install-WindowsFeature Web-Server, Web-WebServer, Web-Common-Http, Web-Default-Doc, Web-Dir-Browsing, Web-Http-Errors, Web-Static-Content, Web-Http-Redirect, Web-Health, Web-Http-Logging, Web-Custom-Logging, Web-Log-Libraries, Web-Request-Monitor, Web-Http-Tracing, Web-Performance, Web-Stat-Compression, Web-Dyn-Compression, Web-Security, Web-Filtering, Web-IP-Security, Web-App-Dev, Web-Net-Ext, Web-Net-Ext45, Web-AppInit, Web-ASP, Web-Asp-Net, Web-Asp-Net45, Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Includes, Web-Mgmt-Tools, Web-Mgmt-Console, Web-Mgmt-Compat, Web-Metabase -Source $windowsDestinationSxsFolderPath

# Add server features
Install-WindowsFeature NET-Framework-Features, NET-Framework-Core, NET-Framework-45-Features, NET-Framework-45-Core, NET-Framework-45-ASPNET, NET-WCF-Services45, NET-WCF-HTTP-Activation45, NET-WCF-MSMQ-Activation45, NET-WCF-Pipe-Activation45, NET-WCF-TCP-Activation45, NET-WCF-TCP-PortSharing45, MSMQ, MSMQ-Services, MSMQ-Server, Telnet-Client

# Get the certificate thumbprint
`$certThumbprint = (Get-ChildItem Cert:\LocalMachine\My | Where {`$_.Subject -like "*CN=$pfxCommonName*"} | Select-Object -First 1).Thumbprint

# IIS site mapping ip/hostheader/port to cert - also maps certificate if it exists for the particular ip/port/hostheader combo
New-WebBinding -name "Default Web Site" -Protocol https -HostHeader $pfxcommonName -Port 443 -SslFlags 1 #-IP "*"

# Bind certificate to IIS site
`$bind = Get-WebBinding -Name "Default Web Site" -Protocol https -HostHeader $pfxcommonName
`$bind.AddSslCertificate(`$certThumbprint, "My")
"@

    #Set Services Timeout Registry key
$servicesTimeoutRegistryCmd = @"
$registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control"
$dwordName = "ServicesPipeTimeout"
$dwordValue = "180000"
New-ItemProperty -Path $registryPath -Name $dwordName -Value $dwordValue -Type DWORD -Force | Out-Null
"@

    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        $vmIP = $vmArray[$i].IP
        $vmRole = $vmArray[$i].Role

        $connectby = Invoke-CheckVMConnectivity -vmName $vmName -vmFqdn $vmFqdn -vmIP $vmIP -stagevCenter $stagevCenter
        if($connectby -eq "WinRMFQDN") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmFqdn
        } elseif ($connectby -eq "WinRMIP") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmIP
        } elseif ($connectby -eq "VMTOOLS") {
            Invoke-ConnecttovCenter -stagevCenter $stagevCenter
        }

        if($connectby -eq "WinRMFQDN" -Or $connectby -eq "WinRMIP") {
            #Import Cert
            Write-Host "Importing Certificate on $vmName" `n -ForegroundColor Green
            Invoke-Command -Session $Session -ScriptBlock $importPfxScript

            # Run the AirWatch prerequisite install script
            Write-Host "Running the AirWatch prequisite installation script on $vmName" `n -ForegroundColor Green
            Invoke-Command -Session $Session -ScriptText $airwatchPreRequisitesScript
            
            # Run the .NET install CMD
            $dotNetDestinationPath = Invoke-Command -Session $Session -ScriptBlock {Get-ChildItem -Path $using:destprereqsDir -Include ndp48*.exe -Recurse -ErrorAction SilentlyContinue}
            #$dotNetInstallCMD = "CMD /C `"$dotNetDestinationPath /q /norestart`""
            Write-Host "Installing .Net on $vmName" `n -ForegroundColor Green
            Invoke-Command -Session $Session -ScriptBlock {CMD /C `"$using:dotNetDestinationPath /q /norestart`"}
            
            # Run the Java install CMD
            $javaDestinationPath = Invoke-Command -Session $Session -ScriptBlock {Get-ChildItem -Path $using:destprereqsDir -Include jre*.exe -Recurse -ErrorAction SilentlyContinue}
            #$JavaInstallCMD = "CMD /C `"$javaDestinationPath INSTALL_SILENT=Enable SPONSORS=0`""
            Write-Host "Installing Java on $vmName" `n -ForegroundColor Green
            Invoke-Command -Session $Session -ScriptBlock {CMD /C `"$using:javaDestinationPath INSTALL_SILENT=Enable SPONSORS=0`"}

            #Set Services Timeout Registry key
            Write-Host "Setting Services Timeout Registry key on $vmName" `n -ForegroundColor Green
            Invoke-Command -Session $Session -ScriptBlock $servicesTimeoutRegistryCmd

        } elseif ($connectby -eq "VMTOOLS") {

            #Import Cert
            Write-Host "Importing Certificate on $vmName" `n -ForegroundColor Green
            Invoke-VMScript -ScriptText $importPfxScript -VM $vmName -GuestCredential $Credential -ScriptType powershell

            # Run the AirWatch prerequisite install script
            Write-Host "Running the AirWatch prequisite installation script on $vmName" `n -ForegroundColor Green
            Invoke-VMScript -ScriptText $airwatchPreRequisitesScript -VM $vmName -GuestCredential $Credential -ScriptType powershell
            
            # Run the .NET install CMD
            $dotNetDestinationPathcmd = "Invoke-Command -Session $Session -ScriptBlock {Get-ChildItem -Path $using:destprereqsDir -Include ndp48*.exe -Recurse -ErrorAction SilentlyContinue}"
            $dotNetDestinationPath = Invoke-VMScript -ScriptText $dotNetDestinationPathcmd -VM $vmName -GuestCredential $Credential -ScriptType powershell
            $dotNetInstallCMD = "CMD /C `"$dotNetDestinationPath /q /norestart`""
            Write-Host "Installing .Net on $vmName" `n -ForegroundColor Green
            Invoke-VMScript -ScriptText $dotNetInstallCMD -VM $vmName -GuestCredential $Credential -ScriptType powershell
            
            # Run the Java install CMD
            $javaDestinationPathcmd = "Invoke-Command -Session $Session -ScriptBlock {Get-ChildItem -Path $using:destprereqsDir -Include jre*.exe -Recurse -ErrorAction SilentlyContinue}"
            $javaDestinationPath = Invoke-VMScript -ScriptText $javaDestinationPathcmd -VM $vmName -GuestCredential $Credential -ScriptType powershell
            $JavaInstallCMD = "CMD /C `"$javaDestinationPath INSTALL_SILENT=Enable SPONSORS=0`""
            Write-Host "Installing Java on $vmName" `n -ForegroundColor Green
            Invoke-VMScript -ScriptText $JavaInstallCMD -VM $vmName -GuestCredential $Credential -ScriptType powershell

            #Set Services Timeout Registry key
            Write-Host "Setting Services Timeout Registry key on $vmName" `n -ForegroundColor Green
            Invoke-VMScript -ScriptText $servicesTimeoutRegistryCmd -VM $vmName -GuestCredential $Credential -ScriptType powershell

            # Restart the VM 
            
        } else {
            Write-Host "Can't connect to $vmName over the network or VMTools. Please Stage files manually." -ForegroundColor Red;Continue
        }

        Write-Host "Restarting $vmName to complete the prerquisite install" `n -ForegroundColor Yellow
        if($connectby -eq "WinRMFQDN") {
            Restart-Computer -ComputerName $vmFqdn -Credential $Credential -Force
        } elseif ($connectby -eq "WinRMIP") {
            Restart-Computer -ComputerName $vmIP -Credential $Credential -Force
        } elseif ($connectby -eq "VMTOOLS") {
            Restart-VMGuest -VM $vmName -Confirm:$false
        }

        Write-Host "Finished the AirWatch prerequisite installs" `n -ForegroundColor Green
    }
    return $completedVMs
}

function Invoke-InstallPhase1 {
    param(
        [array]$vmArray,
        [String] $stagevCenter
    )
    Write-Host "--------------------------PHASE 1--------------------------" `n -ForegroundColor Yellow

    $destprereqsDir = $destinationDir + "\" + $InstallerDir + "\" + $configDir
    $ConfigFile = $vmRole + "_ConfigScript.xml"
    $AppInstallDestBinary = $destinationDir + "\" + $InstallerDir + "\" + $AppInstallerDir

$installAppScriptBlock = @"
CMD /C #AppInstallDestBinary# /s /V`"/qn /lie $destinationDir\AppInstall.log TARGETDIR=$INSTALLDIR INSTALLDIR=$INSTALLDIR AWIGNOREBACKUP=true AWSTAGEAPP=true AWSETUPCONFIGFILE=$ConfigFile`"
"@

    for($i = 0; $i -lt $vmArray.count; $i++){ 
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        $vmIP = $vmArray[$i].IP
        $vmRole = $vmArray[$i].Role
        
        $connectby = Invoke-CheckVMConnectivity -vmName $vmName -vmFqdn $vmFqdn -vmIP $vmIP -stagevCenter $stagevCenter
        if($connectby -eq "WinRMFQDN") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmFqdn
        } elseif ($connectby -eq "WinRMIP") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmIP
        } elseif ($connectby -eq "VMTOOLS") {
            Invoke-ConnecttovCenter -stagevCenter $stagevCenter
        }

        if($connectby -eq "WinRMFQDN" -Or $connectby -eq "WinRMIP") {
            # Run the command to install the AirWatch App  
            $installAppDestPath = Invoke-Command -Session $Session -ScriptBlock {Get-ChildItem -Path $using:AppInstallDestBinary -Include WorkspaceONE_UEM_Application*.exe -Recurse -ErrorAction SilentlyContinue}
            $updinstallAppScriptBlock = $installAppScriptBlock -replace "#AppInstallDestBinary#", $installAppDestPath
            $installSuccessfull = Invoke-Command -Session $Session -ScriptBlock $updinstallAppScriptBlock 
            
            #Check the install worked by looking for this line in the publish log file - "Updating database (Complete)"
            If($installSuccessfull -notlike "*Installation operation completed successfully*"){
                #throw "Failed to setup AirWatch App. Could not find a line in the Publish log that contains `"Installation operation completed successfully`""
            } Else {
                Write-Host "WS1 AppServer has been successfully installed on $vmName" `n -ForegroundColor Green
            }
            
            #Copy SQL Scripts in Application installer directory to SQL Server via this machine
            $CopytoSQLServer = Join-Path -Path $current_path -ChildPath $DBInstallerDir
            Copy-Item -FromSession $Session -Path $AppInstallDestBinary"\*.sql" -Destination $CopytoSQLServer -Force -Confirm:$false
            Write-Host "Important:" `n -ForegroundColor Yellow
            Write-Host "Please copy the $CopytoSQLServer folder including the SQL script files (*.sql) to the SQL Server." `n -ForegroundColor Yellow
            Write-Host "Run the DB upgrade installer followed by these scripts against the WS1 database, AFTER database upgrade!" `n -ForegroundColor Yellow
        } elseif ($connectby -eq "VMTOOLS") {
            # Run the command to install the AirWatch App
            $installAppDestPathcmd = "Invoke-Command -Session $Session -ScriptBlock {Get-ChildItem -Path $using:AppInstallDestBinary -Include WorkspaceONE_UEM_Application*.exe -Recurse -ErrorAction SilentlyContinue}"
            $installAppDestPath = Invoke-VMScript -ScriptText $installAppDestPathcmd -VM $vmName -GuestCredential $Credential -ScriptType powershell
            $updinstallAppScriptBlock = $installAppScriptBlock -replace "#AppInstallDestBinary#", $installAppDestPath
            $installSuccessfull = Invoke-VMScript -ScriptText $updinstallAppScriptBlock -VM $vmName -GuestCredential $Credential -ScriptType powershell
            
            #Check the install worked by looking for this line in the publish log file - "Updating database (Complete)"
            If($installSuccessfull -notlike "*Installation operation completed successfully*"){
                #throw "Failed to setup AirWatch App. Could not find a line in the Publish log that contains `"Installation operation completed successfully`""
            } Else {
                Write-Host "WS1 AppServer has been successfully installed on $vmName" `n -ForegroundColor Green
            }

            #Copy SQL Scripts in Application installer directory to SQL Server via this machine
            $CopytoSQLServer = Join-Path -Path $current_path -ChildPath $DBInstallerDir
            Copy-VMGuestFile -Source $AppInstallDestBinary"\*.sql" -Destination $CopytoSQLServer -VM myVM -GuestToLocal -GuestCredential $Credential
            Write-Host "Important:" `n -ForegroundColor Yellow
            Write-Host "Please copy the $CopytoSQLServer folder including the SQL script files (*.sql) to the SQL Server." `n -ForegroundColor Yellow
            Write-Host "Run the DB upgrade installer followed by these scripts against the WS1 database, AFTER database upgrade!" `n -ForegroundColor Yellow
        } else {
            Write-Host "Cannot Connect to Server $vmName to do Phase 1 Install" `n -ForegroundColor Red
        }
    }
}

function Invoke-InstallPhase2 {
    param(
        [array]$vmArray,
        [String] $stagevCenter
    )

    Write-Host "--------------------------PREREQS--------------------------" `n -ForegroundColor Yellow

    $destprereqsDir = $destinationDir + "\" + $InstallerDir + "\" + $configDir
    $ConfigFile = $vmRole + "_ConfigScript.xml"
    $INSTALL_TOKEN = $WS1Config.globalConfig.INSTALL_TOKEN
    $COMPANY_NAME  = $WS1Config.globalConfig.COMPANY_NAME
    $certinstallerpath = "Supplimental Software\CertInstaller\CertificateInstaller.exe"
    $GEMcertinstallerpath = "Supplimental Software\GEM_Certificate_Install\GEMCertificateInstaller.exe"
    $branchcacheserverkeyinstallerpath = "Supplimental Software\Tools\BranchCacheServerKeyUtility\BranchCacheServerKeyInstaller.exe"

$AllAppServers_ScriptBlock = @"
Start-Process -filepath "#AIRWATCHDIR\$certinstallerpath" -ArgumentList "-t `"$INSTALL_TOKEN`"" -wait
"@

$CN_ScriptBlock = @"
Start-Process -filepath "#AIRWATCHDIR\$GEMcertinstallerpath" -ArgumentList "`"$COMPANY_NAME`"" -wait
"@

$DS_ScriptBlock = @"
Start-Process -filepath "#AIRWATCHDIR\branchcacheserverkeyinstallerpath" -wait
"@

$getAIRWATCHDIR = @"
Get-ItemProperty -Path HKLM:\SOFTWARE\WOW6432Node\AirWatch -ErrorAction SilentlyContinue).AWVERSIONDIR
"@
    for($i = 0; $i -lt $vmArray.count; $i++){ 
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN
        $vmIP = $vmArray[$i].IP
        $vmRole = $vmArray[$i].Role

        $connectby = Invoke-CheckVMConnectivity -vmName $vmName -vmFqdn $vmFqdn -vmIP $vmIP -stagevCenter $stagevCenter
        if($connectby -eq "WinRMFQDN") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmFqdn
        } elseif ($connectby -eq "WinRMIP") {
            $Session = Invoke-CreatePsSession -ServerFqdn $vmIP
        } elseif ($connectby -eq "VMTOOLS") {
            Invoke-ConnecttovCenter -stagevCenter $stagevCenter
        }

        if($connectby -eq "WinRMFQDN" -Or $connectby -eq "WinRMIP") {
            $AIRWATCHDIR = Invoke-Command -Session $Session -ScriptBlock $getAIRWATCHDIR
            $AllAppServers_ScriptBlock_upd = $AllAppServers_ScriptBlock.Replace('#AIRWATCHDIR#',$AIRWATCHDIR)
            Invoke-Command -Session $Session -ScriptBlock $AllAppServers_ScriptBlock_upd

            if ($vmRole -eq "CN"){
                $CN_ScriptBlock_upd = $CN_ScriptBlock.Replace('#AIRWATCHDIR#',$AIRWATCHDIR)
                Invoke-Command -Session $Session -ScriptBlock $CN_ScriptBlock_upd
            } 
            if ($vmRole -eq "DS"){
                $DS_ScriptBlock_upd = $DS_ScriptBlock.Replace('#AIRWATCHDIR#',$AIRWATCHDIR)
                Invoke-Command -Session $Session -ScriptBlock $DS_ScriptBlock_upd
            } 
            # Restart IIS to start AirWatch
            Invoke-Command -Session $Session -ScriptBlock {iisreset}
            
        } elseif ($connectby -eq "VMTOOLS") {
            $AIRWATCHDIR = (Invoke-VMScript -ScriptText $getAIRWATCHDIR -VM $vmName -GuestCredential $Credential -ScriptType powershell).ScriptOutput
            $AllAppServers_ScriptBlock_upd = $AllAppServers_ScriptBlock.Replace('#AIRWATCHDIR#',$AIRWATCHDIR)
            Invoke-VMScript -ScriptText $AllAppServers_ScriptBlock_upd -VM $vmName -GuestCredential $Credential -ScriptType powershell

            if ($vmRole -eq "CN"){
                $CN_ScriptBlock_upd = $CN_ScriptBlock.Replace('#AIRWATCHDIR#',$AIRWATCHDIR)
                Invoke-VMScript -ScriptText $CN_ScriptBlock_upd -VM $vmName -GuestCredential $Credential -ScriptType powershell
            } 
            if ($vmRole -eq "DS"){
                $DS_ScriptBlock_upd = $DS_ScriptBlock.Replace('#AIRWATCHDIR#',$AIRWATCHDIR)
                Invoke-VMScript -ScriptText $DS_ScriptBlock_upd -VM $vmName -GuestCredential $Credential -ScriptType powershell
            } 
            
            # Restart IIS to start AirWatch
            Invoke-VMScript -ScriptText "iisreset" -VM $vmName -GuestCredential $Credential -ScriptType powershell
        } else {
            Write-Host "Cannot Connect to Server $vmName to do Phase 1 Install" `n -ForegroundColor Red
        }
    }
}

Function Invoke-VMToolsCopy {
    param(
        [String] $vmName,
        [String] $vmFqdn,
        [String] $stagevCenter
        #[String] $vcCreds
    )
    
    Invoke-ConnecttovCenter -stagevCenter $stagevCenter
    
    #Check if VMtools installed and we can talk to the VM
    If ( ! (Invoke-CheckVmTools -vmName $vmName)) {
        Write-Error "$vmName VMTools is not responding on $vmName!! Can't stage files to this VM." -ForegroundColor Red;Continue
    } Else {
        #Check if enough free disk space
        $destDrive = $destinationDir.Substring(0,1)
$script = @'

$drive = Get-PSDrive #$destDrive#
$drivefree = $drive.Free/1GB
'@
        # Get the correct value in the variables, then replace the marker in the string with that value
        $testfreespaceScriptBlock = $script.Replace('#$destDrive#',$destDrive)
        $testfreespace = Invoke-VMScript -ScriptText $testfreespaceScriptBlock -VM $vmName -GuestCredential $Credential -ScriptType Powershell
        Write-Host "current free disk space is $testfreespace" -ForegroundColor Yellow

        If ( $testfreespace -lt 10) {
            Write-Host "Target server $vmName does not have more than 10GB free disk space. Cannot continue."; `n  -ForegroundColor Red
            Continue
        } Else {
            #Check if $destinationDir exists
            $destinationFolderExists = (Invoke-VMScript -ScriptText {Test-Path -Path $destinationDir} -VM $vmName  -GuestCredential $Credential -ScriptType Powershell)
            
            If ( ! $destinationFolderExists) {
                #Create destination folders
                Write-Host "Creating $destinationDir folder path to $vmName" -ForegroundColor Green
                $newdestinationDirCMD = "New-Item -Path $destinationDir -ItemType Directory -Force"
                Invoke-VMScript -ScriptText $newdestinationDirCMD -VM $vmName -GuestCredential $Credential

                $desttoolsDirCMD = "New-Item -Path $desttoolsDir -ItemType Directory -Force"
                Invoke-VMScript -ScriptText $desttoolsDirCMD -VM $vmName -GuestCredential $Credential
            } Else {
                # Use 7zip to compress the WS1 installation files into separate 200MB files that aren't too big to copy with VMTools.
                Write-Host "Zipping the WS1 install files into 200MB files on local machine that can be copied with VMTools to $vmName" -ForegroundColor Green
                $7zipsplitCMD = {"$toolsDir\7z.exe a -y -mx1 -v200m $InstallerDir\WS1_Install.7z $InstallerDir"}
                $zipsplitOutput = Invoke-Command -ScriptBlock $7zipsplitCMD
                If ($zipsplitOutput -like "*Error:*") {
                    throw "7zip failed to zip the WS1 install files"
                }
                
                # Capture each of the WS1 zip files and copy them to the destination server
                $7zipsplitFiles = Get-ChildItem -Path $InstallerDir | Where-Object { $_ -like "WS1_Install.7z*" }
                
                # Copy each of the zip files to the destination VM. This takes a long time to use VMTools, but it means we can copy the files to VMs located in the DMZ that don't have direct network access
                foreach ($file in $7zipsplitFiles) {
                    Write-Host "Copying $file of $($7zipsplitFiles.count) total files to $vmName" -ForegroundColor Green
                    Copy-VMGuestFile -LocalToGuest -source $file.FullName -destination $destinationDir -Force -vm $vmName -GuestCredential $Credential 
                }

                # Copy Tools directory containing 7zip to destination VM so that the zip files can be unzipped
                Write-Host "Copying 7-zip to $vmName" -ForegroundColor Green
                Copy-VMGuestFile -LocalToGuest -source $toolsDir -destination $desttoolsDir -Force:$true -vm $vmName -GuestCredential $Credential

                # Unzip the WS1 files on the destination server
                Write-Host "Unzipping the WS1 install files on $vmName" -ForegroundColor Green
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
        $Session
    )

    If ($session -is [System.Management.Automation.Runspaces.PSSession]) {
		Write-Host "Using PowerShell remote session to copy files to $vmName" -ForegroundColor Green
        #Check if enough free disk space
        $destDrive = $destinationDir.SubString(0,1)
        $remoteServerDrive = Invoke-Command -Session $Session -ScriptBlock { Get-PSDrive $using:destDrive }
        $testfreespace = $($remoteServerDrive.Free/1GB)
        
        $desttoolsDir = $destinationDir + "\" + $WS1Config.globalConfig.deploymentDirectories.toolsDir
        $destInstallerDir = $destinationDir + "\" + $WS1Config.globalConfig.deploymentDirectories.InstallerDir

        #Write-Host "current free disk space is $testfreespace"        
        If ( $testfreespace -lt 10) {
            Write-Host "Target server $vmName does not have more than 10GB free disk space. Cannot continue." `n -ForegroundColor Red;Continue
        } Else {
            #write-host "Check if $destinationDir exists first"
            $existsdestinationDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:destinationDir}            
            If (! $existsdestinationDir) {
                #Create base destination folders
                Write-Host "Creating destination base folder $destinationDir on $vmName" -ForegroundColor Green
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:destinationDir -ItemType Directory -Force}
            } Else {
                #Base Directory exists
            }
            
<#             $existsdestInstallerDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:destInstallerDir}
            If (! $existsdestInstallerDir) {
                #Create destination Installer folders
                Write-Host "Creating $destInstallerDir folder in $destinationDir to $vmName" -ForegroundColor Green
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:destInstallerDir -ItemType Directory -Force}
            } Else {
                #Installer Directory exists
            }

            $existsdesttoolsDir = Invoke-Command -Session $Session -ScriptBlock {Test-Path -Path $using:desttoolsDir}
            If (! $existsdesttoolsDir) {
                #Create destination Tools folders
                Write-Host "Creating $desttoolsDir folder in $destinationDir to $vmName" -ForegroundColor Green
                Invoke-Command -Session $Session -ScriptBlock {New-Item -Path $using:desttoolsDir -ItemType Directory -Force}
            } Else {
                #Tools Directory exists
            } #>

            #Copy Tools files to destination $destToolsDir
            write-host "Copying ToolsDir files to $vmName" -ForegroundColor Green
            Copy-Item -ToSession $session -Path $toolsDir -Destination $desttoolsDir -Recurse -Force -Confirm:$false
                        
            #Copy installer zip files to destination directory
            Copy-Item -ToSession $Session -Path $InstallerDir -Destination $destinationDir -Recurse -Force -Confirm:$false
            #Copy-Item -ToSession $Session -Path $InstallerDir -Destination $destInstallerDir -Recurse -Force -Confirm:$false
<#             $WS1InstallerZipFiles = Get-ChildItem -Path $InstallerDir | Where-Object { $_ -like "*.zip" }
            foreach ($file in $WS1InstallerZipFiles) {
                Write-Host "Copying $file of a $($WS1InstallerZipFiles.count) total files to $vmName" -ForegroundColor Green
                Copy-Item -ToSession $Session -Path $file.FullName -Destination $destinationDir -Recurse -Force -Confirm:$false
                $destzipfile = $destinationDir + "\" + $file
                write-host "Expanding $destzipfile to $destInstallerDir" -ForegroundColor Green
                Invoke-Command -session $Session -ScriptBlock {Expand-Archive -Path "$using:destzipfile" -DestinationPath "$using:destInstallerDir" -Force}
            } #>
        #Disconnect from Windows Server
        Remove-PSSession $Session
        
        $CheckPSCopy =  $true
        return $CheckPSCopy
        } 
	} else {
	write-host "no PSSession for $vmName"
        $CheckPSCopy =  $false
        return $CheckPSCopy
    }
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
<#     if((Test-NetConnection -ComputerName $Computer -Port 5986).TcpTestSucceeded -eq $true) {
        $result.stdout += "WinRM enabled successfully.`n"
    } #>
	
    if (Test-WsMan -ComputerName $vmFqdn) {
        Write-Host "Connected to $vmFqdn over the network!" `n -ForegroundColor Green
		$connection = "WinRMFQDN"}
    elseif (Test-WsMan -ComputerName $vmIP){ 
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
            if (Test-WsMan -ComputerName $vmFqdn) {
                Write-Host "Connected to $vmFqdn over the network!" `n -ForegroundColor Green
                $connection = "WinRMFQDN"}
            elseif (Test-WsMan -ComputerName $vmIP){ 
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

Function Invoke-CreatePsSession {
    param(
		[String] $ServerFqdn
    )
    #Add VM to WinRM Trusted Hosts
	set-item WSMan:\localhost\Client\TrustedHosts -Value $ServerFqdn -Force -Confirm:$false
	
	#Write-Host "Attempting to create remote PowerShell session on $ServerFqdn."
    $ReturnValue = New-PSSession -ComputerName $ServerFqdn -Authentication Default -Credential $Credential -ErrorAction SilentlyContinue
    return $ReturnValue
}

Function Invoke-enablePSRemoting {
    param(
        [String] $vmName,
        [String] $stagevCenter
    )
    
    Invoke-ConnecttovCenter -stagevCenter $stagevCenter

$enablepsremotingscript = @'
Set-ExecutionPolicy undefined
Enable-PSRemoting -Force
'@

    #Check if VMtools installed and we can talk to the VM
    If ( ! (Invoke-CheckVmTools -vmName $vmName)) {
        Write-Host "$vmName VMTools is not responding on $vmName!! Can't do any automation on this VM." -ForegroundColor Red
        $CheckPSRemoting =  $false
        return $CheckPSRemoting
    }
    Else {
        #Enable Powershell Remoting
        Write-Host "Enabling Powershell remoting on $vmName" -ForegroundColor Yellow
        Invoke-VMScript -ScriptText $enablepsremotingscript -VM $vmName -GuestCredential $Credential -ScriptType Powershell
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
                    Start-Sleep -Seconds 10
                    #Invoke-StartSleep 10
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

Function zInvoke-CreateVMs {
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
function zcloneVMs {
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
function znewAffinityRule{
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
function zaddLocalAdmin{
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
Function zInvoke-ShutdownVMs {
    param(
        [array] $vmArray,
        [String] $stagevCenter
        )
    
    Invoke-ConnecttovCenter -stagevCenter $stagevCenter
    
    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name

        # Shutdown VM
        Get-VM $vmName | Shutdown-VMGuest
    }
    
    #Disconnect from vCenter Server
    Disconnect-VIServer * -Force -Confirm:$false
}
Function zInvoke-vIDMUpg {
    #script to take all vIDM nodes out of load balancer pools
    #script to add the first vIDM node into the load balancer pool
    #script to ssh to vidm node, su to root and run the following commands
    # /usr/local/horizon/update/updatemgr.hzn updateinstaller
    # /usr/local/horizon/update/updatemgr.hzn check
    # /usr/local/horizon/update/updatemgr.hzn update
    # reboot when done
    #script to add next vIDM node back into load balancer pool and run commands
}
Function zInvoke-RemoteConsole {
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
function zInvoke-StartServices {
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
Function zInvoke-StopServices {
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
function zInvoke-checkAirWatchService{
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
Function zInvoke-SnapshotVMs {
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
    Write-Host "                                                                    " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "          VMware Workspace ONE Blue / Green Upgrade Script          " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "                                                                    " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host `n
    Write-Host "The following tasks can be exectued from this tool" -ForegroundColor Cyan
    Write-Host `n
    Write-Host "1: PHASE 1 - Create New Application Server VMs" -ForegroundColor Cyan `n
    Write-Host "2: PHASE 1 - Stage installer binaries to New Application & DB servers" -ForegroundColor Cyan `n
    Write-Host "3: PHASE 1 - Install Pre-Reqs / Config New Application Servers" -ForegroundColor Cyan `n
    Write-Host "4: PHASE 1 - Run installer (staging mode) on New Application Servers" -ForegroundColor Cyan `n
    Write-Host "5: PHASE 2 - Shutdown Old Application Server VMs" -ForegroundColor Cyan `n
    Write-Host "6: PHASE 2 - Run installer on DB Server" -ForegroundColor Cyan `n
    Write-Host "7: PHASE 2 - Run PHASE 2 components on New Application Servers" -ForegroundColor Cyan `n
    Write-Host "8: PHASE 2 - Add Application Servers into NSX LB Pools" -ForegroundColor Cyan `n
    Write-Host "9: Test Site URLs" -ForegroundColor Cyan `n
    Write-Host "Type 'x' to exit" -ForegroundColor Red
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
        Write-Host "PHASE 1 - Create New Application Server VMs" -ForegroundColor Cyan `n
        Invoke-CreateVMs -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-CreateVMs -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-CreateVMs -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-CreateVMs -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    2 {
        Write-Host "PHASE 1 - Stage installer binaries to New Application & DB servers" -ForegroundColor Cyan `n
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
    3 {
        Write-Host "PHASE 1 - Install Pre-Reqs / Config New Application Servers" -ForegroundColor Cyan `n
        Invoke-InstallPrereqs -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-InstallPrereqs -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPrereqs -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-InstallPrereqs -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    4 {
        Write-Host "PHASE 1 - Run installer (staging mode) on New Application Servers" -ForegroundColor Cyan `n
        Invoke-InstallPhase1 -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-InstallPhase1 -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPhase1 -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-InstallPhase1 -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    5 {
        Write-Host "PHASE 2 - Shutdown Old Application Server VMs" -ForegroundColor Cyan `n
        Write-Host "CURRENTLY DISABLED, PLEASE DO THIS MANUALLY" -ForegroundColor Red `n
    }
    6 {
        Write-Host "PHASE 2 - Run installer on DB Server" -ForegroundColor Cyan `n
        Write-Host "CURRENTLY DISABLED, PLEASE DO THIS MANUALLY" -ForegroundColor Red `n
    }
    7 {
        Write-Host "PHASE 2 - Run PHASE 2 components on Application Servers" -ForegroundColor Cyan `n
        Invoke-InstallPhase2 -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-InstallPhase2 -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        #test if secondary exists
        if($SecvCenter){
            Invoke-InstallPhase2 -vmArray $secAppServers $SecvCenter #$VCSecCred
            Invoke-InstallPhase2 -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    }
    8 {
        Write-Host "PHASE 2 - Add Application Servers into NSX LB Pools" -ForegroundColor Cyan `n
        Write-Host "CURRENTLY DISABLED, PLEASE DO THIS MANUALLY" -ForegroundColor Red `n
    }
    9 {
        Write-Host "Check the install was successfull by use the Web API to see if it responds" -ForegroundColor Cyan `n
        Invoke-CheckURLs -URL $URLs
    }
    x {
        $Quit = $true
        Write-Host "Existing Script" -ForegroundColor Yellow `n
        Stop-Transcript  #Before closing off the script
    }
    Default {}
    }
}



$Host.UI.RawUI.BackgroundColor = $OriginalBackground


