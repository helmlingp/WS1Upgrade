<#
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
$WS1ConfigJson = [String]$args

$WS1ConfigJsonPath = Join-Path -Path $current_path -ChildPath $WS1ConfigJson
$WS1Config = Get-Content -Path $WS1ConfigJsonPath | ConvertFrom-Json
If (!(Test-Path $WS1ConfigJson)) {
    throw "Could not validate the path provided for the EUC Config JSON file!"
}

#Config PS Interface
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
        Write-Host "----------------------------------------------------------------------------"

        #Write-Host "number of VM in the list " + [string]$vmArray[$i]
        # First try to copy WS1 files with PowerShell because it is much faster. If this fails, use VMTools.
        If ( ! (Invoke-CheckVMNetwork $vmFqdn)) {
        
            Write-Host "Can't connect to the $vmFqdn over the network." -ForegroundColor Yellow
            write-host "Will try using VMTools to copy the files" -ForegroundColor Yellow
            Write-Host `n
    
            If ( ! (Invoke-VMToolsCopy $vmName $vmFqdn $stagevCenter)) {
                Write-Error "$vmName VMTools is not responding on $vmName!! Can't stage files to this VM.";Continue
            }
            Else {
                Write-Host "Copied installers to $vmName with VMTools.";Continue
            }
        }
        Else {

            If ( ! (Invoke-enablePSRemoting $vmName $stagevCenter)) {
                Write-Host "$vmName is on the network, but can't enable PS Remoting. Trying VMTools Copy" -ForegroundColor Yellow

                If ( ! (Invoke-VMToolsCopy $vmName $vmFqdn $stagevCenter)) {
                    Write-Error "$vmName VMTools is not responding on $vmName!! Can't stage files to this VM.";Continue
                }
                Else {
                    Write-Host "Copied installers to $vmName with VMTools.";Continue
                }
            }
            Else {
                Write-Host "Powershell Remoting enabled on $vmName. Trying powershell copy." -ForegroundColor Yellow
                
                If ( ! (Invoke-PSCopy $vmName $vmFqdn)) {

                    Write-Host "Couldn't establish a Powershell session. Failing back to VMTools copy process" -ForegroundColor Yellow
                    If ( ! (Invoke-VMToolsCopy $vmName $vmFqdn $stagevCenter)) {
                        Write-Error "$vmName VMTools is not responding on $vmName!! Can't stage files to this VM.";Continue
                    }
                    Else {
                        Write-Host "Copied installers to $vmName with VMTools.";Continue
                    }
                    
                }
                Else {
                    Write-Host "Copied installers to $vmName with Powershell.";Continue
                }
            }
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
        Out-File -FilePath $enablepsremotingscriptfile -InputObject $enablepsremotingscript        
        
        #Copy PS script to VM
        Copy-VMGuestFile -LocalToGuest -source $enablepsremotingscriptfile -destination $destinationDir -Force:$true -vm $vmName -GuestCredential $Credential
        
        $destenablepsremotingscriptfile = $destinationDir + "\" + "enablepsremoting.ps1"

        #Execute PS script to enable PS Remoting
        $executeenablepsremotingscript = "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -NoLogo -NonInteractive -NoProfile -File #destenablepsremotingscriptfile#' -Verb RunAs"
        $executeenablepsremotingscriptBlock = $executeenablepsremotingscript.Replace('#destenablepsremotingscriptfile#',$destenablepsremotingscriptfile)
        #Write-Host $executeenablepsremotingscriptBlock
        Invoke-VMScript -ScriptText $executeenablepsremotingscriptBlock -VM $vmName -GuestCredential $Credential -ScriptType Powershell
        
        #Write-Host $enablePSRemoting
        $CheckPSRemoting =  $true
        return $CheckPSRemoting
    }
}

Function Invoke-PSCopy {
    param(
        [String] $vmName,
        [String] $vmFqdn
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

Function Invoke-Upgrade {
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

function Invoke-CheckVMNetwork{
	param(
		[string]$vmFqdn
	) 
    
    # Check if network is accessible
    if(Test-Connection -ComputerName $vmFqdn -Count 1 -Quiet){
        $checkVM = $true
        #Write-Host "Connected to $vmFqdn over the network!" `n -ForegroundColor Yellow
		return $checkVM
	} else {
        $checkVM = $false
        Write-Host "Unable to reach $vmFqdn over the network!" `n -ForegroundColor Red
		return $checkVM
    }
}

Function Invoke-CheckVmTools {
    param(
        [string]$vmName
    )
    $VM = Get-VM $vmName

    # Check if VM Tools is running
    if ($VM.ExtensionData.Guest.ToolsRunningStatus -ne "GUESTTOOLSRUNNING") {
        $checkVM = $false
        Write-Host "VMTools is not running on $vmName!" -ForegroundColor Red
        return $checkVM
    }
    else {
        $checkVM = $true
        return $checkVM
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
                Write-Host "Starting Workspace ONE services on $serverfqdn" -ForegroundColor Yellow
                Invoke-Command -Session $Session -ScriptBlock { Get-Service bits,*airwatch* | Start-Service -PassThru | Set-Service -StartupType Automatic }
                #Disconnect from Windows Server
                Remove-PSSession $Session }
            Else
                { Write-Host "Remote test failed: $serverfqdn." }
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
                Invoke-Command -Session $Session -ScriptBlock { Get-Service bits,*airwatch* | Stop-Service -PassThru | Set-Service -StartupType Manual }
                #Disconnect from Windows Server
                Remove-PSSession $Session }
            Else
                { Write-Host "Remote test failed: $serverfqdn." }
        }
        Catch {
            If ( ! (Get-VICredentialStoreItem -Host $stagevCenter)) {
                $vcCreds = Get-Credential
                New-VICredentialStoreItem -Host $stagevCenter -User $vcCreds.UserName -Password $vcCreds.GetNetworkCredential().password
                Get-VICredentialStoreItem -Host $stagevCenter | Out-Null
                Export-Clixml   
                }
            Else{
                Connect-VIServer $stagevCenter -SaveCredentials
            }

            #Stop WS1 Services
            Write-Host "Stopping Workspace ONE services on $serverName via VMTools" -ForegroundColor Yellow
            Invoke-VMScript -ScriptText "Get-Service bits,*airwatch* | Stop-Service -PassThru | Set-Service -StartupType Manual" -GuestCredential $vcsession
            #Disconnect from vCenter Server
            Disconnect-VIServer * -Force -Confirm:$false
        }
    }

    #$completedVMs += (Get-VM -Name $vmName)
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

        #Connect to VIServer
        Connect-VIServer $stagevCenter #vcCreds

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

Function Invoke-CreatePsSession ($ServerFqdn) {
    #Write-Host "Attempting to create remote PowerShell session on $ServerFqdn."
    $ReturnValue = New-PSSession -computername $ServerFqdn -credential $Credential -ErrorAction SilentlyContinue
    return $ReturnValue
}

#####################################################################################
######################           SCRIPT STARTS HERE            ######################
#####################################################################################

Write-Host "Process started $logdate"

Function Invoke-Menu {
    #Clear-Host
    Write-Host `n
    Write-Host "                                                 " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "          VMware Workspace ONE Upgrade Script    " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "                                                 " -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host `n
    Write-Host "The following tasks can be exectued from this tool" -ForegroundColor Cyan
    Write-Host `n
    Write-Host "1: Stage installation binaries to target servers" -ForegroundColor Cyan `n
    Write-Host "2: Shutdown WS1 services on application servers" -ForegroundColor Cyan `n
    Write-Host "3: Create VM Snapshots on application servers" -ForegroundColor Cyan `n
    Write-Host "4: Run SQL DB upgrade scripts  ***** Not available yet *****" -ForegroundColor Cyan `n
    Write-Host "5: Startup WS1 Services on Application Services" -ForegroundColor Cyan `n
    Write-Host "6: Upgrade PRIMARY application servers & Startup Services" -ForegroundColor Cyan `n
    Write-Host "7: Upgrade SECONDARY application servers & Startup Services" -ForegroundColor Cyan `n
    Write-Host "8: Upgrade vIDM appliances  ***** Not available yet *****" -ForegroundColor Cyan `n
    Write-Host "9: Test PRIMARY Site URLs" -ForegroundColor Cyan `n
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
        #Stage (Copy) Installer Files to Secondary Servers (except DB Server)
        Write-Host "Staging Installer Files to Secondary Servers"
        Invoke-StageFiles -vmArray $secAppServers $SecvCenter $VCSecCred
        Invoke-StageFiles -vmArray $secDBServers $SecvCenter $VCSecCred
        Invoke-StageFiles -vmArray $secDMZAppServers $SecDMZvCenter $VCDMZSecCred
        #Stage (Copy) Installer Files to Primary Servers (except DB Server)
        Write-Host "Staging Installer Files to Primary Servers"
        Invoke-StageFiles -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-StageFiles -vmArray $priDBServers $PrivCenter #$VCPriCred
        Invoke-StageFiles -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        }
    2 {
        Write-Host "Stopping Services on Application Servers"
        Invoke-StopServices -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-StopServices -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        Invoke-StopServices -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-StopServices -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    3 {
        Write-Host "Snapshot'ing Application Servers"
        Invoke-SnapshotVMs -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-SnapshotVMs -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        Invoke-SnapshotVMs -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-SnapshotVMs -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        }
    4 {
        Write-Host "Please run the DB Upgrade installer/scripts manually on the SQL DB Server"
    }
    5 {
        Write-Host "Starting Services on Application Servers"
        Invoke-StartServices -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-StartServices -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        Invoke-StartServices -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-StartServices -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
    }
    6 {
        Write-Host "Upgrade Primary Servers"
        Invoke-Upgrade -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-Upgrade -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
        Write-Host "Starting Services on Primary Servers"
        Invoke-StartServices -vmArray $priAppServers $PrivCenter #$VCPriCred
        Invoke-StartServices -vmArray $priDMZAppServers $PriDMZvCenter #$VCDMZPriCred
    }
    7 {
        Write-Host "Upgrade Secondary Servers"
        Invoke-Upgrade -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-Upgrade -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
        Write-Host "Starting Services on Primnary Servers"
        Invoke-StartServices -vmArray $secAppServers $SecvCenter #$VCSecCred
        Invoke-StartServices -vmArray $secDMZAppServers $SecDMZvCenter #$VCDMZSecCred
    }
    8 {
        Write-Host "Please run the vIDM Upgrade installer from each vIDM Appliance Console"
    }
    9 {
        Write-Host "Check the install was successfull by use the Web API to see if it responds"
        Check-URLs -URL $URLs
    }
    x {
        $Quit = $true
        Write-Host "Existing Script" -ForegroundColor Green `n
        #Stop-Transcript  #Before closing off the script
    }
    Default {}
    }
}



$Host.UI.RawUI.BackgroundColor = $OriginalBackground


