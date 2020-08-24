<#
========================================================================
 Created on =   05/25/2018
 Created by =   Tai Ratcliff
 Organization = VMware	 
 Filename =     createConfigFiles.ps1
 Example =      createConfigFiles.ps1 -eucConfigJson eucConfig.json

 Internal Confluence page that describes all of hte possible settings can be found here:
 https://confluence-euc.eng.vmware.com/pages/viewpage.action?spaceKey=RM&title=AirWatch+Headless+Installers#AirWatchHeadlessInstallers-ConfigurationXML
========================================================================
#>
If(! $eucConfig){
    Write-Host "Required global variables have not be set. The Install_VMware_EUC.ps1 script configures the environment and sets the global variables that are required to run this script." `n -ForegroundColor Red
    throw "EUC Install Script needs to be executed first."
} Else {
    # Refresh the euc Config information from the JSON
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
# AirWatch XML Config Files
$cnConfigXmlPath = Join-Path -Path $configFilesDirectory -ChildPath $configFileNames.cnConfig
$dsConfigXmlPath = Join-Path -Path $configFilesDirectory -ChildPath $configFileNames.dsConfig
$apiConfigXmlPath = Join-Path -Path $configFilesDirectory -ChildPath $configFileNames.apiConfig

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


function checkVM{
	param(
		[string]$vmName
	)
	$VM = get-vm $vmName -ErrorAction 'silentlycontinue'

	# Confirm the VM exists in vCenter
	If (! $VM){
		$checkVM = $false
		return $checkVM
	}
	
	# Check if VM Toosl is running
	if ($VM.ExtensionData.Guest.ToolsRunningStatus.toupper() -eq "GUESTTOOLSRUNNING"){
		$checkVM = $true	
		return $checkVM
	} else {
		$checkVM = $false
		return $checkVM
	}
}



#####################################################################################
######################           SCRIPT STARTS HERE            ######################
#####################################################################################

$xmlConfig = $airwatchConfig.xmlConfig

# General Config
$INSTALLDIR = $xmlConfig.GLOBAL.INSTALLDIR
$IS_SQLSERVER_SERVER = $xmlConfig.GLOBAL.IS_SQLSERVER_SERVER
$IS_SQLSERVER_AUTHENTICATION = $xmlConfig.GLOBAL.IS_SQLSERVER_AUTHENTICATION
$IS_SQLSERVER_USERNAME = $xmlConfig.GLOBAL.IS_SQLSERVER_USERNAME
$IS_SQLSERVER_DATABASE = $xmlConfig.GLOBAL.IS_SQLSERVER_DATABASE
$IS_SQLSERVER_PASSWORD = $xmlConfig.GLOBAL.IS_SQLSERVER_PASSWORD
$IS_NET_API_LOGON_USERNAME = $xmlConfig.GLOBAL.IS_NET_API_LOGON_USERNAME
$AWSERVER = $xmlConfig.GLOBAL.AWSERVER
$AWSERVERSCHEME = $xmlConfig.GLOBAL.AWSERVERSCHEME
$AWSERVERDS = $xmlConfig.GLOBAL.AWSERVERDS
$AWSERVERDSSCHEME = $xmlConfig.GLOBAL.AWSERVERDSSCHEME
$AWWEBSITE = $xmlConfig.GLOBAL.AWWEBSITE
$AWSITENUMBER = $xmlConfig.GLOBAL.AWSITENUMBER
$AWTCPPORT = $xmlConfig.GLOBAL.AWTCPPORT
$ACMSERVERIP = $xmlConfig.GLOBAL.ACMSERVERIP
$ACMSERVERPORT = $xmlConfig.GLOBAL.ACMSERVERPORT
$ACMWCPORT = $xmlConfig.GLOBAL.ACMWCPORT
$AWCMCLUSTER = $xmlConfig.GLOBAL.AWCMCLUSTER
$AWCMSSLOFFLOADED = $xmlConfig.GLOBAL.AWCMSSLOFFLOADED
$AWCMUSEOWNCERT = $xmlConfig.GLOBAL.AWCMUSEOWNCERT
$AWCMCERT = $xmlConfig.GLOBAL.AWCMCERT
$AWAMIURL = $xmlConfig.GLOBAL.AWAMIURL
$AWGPLAYSEARCHPROXY = $xmlConfig.GLOBAL.AWGPLAYSEARCHPROXY
$AWGPHTTPHOST = $xmlConfig.GLOBAL.AWGPHTTPHOST
$AWGPHTTPPORT = $xmlConfig.GLOBAL.AWGPHTTPPORT
$AWGPHTTPPASSENABLED = $xmlConfig.GLOBAL.AWGPHTTPPASSENABLED
$AWGPHTTPUSERNAME = $xmlConfig.GLOBAL.AWGPHTTPUSERNAME
$AWGPSOCKSHOST = $xmlConfig.GLOBAL.AWGPSOCKSHOST
$AWGPSOCKSPORT = $xmlConfig.GLOBAL.AWGPSOCKSPORT
$AWGPSOCKSPASSENABLED = $xmlConfig.GLOBAL.AWGPSOCKSPASSENABLED
$AWGPSOCKSUSERNAME = $xmlConfig.GLOBAL.AWGPSOCKSUSERNAME
$AWSERVERTNLISTENIP = $xmlConfig.GLOBAL.AWSERVERTNLISTENIP
$AWSERVERTNPORT = $xmlConfig.GLOBAL.WSERVERTNPORT
$AWSERVERTNSCHEME = $xmlConfig.GLOBAL.AWSERVERTNSCHEME
$AWTUNNELQUEUEINTIP = $xmlConfig.GLOBAL.AWTUNNELQUEUEINTIP
$AWTUNNELREMOTEQ = $xmlConfig.GLOBAL.AWTUNNELREMOTEQ
$AWTUNNELREMOTEQNAME = $xmlConfig.GLOBAL.WTUNNELREMOTEQNAME
$AWRCTSPRIVATEPORT = $xmlConfig.GLOBAL.AWRCTSPRIVATEPORT
$AWRCTSPUBLICPORT = $xmlConfig.GLOBAL.AWRCTSPUBLICPORT
$AWDEPLOYMODE = $xmlConfig.GLOBAL.AWDEPLOYMODE
$AWIGNOREBACKUP = $xmlConfig.GLOBAL.AWIGNOREBACKUP
$AWCERTAUTHTOKEN = $xmlConfig.GLOBAL.AWCERTAUTHTOKEN

# API Config
$apiADDLOCAL = $xmlConfig.API.ADDLOCAL
$apiAWAPISSLOFFLOADED = $xmlConfig.API.AWAPISSLOFFLOADED
$apiAWSERVERTN = $xmlConfig.API.AWSERVERTN
$apiAWSERVERTNINTIP = $xmlConfig.API.AWSERVERTNINTIP
$apiAWTUNNELSERVERFRIENDLYNAME = $xmlConfig.API.AWTUNNELSERVERFRIENDLYNAME

# CN Config
$cnADDLOCAL = $xmlConfig.CN.ADDLOCAL
$cnAWAPISSLOFFLOADED = $xmlConfig.CN.AWAPISSLOFFLOADED
$cnAWSERVERTN = $xmlConfig.CN.AWSERVERTN
$cnAWSERVERTNINTIP = $xmlConfig.CN.AWSERVERTNINTIP
$cnAWTUNNELSERVERFRIENDLYNAME = $xmlConfig.CN.AWTUNNELSERVERFRIENDLYNAME

# DS Config
$dsADDLOCAL = $xmlConfig.DS.ADDLOCAL
$dsAWAPISSLOFFLOADED = $xmlConfig.DS.AWAPISSLOFFLOADED
$dsAWSERVERTN = $xmlConfig.DS.AWSERVERTN
$dsAWSERVERTNINTIP = $xmlConfig.DS.AWSERVERTNINTIP
$dsAWTUNNELSERVERFRIENDLYNAME = $xmlConfig.DS.AWTUNNELSERVERFRIENDLYNAME


# CN Config File
$cnConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<properties>
  <property name="ADDLOCAL" value="$cnADDLOCAL" />
  <property name="INSTALLDIR" value="$INSTALLDIR" />
  <property name="IS_SQLSERVER_SERVER" value="$IS_SQLSERVER_SERVER" />
  <property name="IS_SQLSERVER_AUTHENTICATION" value="$IS_SQLSERVER_AUTHENTICATION" />
  <property name="IS_SQLSERVER_USERNAME" value="$IS_SQLSERVER_USERNAME" />
  <property name="IS_SQLSERVER_DATABASE" value="$IS_SQLSERVER_DATABASE" />
  <property name="IS_SQLSERVER_PASSWORD" value="$IS_SQLSERVER_PASSWORD" />
  <property name="IS_NET_API_LOGON_USERNAME" value="$IS_NET_API_LOGON_USERNAME" />
  <property name="AWSERVER" value="$AWSERVER" />
  <property name="AWSERVERSCHEME" value="$AWSERVERSCHEME" />
  <property name="AWSERVERDS" value="$AWSERVERDS" />
  <property name="AWSERVERDSSCHEME" value="$AWSERVERDSSCHEME" />
  <property name="AWAPISSLOFFLOADED" value="$cnAWAPISSLOFFLOADED" />
  <property name="AWWEBSITE" value="AWWEBSITE$" />
  <property name="AWSITENUMBER" value="$AWSITENUMBER" />
  <property name="AWTCPPORT" value="$AWTCPPORT" />
  <property name="ACMSERVERIP" value="$ACMSERVERIP" />
  <property name="ACMSERVERPORT" value="$ACMSERVERPORT" />
  <property name="ACMWCPORT" value="$ACMWCPORT" />
  <property name="AWCMCLUSTER" value="$AWCMCLUSTER" />
  <property name="AWCMSSLOFFLOADED" value="$AWCMSSLOFFLOADED" />
  <property name="AWCMUSEOWNCERT" value="$AWCMUSEOWNCERT" />
  <property name="AWCMCERT" value="$AWCMCERT" />
  <property name="AWAMIURL" value="$AWAMIURL" />
  <property name="AWGPLAYSEARCHPROXY" value="$AWGPLAYSEARCHPROXY" />
  <property name="AWGPHTTPHOST" value="$AWGPHTTPHOST" />
  <property name="AWGPHTTPPORT" value="$AWGPHTTPPORT" />
  <property name="AWGPHTTPPASSENABLED" value="$AWGPHTTPPASSENABLED" />
  <property name="AWGPHTTPUSERNAME" value="$AWGPHTTPUSERNAME" />
  <property name="AWGPSOCKSHOST" value="$AWGPSOCKSHOST" />
  <property name="AWGPSOCKSPORT" value="$AWGPSOCKSPORT" />
  <property name="AWGPSOCKSPASSENABLED" value="$AWGPSOCKSPASSENABLED" />
  <property name="AWGPSOCKSUSERNAME" value="$AWGPSOCKSUSERNAME" />
  <property name="AWSERVERTN" value="$cnAWSERVERTN" />
  <property name="AWSERVERTNINTIP" value="$cnAWSERVERTNINTIP" />
  <property name="AWSERVERTNLISTENIP" value="$AWSERVERTNLISTENIP" />
  <property name="AWSERVERTNPORT" value="$AWSERVERTNPORT" />
  <property name="AWSERVERTNSCHEME" value="$AWSERVERTNSCHEME" />
  <property name="AWTUNNELQUEUEINTIP" value="$AWTUNNELQUEUEINTIP" />
  <property name="AWTUNNELREMOTEQ" value="$AWTUNNELREMOTEQ" />
  <property name="AWTUNNELREMOTEQNAME" value="$AWTUNNELREMOTEQNAME" />
  <property name="AWTUNNELSERVERFRIENDLYNAME" value="$cnAWTUNNELSERVERFRIENDLYNAME" />
  <property name="AWRCTSPRIVATEPORT" value="$AWRCTSPRIVATEPORT" />
  <property name="AWRCTSPUBLICPORT" value="$AWRCTSPUBLICPORT" />
  <property name="AWDEPLOYMODE" value="$AWDEPLOYMODE" />
  <property name="AWIGNOREBACKUP" value="$AWIGNOREBACKUP" />
  <property name="AWCERTAUTHTOKEN" value="$AWCERTAUTHTOKEN" />
</properties>
"@


# DS Config File
$dsConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<properties>
  <property name="ADDLOCAL" value="$dsADDLOCAL" />
  <property name="INSTALLDIR" value="$INSTALLDIR" />
  <property name="IS_SQLSERVER_SERVER" value="$IS_SQLSERVER_SERVER" />
  <property name="IS_SQLSERVER_AUTHENTICATION" value="$IS_SQLSERVER_AUTHENTICATION" />
  <property name="IS_SQLSERVER_USERNAME" value="$IS_SQLSERVER_USERNAME" />
  <property name="IS_SQLSERVER_DATABASE" value="$IS_SQLSERVER_DATABASE" />
  <property name="IS_SQLSERVER_PASSWORD" value="$IS_SQLSERVER_PASSWORD" />
  <property name="IS_NET_API_LOGON_USERNAME" value="$IS_NET_API_LOGON_USERNAME" />
  <property name="AWSERVER" value="$AWSERVER" />
  <property name="AWSERVERSCHEME" value="$AWSERVERSCHEME" />
  <property name="AWSERVERDS" value="$AWSERVERDS" />
  <property name="AWSERVERDSSCHEME" value="$AWSERVERDSSCHEME" />
  <property name="AWAPISSLOFFLOADED" value="$dsAWAPISSLOFFLOADED" />
  <property name="AWWEBSITE" value="$AWWEBSITE" />
  <property name="AWSITENUMBER" value="$AWSITENUMBER" />
  <property name="AWTCPPORT" value="$AWTCPPORT" />
  <property name="ACMSERVERIP" value="$ACMSERVERIP" />
  <property name="ACMSERVERPORT" value="$ACMSERVERPORT" />
  <property name="ACMWCPORT" value="$ACMWCPORT" />
  <property name="AWCMCLUSTER" value="$AWCMCLUSTER" />
  <property name="AWCMSSLOFFLOADED" value="$AWCMSSLOFFLOADED" />
  <property name="AWCMUSEOWNCERT" value="$AWCMUSEOWNCERT" />
  <property name="AWCMCERT" value="$AWCMCERT" />
  <property name="AWAMIURL" value="$AWAMIURL" />
  <property name="AWGPLAYSEARCHPROXY" value="$AWGPLAYSEARCHPROXY" />
  <property name="AWGPHTTPHOST" value="$AWGPHTTPHOST" />
  <property name="AWGPHTTPPORT" value="$AWGPHTTPPORT" />
  <property name="AWGPHTTPPASSENABLED" value="$AWGPHTTPPASSENABLED" />
  <property name="AWGPHTTPUSERNAME" value="$AWGPHTTPUSERNAME" />
  <property name="AWGPSOCKSHOST" value="$AWGPSOCKSHOST" />
  <property name="AWGPSOCKSPORT" value="$AWGPSOCKSPORT" />
  <property name="AWGPSOCKSPASSENABLED" value="$AWGPSOCKSPASSENABLED" />
  <property name="AWGPSOCKSUSERNAME" value="$AWGPSOCKSUSERNAME" />
  <property name="AWSERVERTN" value="$dsAWSERVERTN" />
  <property name="AWSERVERTNINTIP" value="$dsAWSERVERTNINTIP" />
  <property name="AWSERVERTNLISTENIP" value="$AWSERVERTNLISTENIP" />
  <property name="AWSERVERTNPORT" value="$AWSERVERTNPORT" />
  <property name="AWSERVERTNSCHEME" value="$AWSERVERTNSCHEME" />
  <property name="AWTUNNELQUEUEINTIP" value="$AWTUNNELQUEUEINTIP" />
  <property name="AWTUNNELREMOTEQ" value="$AWTUNNELREMOTEQ" />
  <property name="AWTUNNELREMOTEQNAME" value="$AWTUNNELREMOTEQNAME" />
  <property name="AWTUNNELSERVERFRIENDLYNAME" value="$dsAWTUNNELSERVERFRIENDLYNAME" />
  <property name="AWRCTSPRIVATEPORT" value="$AWRCTSPRIVATEPORT" />
  <property name="AWRCTSPUBLICPORT" value="$AWRCTSPUBLICPORT" />
  <property name="AWDEPLOYMODE" value="$AWDEPLOYMODE" />
  <property name="AWIGNOREBACKUP" value="$AWIGNOREBACKUP" />
  <property name="AWCERTAUTHTOKEN" value="$AWCERTAUTHTOKEN" />
</properties>
"@


# API Config File
$apiConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<properties>
  <property name="ADDLOCAL" value="$apiADDLOCAL" />
  <property name="INSTALLDIR" value="$INSTALLDIR" />
  <property name="IS_SQLSERVER_SERVER" value="$IS_SQLSERVER_SERVER" />
  <property name="IS_SQLSERVER_AUTHENTICATION" value="$IS_SQLSERVER_AUTHENTICATION" />
  <property name="IS_SQLSERVER_USERNAME" value="$IS_SQLSERVER_USERNAME" />
  <property name="IS_SQLSERVER_DATABASE" value="$IS_SQLSERVER_DATABASE" />
  <property name="IS_SQLSERVER_PASSWORD" value="$IS_SQLSERVER_PASSWORD" />
  <property name="IS_NET_API_LOGON_USERNAME" value="$IS_NET_API_LOGON_USERNAME" />
  <property name="AWSERVER" value="$AWSERVER" />
  <property name="AWSERVERSCHEME" value="$AWSERVERSCHEME" />
  <property name="AWSERVERDS" value="$AWSERVERDS" />
  <property name="AWSERVERDSSCHEME" value="$AWSERVERDSSCHEME" />
  <property name="AWAPISSLOFFLOADED" value="$apiAWAPISSLOFFLOADED" />
  <property name="AWWEBSITE" value="AWWEBSITE$" />
  <property name="AWSITENUMBER" value="$AWSITENUMBER" />
  <property name="AWTCPPORT" value="$AWTCPPORT" />
  <property name="ACMSERVERIP" value="$ACMSERVERIP" />
  <property name="ACMSERVERPORT" value="$ACMSERVERPORT" />
  <property name="ACMWCPORT" value="$ACMWCPORT" />
  <property name="AWCMCLUSTER" value="$AWCMCLUSTER" />
  <property name="AWCMSSLOFFLOADED" value="$AWCMSSLOFFLOADED" />
  <property name="AWCMUSEOWNCERT" value="$AWCMUSEOWNCERT" />
  <property name="AWCMCERT" value="$AWCMCERT" />
  <property name="AWAMIURL" value="$AWAMIURL" />
  <property name="AWGPLAYSEARCHPROXY" value="$AWGPLAYSEARCHPROXY" />
  <property name="AWGPHTTPHOST" value="$AWGPHTTPHOST" />
  <property name="AWGPHTTPPORT" value="$AWGPHTTPPORT" />
  <property name="AWGPHTTPPASSENABLED" value="$AWGPHTTPPASSENABLED" />
  <property name="AWGPHTTPUSERNAME" value="$AWGPHTTPUSERNAME" />
  <property name="AWGPSOCKSHOST" value="$AWGPSOCKSHOST" />
  <property name="AWGPSOCKSPORT" value="$AWGPSOCKSPORT" />
  <property name="AWGPSOCKSPASSENABLED" value="$AWGPSOCKSPASSENABLED" />
  <property name="AWGPSOCKSUSERNAME" value="$AWGPSOCKSUSERNAME" />
  <property name="AWSERVERTN" value="$apiAWSERVERTN" />
  <property name="AWSERVERTNINTIP" value="$apiAWSERVERTNINTIP" />
  <property name="AWSERVERTNLISTENIP" value="$AWSERVERTNLISTENIP" />
  <property name="AWSERVERTNPORT" value="$AWSERVERTNPORT" />
  <property name="AWSERVERTNSCHEME" value="$AWSERVERTNSCHEME" />
  <property name="AWTUNNELQUEUEINTIP" value="$AWTUNNELQUEUEINTIP" />
  <property name="AWTUNNELREMOTEQ" value="$AWTUNNELREMOTEQ" />
  <property name="AWTUNNELREMOTEQNAME" value="$AWTUNNELREMOTEQNAME" />
  <property name="AWTUNNELSERVERFRIENDLYNAME" value="$apiAWTUNNELSERVERFRIENDLYNAME" />
  <property name="AWRCTSPRIVATEPORT" value="$AWRCTSPRIVATEPORT" />
  <property name="AWRCTSPUBLICPORT" value="$AWRCTSPUBLICPORT" />
  <property name="AWDEPLOYMODE" value="$AWDEPLOYMODE" />
  <property name="AWIGNOREBACKUP" value="$AWIGNOREBACKUP" />
  <property name="AWCERTAUTHTOKEN" value="$AWCERTAUTHTOKEN" />
</properties>
"@


Set-Content -Value $cnConfig -Path $cnConfigXmlPath -Confirm:$false
Set-Content -Value $dsConfig -Path $dsConfigXmlPath -Confirm:$false
Set-Content -Value $apiConfig -Path $apiConfigXmlPath -Confirm:$false


# Add the application directory to the JSON file. 
$eucConfig | ConvertTo-Json -Depth 100 | Set-Content $eucConfigJsonPath



Write-Host "Script Completed" -ForegroundColor Green `n

