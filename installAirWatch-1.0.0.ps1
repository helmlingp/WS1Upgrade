<#
========================================================================
 Created on:   05/25/2018
 Created by:   Tai Ratcliff
 Organization: VMware	 
 Filename:     cloneVMs.ps1
 Example:      cloneVMs.ps1 -eucConfigJson eucConfig.json
========================================================================
#>
<#
param(
    [ValidateScript({Test-Path -Path $_})]
    [String]$eucConfigJson = "$PsScriptRoot\..\..\eucConfig.json"
)

$eucConfig = Get-Content -Path $eucConfigJson | ConvertFrom-Json
#>
If(! $eucConfig){
    Write-Host "Required global variables have not be set. The Install_VMware_EUC.ps1 script configures the environment and sets the global variables that are required to run this script." `n -ForegroundColor Red
    throw "EUC Install Script needs to be executed first."
} Else {
    # Refresh the euc Config information from the JSON
    Write-Host "Refreshing JSON config"
    $eucConfigJsonPath = Join-Path -Path $eucConfig.globalConfig.deploymentDirectories.configFilesDirectory -ChildPath $eucConfig.globalConfig.configFileNames.jsonFile
    $eucConfig = Get-Content -Path $eucConfigJsonPath | ConvertFrom-Json
}


$error.Clear()


# Global variables from JSON
$globalConfig = $eucConfig.globalConfig
    $binaries = $globalConfig.binaries
    $licenseKeys = $globalConfig.licenseKeys
    $deploymentDirectories = $globalConfig.deploymentDirectories
    $configFileNames = $globalConfig.configFileNames
    $serviceAccounts = $globalConfig.serviceAccounts
    $windowsConfig = $globalConfig.windowsConfig
    $domainConfig = $globalConfig.domainConfig
    $certificateConfig = $globalConfig.certificateConfig
    $mgmtvCenterConfig = $globalConfig.mgmtvCenterConfig
    $dmzvCenterConfig = $globalConfig.dmzvCenterConfig
    $networks = $globalConfig.networks
    $affinityRuleName = $globalConfig.affinityRuleName
    $vmFolders = $globalConfig.vmFolders
$nsxConfig = $eucConfig.nsxConfig
$horizonConfig = $eucConfig.horizonConfig
$airwatchConfig = $eucConfig.airwatchConfig
$uagConfig = $eucConfig.uagConfig

# Script specific variables from JSON
$appRootDirectory = $deploymentDirectories.appRootDirectory
$deploymentSourceDirectory = Join-Path -Path $appRootDirectory -ChildPath $deploymentDirectories.sourceDirectory
$deploymentDestinationDirectory = $deploymentDirectories.destinationDirectory
$certificateDirectory = Join-Path -Path $appRootDirectory -ChildPath $deploymentDirectories.certificateDirectory
$toolsDirectory = Join-Path -Path $appRootDirectory -ChildPath $deploymentDirectories.toolsDirectory
$codeDirectory = Join-Path -Path $appRootDirectory -ChildPath $deploymentDirectories.codeDirectory
$configFilesDirectory = Join-Path -Path $appRootDirectory -ChildPath $deploymentDirectories.configFilesDirectory
$destinationConfigFilesDirectory = Join-Path -Path $deploymentDestinationDirectory -ChildPath $deploymentDirectories.configFilesDirectory
# vCenter Config
$mgmtvCenterName = $mgmtvCenterConfig.vCenter
$mgmtvCenterAccount = $serviceAccounts.mgmtvCenterAccount.username
$mgmtvCenterPassword = $serviceAccounts.mgmtvCenterAccount.password
$dmzvCenterName = $dmzvCenterConfig.vCenter
$dmzvCenterAccount = $serviceAccounts.dmzvCenterAccount.username
$dmzvCenterPassword = $serviceAccounts.dmzvCenterAccount.password
# Service Accounts
$airwatchServiceAccountName = $serviceAccounts.airwatchServiceAccount.username
$airwatchServiceAccountPassword = $serviceAccounts.airwatchServiceAccount.password
$horizonServiceAccountName = $serviceAccounts.horizonServiceAccount.username
$horizonServiceAccountPassword = $serviceAccounts.horizonServiceAccount.password
$localDomainAdminUser = $serviceAccounts.localDomainAdmin.username
$localDomainAdminPassword = $serviceAccounts.localDomainAdmin.password
$domainJoinUser = $serviceAccounts.domainJoin.username
$domainJoinPassword = $serviceAccounts.domainJoin.password
# Import arrays of VMs to deploy
$installCn = $airwatchConfig.airwatchServers.CN.installCn
$installDs = $airwatchConfig.airwatchServers.DS.installDs
$connectionServers = $horizonConfig.connectionServerConfig.ConnectionServers
$airwatchCnServers = $airwatchConfig.airwatchServers.CN.servers
$airwatchDsServers = $airwatchConfig.airwatchServers.DS.servers
# CA SSL Certificate config
$pfxFileName = $globalConfig.sslCertificates.airwatch.pfxFileName
$pfxPassword = $globalConfig.sslCertificates.airwatch.pfxPassword
$pfxSourceFilePath = Join-Path -Path $certificateDirectory -ChildPath $pfxFileName
$pfxDestinationFilePath = Join-Path -Path $deploymentDestinationDirectory -ChildPath $pfxFileName
# AirWatch Cert Config
$airwatchCnCommonName = $airwatchConfig.certificateConfig.cnCommonName
$airwatchDsCommonName = $airwatchConfig.certificateConfig.dsCommonName
# IIS Config
$iisSite = $airwatchConfig.iis.iisSiteName
# Windows Source files for installing Windows Features like IIS and .NET
$windowsSourceSxsZip = $binaries.windowsSourceZip
$windowsSourceSxsZipPath = Join-Path -Path $deploymentSourceDirectory -ChildPath $windowsSourceSxsZip
$windowsDestinationSxsZipPath = Join-Path -Path $deploymentDestinationDirectory -ChildPath $windowsSourceSxsZip
$windowsDestinationSxsFolderPath = Join-Path -Path $deploymentDestinationDirectory -ChildPath "\sxs\"
$dotNetBinary = $binaries.dotNet
$dotNetSourcePath = Join-Path -Path $deploymentSourceDirectory -ChildPath $dotNetBinary
$dotNetDestinationPath = Join-Path -Path $deploymentDestinationDirectory -ChildPath $dotNetBinary
# AirWatch Install Files
$airwatchInstallFolderName = $binaries.airwatchInstallFolderName
$airwatchInstallSourceFolderPath = Join-Path -Path $deploymentSourceDirectory -ChildPath $airwatchInstallFolderName
$airwatchAppBinary = $binaries.airwatchAppBinary
$airwatchAppInstallDestinationBinary = Join-Path -Path $deploymentDestinationDirectory -ChildPath $airwatchAppBinary
$airwatchDbInstallBinary = $binaries.airwatchDbBinary
$airwatchDbInstallSourcePath = Join-Path -Path $deploymentSourceDirectory -ChildPath $airwatchDbInstallBinary
$airwatchDbInstallDestinationPath = Join-Path -Path $deploymentDestinationDirectory -ChildPath $airwatchDbInstallBinary
# 7zip Files
$7zipFolderName = $binaries.sevenZipFolderName
$7zipSourceFolderPath = Join-Path -Path $toolsDirectory -ChildPath $7zipFolderName
$7zipDestinationFolderPath = Join-Path $deploymentDestinationDirectory -ChildPath $7zipFolderName
# AirWatch XML Configuration
$xmlConfig = $airwatchConfig.xmlConfig
$dbInstallVM = $airwatchCnServers[0].Name
$installDb = $airwatchConfig.deployAirWatchDb
$INSTALLDIR = $xmlConfig.GLOBAL.INSTALLDIR
$IS_SQLSERVER_SERVER = $xmlConfig.GLOBAL.IS_SQLSERVER_SERVER
$IS_SQLSERVER_AUTHENTICATION = $xmlConfig.GLOBAL.IS_SQLSERVER_AUTHENTICATION
$IS_SQLSERVER_USERNAME = $xmlConfig.GLOBAL.IS_SQLSERVER_USERNAME
$IS_SQLSERVER_DATABASE = $xmlConfig.GLOBAL.IS_SQLSERVER_DATABASE
$IS_SQLSERVER_PASSWORD = $xmlConfig.GLOBAL.IS_SQLSERVER_PASSWORD
$cnUrl = $xmlConfig.GLOBAL.AWSERVER
$dsUrl = $xmlConfig.GLOBAL.AWSERVERDS
# AirWatch XML Config Files
$cnConfigXmlPath = Join-Path -Path $configFilesDirectory -ChildPath $configFileNames.cnConfig
$dsConfigXmlPath = Join-Path -Path $configFilesDirectory -ChildPath $configFileNames.dsConfig
$apiConfigXmlPath = Join-Path -Path $configFilesDirectory -ChildPath $configFileNames.apiConfig
$cnConfigXmlDestinationPath = Join-Path -Path $destinationConfigFilesDirectory -ChildPath $configFileNames.cnConfig
$dsConfigXmlDestinationPath = Join-Path -Path $destinationConfigFilesDirectory -ChildPath $configFileNames.dsConfig
$apiConfigXmlDestinationPath = Join-Path -Path $destinationConfigFilesDirectory -ChildPath $configFileNames.apiConfig

If($error){throw "Failed to validate the required configuration settings"}



function Start-Sleep($seconds) {
    $doneDT = (Get-Date).AddSeconds($seconds)
    while($doneDT -gt (Get-Date)) {
        $secondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $percent = ($seconds - $secondsLeft) / $seconds * 100
        Write-Progress -Activity "Sleeping" -Status "Sleeping..." -SecondsRemaining $secondsLeft -PercentComplete $percent
        [System.Threading.Thread]::Sleep(500)
    }
    Write-Progress -Activity "Sleeping" -Status "Sleeping..." -SecondsRemaining 0 -Completed
}


function checkVMNetwork{
	param(
		[string]$vmFqdn
	) 
    

    # Check if network is accessible
    if(Test-Connection -ComputerName $vmFqdn -Count 1 -Quiet -ErrorAction SilentlyContinue){
    	$checkVM = $true	
		return $checkVM
	} else {
        $checkVM = $false
        Write-Host "Unable to reach $vmFqdn over the network!" `n -ForegroundColor Red
		return $checkVM
    }
}


function checkVmTools{
	param(
		[string]$vmName
	)
	$VM = get-vm $vmName
	
	# Check if VM Tools is running
	if ($VM.ExtensionData.Guest.ToolsRunningStatus.toupper() -ne "GUESTTOOLSRUNNING"){
        $checkVM = $false	
        Write-Host "VMTools is not running on $vmName!" `n -ForegroundColor Red
		return $checkVM
    } 
    $checkVM = $true	
	return $checkVM
}


Function Check-Web($URL){
    If($URL){
        #This will allow self-signed certificates to work
        $CheckWebStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        #Define the total time to wait for a response
        $CheckWebTimeOut = New-TimeSpan -Minutes 5
        Write-Host "Waiting until $URL is available" `n -ForegroundColor Yellow
        $Response = Invoke-WebRequest $URL -ErrorAction SilentlyContinue
        While(($Response.StatusCode -ne "200") -and ($CheckWebStopWatch.Elapsed -le $CheckWebTimeOut)){
            Try{
                $Response = Invoke-WebRequest $URL -ErrorAction SilentlyContinue
            } Catch {
                Start-Sleep -Seconds 10
            }        
        }
        If($Response.StatusCode -eq "200"){
            Write-Host "$URL is now responding" `n -ForegroundColor Green
			return $true
        } Else {
            Write-Host "Timed out while waiting for $URL to respond" -ForegroundColor Red
            return $false
        }
    }
}


function waitForVMs{
    param(
        [Array]$vmArray
    )
    
    # Build an Array of VM Name strings
    $checkVMs = @()

    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
       If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
       
       $checkVMs += $vmArray[$i].Name
    }
    
    # Wait for up to 10 minutes for the VMs to respond before continuing
    for($i = 0; $i -lt 10; $i++){
        foreach($VM in $checkVMs){
            If(checkVmTools -vmName $VM){
                # If the VM is responding them remove it from the array so it doesn't get checked again.
                $checkVMs = $checkVMs | Where-Object {$_ -ne $VM}
            }
        }
        If(! $checkVMs){Break}
        Write-Host "$($checkVMs -join ", ") are not responding. Wait 1 minute and try again...." `n -ForegroundColor Yellow
        Start-Sleep 60
    }
    If(! $checkVMs){
        return $true
    } Else {
        return $false
    }
}

function Unzip
{
    param(
    [string]$zipfile, 
    [string]$outpath
    )
    Add-Type -assembly "system.io.compression.filesystem"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, $outpath)
}


function installAirWatchPrereqs{
    param(
        [String]$guestOsAccount,
        [String]$guestOsPassword,
        [switch]$installPfxFile,
        [string]$commonName,
        [array]$vmArray,
        [Switch]$dbInstall,
        [Parameter(ParameterSetName='CN_Install')]
        [Switch]$cnInstall,
        [Parameter(ParameterSetName='DS_Install')]
        [Switch]$dsInstall,
        [Parameter(ParameterSetName='API_Install')]
        [Switch]$apiInstall
    )

    $completedVMs = @()

    for($i = 0; $i -lt $vmArray.count; $i++){
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        
        $vmName = $vmArray[$i].Name
        $vmFqdn = $vmArray[$i].FQDN

        If( ! (checkVmTools $vmName)){
            Write-Error "$vmName VMTools is not responding on $vmName!!"
            break
        }

        $completedVMs += (Get-VM -Name $vmName)

        Write-Host "Starting the prerequisite install for $vmName" `n -ForegroundColor Yellow

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

        
        $dotNetInstallCMD = "CMD /C `"$dotNetDestinationPath /q /norestart`""
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


function snapshotVMs{
    param(
        [array]$vmArray,
        [String]$snapshotName = "Installing AirWatch"
    )
    # Take Snapshots of each of the connection servers for rollback.    
    for($i = 0; $i -lt $vmArray.count; $i++){ 
        #Skip null or empty properties.
        If ([string]::IsNullOrEmpty($vmArray[$i].Name)){Continue}
        $vmName = $vmArray[$i].Name
        
        # Check the VM is working
        If(!(checkVmTools -vmName $vmName)){throw "Unable to find $vmName. The VM is either not in the inventory or VMTools is not responding"}
        
        # Take a snapshot of the VM before attempting to install Horizon Connection Servers, if one doesn't already exist
        Write-Host "`nTaking snapshots of each of the AirWatch VMs to provide a rollback" -ForegroundColor Yellow
        $Snapshot = Get-Snapshot $vmName | Select-Object Name
        
        If($Snapshot.Name -ne $snapshotName){
            New-Snapshot -VM $vmName -Name $snapshotName -Confirm:$false -WarningAction silentlycontinue | Out-Null
        } Else {
            Write-Host "`nA Snapshot for $vmName already exists. There is no need to take a new snapshot!" -ForegroundColor Yellow
        }
    }
}


# Install database.
function InstallAirWatchDb{
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


# Install AirWatch.
function InstallAirwatch {
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
        $installAppScriptBlock = [scriptblock]::Create("CMD /C $airwatchAppInstallDestinationBinary /s /V`"/qn /lie $deploymentDestinationDirectory\AppInstall.log TARGETDIR=$INSTALLDIR INSTALLDIR=$INSTALLDIR AWIGNOREBACKUP=true AWSETUPCONFIGFILE=$ConfigFile`"")
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


# Start all Airwatch services.
function StartServices
{
	Write-Host "Starting AirWatch services." `n -ForegroundColor Yellow
	try
	{
		Invoke-VMScript -ScriptText "Start-Service AirWatch*,GooglePlayS*,w3sv*,LogInsightAgent*" -VM $vmName -guestuser $airwatchServiceAccountName -guestpassword $airwatchServiceAccountPassword -ScriptType powershell
	}
	catch
	{
		$FailedToStartServices = $True
		Write-Error "Exception: $_"
	}
}


# Stop all AirWatch services.
function StopServices ($Session)
{
	Write-Host "Stopping AirWatch services." `n -ForegroundColor Yellow
    Invoke-VMScript -ScriptText "Stop-Service AirWatch*,GooglePlayS*,w3sv*,LogInsightAgent* -force" -VM $vmName -guestuser $airwatchServiceAccountName -guestpassword $airwatchServiceAccountPassword -ScriptType powershell
}


function checkAirWatchService{
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



# Closes PS Session and exits with value passed.
function DeployExit ($Session, $ExitCode)
{
    Remove-PSSession $Session
	if ($ExitCode -eq 0)
	{
		Write-Host "Success!"
	}
    else
	{
		Write-Error "Ending remote PowerShell session and exiting with $ExitCode. Refer to documentation for information about this exit code."
		if ($FailedToStartServices -eq $True)
		{
			Write-Warning "Some services failed to start. Manually check services and start any that are not running."
		}
	}
	Exit $ExitCode
}


# Try to create a remote PS session.
function CreatePsSession{
    param(
        $ServerFqdn,
        $ServerUser,
        $ServerPass
    )

	try
	{
		Write-Host "Attempting to create remote PowerShell session on $ServerFqdn."
		$ServerPassSs = ConvertTo-SecureString -AsPlainText -Force -String $ServerPass
        $Credential = New-Object -typename System.Management.Automation.PSCredential -argumentlist $ServerUser, $ServerPassSs
		$Session = New-PSSession -computername $ServerFqdn -credential $Credential -erroraction Stop
		Write-Host "Successfully connected to $ServerFqdn."
		return $Session
    
	}
	catch
	{
		Write-Host "An error occurred trying to establish a PowerShell remote session with $ServerFqdn."
		Write-Host ""
		Write-Host "Exception: $_"
		return $False
	}
}


# Remove all of the install files and delete the snapshots
function cleanUpInstall{
    # Remove all of the local guest files after the install is complete
    $removeGuestFiles = [scriptblock]::Create("Remove-Item -Path `"$deploymentDestinationDirectory`" -Recurse -Force")
    Write-Host "Removing left over deployment files from $vmName" -ForegroundColor Yellow `n
    Invoke-VMScript -ScriptText $removeGuestFiles -VM $vmName -guestuser $guestOsAccount -guestpassword $guestOsPassword
}


#####################################################################################
######################           SCRIPT STARTS HERE            ######################
#####################################################################################

Write-Host "`n=============="
Write-Host "DeployAirWatch"
Write-Host "==============" `n

# Connect to Management vCenter Servers
if($global:defaultVIServers.Name -notcontains $mgmtvCenterName){
    Connect-VIServer -Server $mgmtvCenterName -User $mgmtvCenterAccount -Password $mgmtvCenterPassword -Force | Out-Null
}
if($global:defaultVIServers.Name -contains $mgmtvCenterName){
    Write-Host "Successfully connected to $mgmtvCenterName" -ForegroundColor Green `n
} Else {
    Write-Error "Unable to connect to Management vCenter Server"
}

If($installCn){ 
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


If($installDs){
    Write-Host "Install the AirWatch DS Servers in the DMZ environment" `n -ForegroundColor Yellow
    
    # Snapshot the CN VMs before starting the install
    snapshotVMs -vmArray $airwatchDsServers -snapshotName "Installing AirWatch"

    # Start the AirWatch prerequisite installs on the CN Servers
    installAirWatchPrereqs -vmArray $airwatchDsServers -commonName $airwatchDsCommonName -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword -installPfxFile -dsInstall
    waitForVMs -vmArray $airwatchDsServers

    InstallAirwatch -vmArray $airwatchDsServers -guestOsAccount $localDomainAdminUser -guestOsPassword $localDomainAdminPassword -DsInstall
    
    # Check the install was successfull by use the Web API to see if it responds before continuing
    Check-Web -URL $dsUrl
}

Disconnect-VIServer * -Force -Confirm:$false
Write-Host "Script Completed" -ForegroundColor Green `n




