##############################################################################################
# CommonFunctions.psm1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# Operations :
#
<#
.SYNOPSIS
	PS modules for LISAv2 test automation.
	Common functions for running LISAv2 test

.PARAMETER
	<Parameters>

.INPUTS

.NOTES
	Creation Date:
	Purpose/Change:

.EXAMPLE

#>
###############################################################################################

Function Import-TestParameters($ParametersFile)
{
	$paramTable = @{}
	Write-LogInfo "Import test parameters from provided XML file $ParametersFile ..."
	try {
		$LISAv2Parameters = [xml](Get-Content -Path $ParametersFile)
		$ParameterNames = ($LISAv2Parameters.TestParameters.ChildNodes | Where-Object {$_.NodeType -eq "Element"}).Name
		foreach ($ParameterName in $ParameterNames) {
			if ($LISAv2Parameters.TestParameters.$ParameterName) {
				if ($LISAv2Parameters.TestParameters.$ParameterName -eq "true") {
					Write-LogInfo "Setting boolean parameter: $ParameterName = true"
					$paramTable.Add($ParameterName, $true)
				}
				else {
					Write-LogInfo "Setting parameter: $ParameterName = $($LISAv2Parameters.TestParameters.$ParameterName)"
					$paramTable.Add($ParameterName, $LISAv2Parameters.TestParameters.$ParameterName)
				}
			}
		}
	} catch {
		$line = $_.InvocationInfo.ScriptLineNumber
		$script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
		$ErrorMessage =  $_.Exception.Message

		Write-LogErr "EXCEPTION : $ErrorMessage"
		Write-LogErr "Source : Line $line in script $script_name."
	}
	return $paramTable
}

Function Match-TestPriority($currentTest, $TestPriority)
{
    if( -not $TestPriority ) {
        return $True
    }

    if( $TestPriority -eq "*") {
        return $True
    }

    $priorityInXml = $currentTest.Priority
    if (-not $priorityInXml) {
        Write-LogWarn "Priority of $($currentTest.TestName) is not defined, set it to 1 (default)."
        $priorityInXml = 1
    }
    foreach( $priority in $TestPriority.Split(",") ) {
        if ($priorityInXml -eq $priority) {
            return $True
        }
    }
    return $False
}

Function Match-TestTag($currentTest, $TestTag)
{
    if( -not $TestTag ) {
        return $True
    }

    if( $TestTag -eq "*") {
        return $True
    }

    $tagsInXml = $currentTest.Tags
    if (-not $tagsInXml) {
        Write-LogWarn "Test Tags of $($currentTest.TestName) is not defined; include this test case by default."
        return $True
    }
    foreach( $tagInTestRun in $TestTag.Split(",") ) {
        foreach( $tagInTestXml in $tagsInXml.Split(",") ) {
            if ($tagInTestRun -eq $tagInTestXml) {
                return $True
            }
        }
    }
    return $False
}

#
# This function will filter and collect all qualified test cases from XML files.
#
# TestCases will be filtered by (see definition in the test case XML file):
# 1) TestCase "Scope", which is defined by the TestCase hierarchy of:
#    "Platform", "Category", "Area", "TestNames"
# 2) TestCase "Attribute", which can be "Tags", or "Priority"
#
# Before entering this function, $TestPlatform has been verified as "valid" in Run-LISAv2.ps1.
# So, here we don't need to check $TestPlatform
#
Function Collect-TestCases($TestXMLs, $TestCategory, $TestArea, $TestNames, $TestTag, $TestPriority)
{
    $AllLisaTests = @()

    # Check and cleanup the parameters
    if ( $TestCategory -eq "All")   { $TestCategory = "*" }
    if ( $TestArea -eq "All")       { $TestArea = "*" }
    if ( $TestNames -eq "All")      { $TestNames = "*" }
    if ( $TestTag -eq "All")        { $TestTag = "*" }
    if ( $TestPriority -eq "All")   { $TestPriority = "*" }

    if (!$TestCategory) { $TestCategory = "*" }
    if (!$TestArea)     { $TestArea = "*" }
    if (!$TestNames)    { $TestNames = "*" }
    if (!$TestTag)      { $TestTag = "*" }
    if (!$TestPriority) { $TestPriority = "*" }

    # Filter test cases based on the criteria
    foreach ($file in $TestXMLs.FullName) {
        $currentTests = ([xml]( Get-Content -Path $file)).TestCases
        foreach ($test in $currentTests.test){
            if (!($test.Platform.Split(",").Contains($TestPlatform))) {
                continue
            }

            if (!($TestCategory.Split(",").Contains($test.Category)) -and ($TestCategory -ne "*")) {
                continue
            }

            if (!($TestArea.Split(",").Contains($test.Area)) -and ($TestArea -ne "*")) {
                continue
            }

            if (!($TestNames.Split(",").Contains($test.testName)) -and ($TestNames -ne "*")) {
                continue
            }

            $testTagMatched = Match-TestTag -currentTest $test -TestTag $TestTag
            if ($testTagMatched -eq $false) {
                continue
            }

            $testPriorityMatched = Match-TestPriority -currentTest $test -TestPriority $TestPriority
            if ($testPriorityMatched -eq $false) {
                continue
            }

            Write-LogInfo "Collected: $($test.TestName)"
            $AllLisaTests += $test
        }
    }
    return $AllLisaTests
}

# This function set the AdditionalHWConfig of the test case data
# Called when -EnableAcceleratedNetworking or -UseManagedDisks is set
function Set-AdditionalHWConfigInTestCaseData ($CurrentTestData, $ConfigName, $ConfigValue) {
	Write-LogInfo "The AdditionalHWConfig $ConfigName of case $($CurrentTestData.testName) is set to $ConfigValue"
	if (!$CurrentTestData.AdditionalHWConfig) {
		$CurrentTestData.InnerXml += "<AdditionalHWConfig><$ConfigName>$ConfigValue</$ConfigName></AdditionalHWConfig>"
	} elseif ($CurrentTestData.AdditionalHWConfig.$ConfigName) {
		$CurrentTestData.AdditionalHWConfig.$ConfigName = $ConfigValue
	} else {
		$CurrentTestData.AdditionalHWConfig.InnerXml += "<$ConfigName>$ConfigValue</$ConfigName>"
	}
}

function Get-SecretParams {
    <#
    .DESCRIPTION
    Used only if the "SECRET_PARAMS" parameter exists in the test definition xml.
    Used to specify parameters that should be passed to test script but cannot be
    present in the xml test definition or are unknown before runtime.
    #>

    param(
        [array] $ParamsArray,
        [xml] $GlobalConfig,
        [object] $AllVMData
    )

    $testParams = @{}

    foreach ($param in $ParamsArray.Split(',')) {
        switch ($param) {
            "Password" {
                $value = $($GlobalConfig.Global.$global:TestPlatform.TestCredentials.LinuxPassword)
                $testParams["PASSWORD"] = $value
            }
            "RoleName" {
                $value = $AllVMData.RoleName | ?{$_ -notMatch "dependency"}
                $testParams["ROLENAME"] = $value
            }
            "Distro" {
                $value = $detectedDistro
                $testParams["DETECTED_DISTRO"] = $value
            }
            "Ipv4" {
                $value = $AllVMData.PublicIP
                $testParams["ipv4"] = $value
            }
            "VM2Name" {
                $value = $DependencyVmName
                $testParams["VM2Name"] = $value
            }
            "CheckpointName" {
                $value = "ICAbase"
                $testParams["CheckpointName"] = $value
            }
        }
    }

    return $testParams
}

function Parse-TestParameters {
    <#
    .DESCRIPTION
    Converts the parameters specified in the test definition into a hashtable
    to be used later in test.
    #>

    param(
        $XMLParams,
        $GlobalConfig,
        $AllVMData
    )

    $testParams = @{}
    foreach ($param in $XMLParams.param) {
        $name = $param.split("=")[0]
        if ($name -eq "SECRET_PARAMS") {
            $paramsArray = $param.split("=")[1].trim("(",")"," ").split(" ")
            $testParams += Get-SecretParams -ParamsArray $paramsArray `
                 -GlobalConfig $GlobalConfig -AllVMData $AllVMData
        } else {
            $value = $param.split("=")[1]
            $testParams[$name] = $value
        }
    }

    return $testParams
}

function Run-SetupScript {
    <#
    .DESCRIPTION
    Executes a powershell script specified in the <setupscript> tag
    Used to further prepare environment/VM
    #>

    param(
        [string] $Script,
        [hashtable] $Parameters,
        [object] $VMData,
        [object] $CurrentTestData
    )
    $workDir = Get-Location
    $scriptLocation = Join-Path $workDir $Script
    $scriptParameters = ""
    foreach ($param in $Parameters.Keys) {
        $scriptParameters += "${param}=$($Parameters[$param]);"
    }
    $msg = ("Test setup/cleanup started using script:{0} with parameters:{1}" `
             -f @($Script,$scriptParameters))
    Write-LogInfo $msg
    $result = & "${scriptLocation}" -TestParams $scriptParameters -AllVMData $VMData -CurrentTestData $CurrentTestData
    return $result
}

function Run-TestScript {
    <#
    .DESCRIPTION
    Executes test scripts specified in the <testScript> tag.
    Supports python, shell and powershell scripts.
    Python and shell scripts will be executed remotely.
    Powershell scripts will be executed host side.
    After the test completion, the method will collect logs
    (for shell and python) and return the relevant test result.
    #>

    param(
        [object]$CurrentTestData,
        [hashtable]$Parameters,
        [string]$LogDir,
        [object]$VMData,
        [string]$Username,
        [string]$Password,
        [string]$TestLocation,
        [int]$Timeout,
        [xml]$GlobalConfig,
        [object]$TestProvider
    )

    $workDir = Get-Location
    $script = $CurrentTestData.TestScript
    $scriptName = $Script.split(".")[0]
    $scriptExtension = $Script.split(".")[1]
    $constantsPath = Join-Path $workDir "constants.sh"
    $testName = $currentTestData.TestName
    $testResult = ""

    Create-ConstantsFile -FilePath $constantsPath -Parameters $Parameters
    if(!$IsWindows){
        foreach ($VM in $VMData) {
            Copy-RemoteFiles -upload -uploadTo $VM.PublicIP -Port $VM.SSHPort `
                -files $constantsPath -Username $Username -password $Password
            Write-LogInfo "Constants file uploaded to: $($VM.RoleName)"
        }
    }
    Write-LogInfo "Test script: ${Script} started."
    if ($scriptExtension -eq "sh") {
        Run-LinuxCmd -Command "echo '${Password}' | sudo -S -s eval `"export HOME=``pwd``;bash ${Script} > ${TestName}_summary.log 2>&1`"" `
             -Username $Username -password $Password -ip $VMData.PublicIP -Port $VMData.SSHPort `
             -runMaxAllowedTime $Timeout
    } elseif ($scriptExtension -eq "ps1") {
        $scriptDir = Join-Path $workDir "Testscripts\Windows"
        $scriptLoc = Join-Path $scriptDir $Script
        foreach ($param in $Parameters.Keys) {
            $scriptParameters += (";{0}={1}" -f ($param,$($Parameters[$param])))
        }
        Write-LogInfo "${scriptLoc} -TestParams $scriptParameters -AllVmData $VmData -TestProvider $TestProvider -CurrentTestData $CurrentTestData"
        $testResult = & "${scriptLoc}" -TestParams $scriptParameters -AllVmData $VmData -TestProvider $TestProvider -CurrentTestData $CurrentTestData
    } elseif ($scriptExtension -eq "py") {
        Run-LinuxCmd -Username $Username -password $Password -ip $VMData.PublicIP -Port $VMData.SSHPort `
             -Command "python ${Script}" -runMaxAllowedTime $Timeout -runAsSudo
        Run-LinuxCmd -Username $Username -password $Password -ip $VMData.PublicIP -Port $VMData.SSHPort `
             -Command "mv Runtime.log ${TestName}_summary.log" -runAsSudo
    }

    if (-not $testResult) {
        $testResult = Collect-TestLogs -LogsDestination $LogDir -ScriptName $scriptName -TestType $scriptExtension `
             -PublicIP $VMData.PublicIP -SSHPort $VMData.SSHPort -Username $Username -password $Password `
             -TestName $TestName
    }
    return $testResult
}

function Is-VmAlive {
    <#
    .SYNOPSIS
        Checks if a VM responds to TCP connections to the SSH or RDP port.
        If the VM is a Linux on Azure, it also checks the serial console log for kernel panics.

    .OUTPUTS
        Returns "True" or "False"
    #>
    param(
        $AllVMDataObject,
        $MaxRetryCount = 20
    )

    Write-LogInfo "Trying to connect to deployed VMs."

    $retryCount = 0
    $kernelPanicPeriod = 3

    do {
        $deadVms = 0
        $retryCount += 1
        foreach ( $vm in $AllVMDataObject) {
            if ($IsWindows) {
                $port = $vm.RDPPort
            } else {
                $port = $vm.SSHPort
            }

            $out = Test-TCP -testIP $vm.PublicIP -testport $port
            if ($out -ne "True") {
                Write-LogInfo "Connecting to $($vm.PublicIP) and port $port failed."
                $deadVms += 1
                # Note(v-advlad): Check for kernel panic once every ${kernelPanicPeriod} retries on Linux Azure
                if (($retryCount % $kernelPanicPeriod -eq 0) -and ($TestPlatform -eq "Azure") `
                    -and (!$IsWindows) -and (Check-AzureVmKernelPanic $vm)) {
                    Write-LogErr "Linux VM $($vm.RoleName) failed to boot because of a kernel panic."
                    return "False"
                }
            } else {
                Write-LogInfo "Connecting to $($vm.PublicIP):$port succeeded."
            }
        }

        if ($deadVms -gt 0) {
            Write-LogInfo "$deadVms VM(s) still waiting to open port $port."
            Write-LogInfo "Retrying $retryCount/$MaxRetryCount in 3 seconds."
            Start-Sleep -Seconds 3
        } else {
            Write-LogInfo "All VM ports are open."
            return "True"
        }
    } While (($retryCount -lt $MaxRetryCount) -and ($deadVms -gt 0))

    return "False"
}

Function Provision-VMsForLisa($allVMData, $installPackagesOnRoleNames)
{
	$keysGenerated = $false
	foreach ( $vmData in $allVMData )
	{
		Write-LogInfo "Configuring $($vmData.RoleName) for LISA test..."
		Copy-RemoteFiles -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files ".\Testscripts\Linux\utils.sh,.\Testscripts\Linux\enableRoot.sh,.\Testscripts\Linux\enablePasswordLessRoot.sh" -username $user -password $password -upload
		$Null = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "chmod +x /home/$user/*.sh" -runAsSudo
		$rootPasswordSet = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort `
			-username $user -password $password -runAsSudo `
			-command ("/home/{0}/enableRoot.sh -password {1}" -f @($user, $password.Replace('"','')))
		Write-LogInfo $rootPasswordSet
		if (( $rootPasswordSet -imatch "ROOT_PASSWRD_SET" ) -and ( $rootPasswordSet -imatch "SSHD_RESTART_SUCCESSFUL" ))
		{
			Write-LogInfo "root user enabled for $($vmData.RoleName) and password set to $password"
		}
		else
		{
			Throw "Failed to enable root password / starting SSHD service. Please check logs. Aborting test."
		}
		$Null = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "cp -ar /home/$user/*.sh ."
		if ( $keysGenerated )
		{
			Copy-RemoteFiles -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files "$LogDir\sshFix.tar" -username "root" -password $password -upload
			$keyCopyOut = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "./enablePasswordLessRoot.sh"
			Write-LogInfo $keyCopyOut
			if ( $keyCopyOut -imatch "KEY_COPIED_SUCCESSFULLY" )
			{
				$keysGenerated = $true
				Write-LogInfo "SSH keys copied to $($vmData.RoleName)"
				$md5sumCopy = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "md5sum .ssh/id_rsa"
				if ( $md5sumGen -eq $md5sumCopy )
				{
					Write-LogInfo "md5sum check success for .ssh/id_rsa."
				}
				else
				{
					Throw "md5sum check failed for .ssh/id_rsa. Aborting test."
				}
			}
			else
			{
				Throw "Error in copying SSH key to $($vmData.RoleName)"
			}
		}
		else
		{
			$Null = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "rm -rf /root/sshFix*"
			$keyGenOut = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "./enablePasswordLessRoot.sh"
			Write-LogInfo $keyGenOut
			if ( $keyGenOut -imatch "KEY_GENERATED_SUCCESSFULLY" )
			{
				$keysGenerated = $true
				Write-LogInfo "SSH keys generated in $($vmData.RoleName)"
				Copy-RemoteFiles -download -downloadFrom $vmData.PublicIP -port $vmData.SSHPort  -files "/root/sshFix.tar" -username "root" -password $password -downloadTo $LogDir
				$md5sumGen = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "md5sum .ssh/id_rsa"
			}
			else
			{
				Throw "Error in generating SSH key in $($vmData.RoleName)"
			}
		}
	}

	$packageInstallJobs = @()
	foreach ( $vmData in $allVMData )
	{
		if ( $installPackagesOnRoleNames )
		{
			if ( $installPackagesOnRoleNames -imatch $vmData.RoleName )
			{
				Write-LogInfo "Executing $scriptName ..."
				$jobID = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "/root/$scriptName" -RunInBackground
				$packageInstallObj = New-Object PSObject
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name ID -Value $jobID
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name RoleName -Value $vmData.RoleName
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name PublicIP -Value $vmData.PublicIP
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name SSHPort -Value $vmData.SSHPort
				$packageInstallJobs += $packageInstallObj
				#endregion
			}
			else
			{
				Write-LogInfo "$($vmData.RoleName) is set to NOT install packages. Hence skipping package installation on this VM."
			}
		}
		else
		{
			Write-LogInfo "Executing $scriptName ..."
			$jobID = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "/root/$scriptName" -RunInBackground
			$packageInstallObj = New-Object PSObject
			Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name ID -Value $jobID
			Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name RoleName -Value $vmData.RoleName
			Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name PublicIP -Value $vmData.PublicIP
			Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name SSHPort -Value $vmData.SSHPort
			$packageInstallJobs += $packageInstallObj
			#endregion
		}
	}

	$packageInstallJobsRunning = $true
	while ($packageInstallJobsRunning)
	{
		$packageInstallJobsRunning = $false
		foreach ( $job in $packageInstallJobs )
		{
			if ( (Get-Job -Id $($job.ID)).State -eq "Running" )
			{
				$currentStatus = Run-LinuxCmd -ip $job.PublicIP -port $job.SSHPort -username "root" -password $password -command "tail -n 1 /root/provisionLinux.log"
				Write-LogInfo "Package Installation Status for $($job.RoleName) : $currentStatus"
				$packageInstallJobsRunning = $true
			}
			else
			{
				Copy-RemoteFiles -download -downloadFrom $job.PublicIP -port $job.SSHPort -files "/root/provisionLinux.log" -username "root" -password $password -downloadTo $LogDir
				Rename-Item -Path "$LogDir\provisionLinux.log" -NewName "$($job.RoleName)-provisionLinux.log" -Force | Out-Null
			}
		}
		if ( $packageInstallJobsRunning )
		{
			Wait-Time -seconds 10
		}
	}
}

function Install-CustomKernel ($CustomKernel, $allVMData, [switch]$RestartAfterUpgrade, $TestProvider)
{
	try
	{
		$currentKernelVersion = ""
		$upgradedKernelVersion = ""
		$CustomKernel = $CustomKernel.Trim()
		if( ($CustomKernel -ne "ppa") -and ($CustomKernel -ne "linuxnext") -and `
		($CustomKernel -ne "netnext") -and ($CustomKernel -ne "proposed") -and `
		($CustomKernel -ne "proposed-azure") -and ($CustomKernel -ne "proposed-edge") -and `
		($CustomKernel -ne "latest") -and !($CustomKernel.EndsWith(".deb"))  -and `
		!($CustomKernel.EndsWith(".rpm")) )
		{
			Write-LogErr "Only linuxnext, netnext, proposed, proposed-azure, proposed-edge, `
			latest are supported. E.g. -CustomKernel linuxnext/netnext/proposed. `
			Or use -CustomKernel <link to deb file>, -CustomKernel <link to rpm file>"
		}
		else
		{
			$scriptName = "customKernelInstall.sh"
			$jobCount = 0
			$kernelSuccess = 0
			$packageInstallJobs = @()
			$CustomKernelLabel = $CustomKernel
			foreach ( $vmData in $allVMData )
			{
				Copy-RemoteFiles -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files ".\Testscripts\Linux\$scriptName,.\Testscripts\Linux\utils.sh" -username $user -password $password -upload
				if ( $CustomKernel.StartsWith("localfile:")) {
					$customKernelFilePath = $CustomKernel.Replace('localfile:','')
					$customKernelFilePath = (Resolve-Path $customKernelFilePath).Path
					if ($customKernelFilePath -and (Test-Path $customKernelFilePath)) {
						Copy-RemoteFiles -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files $customKernelFilePath `
							-username $user -password $password -upload
					} else {
						Write-LogErr "Failed to find kernel file ${customKernelFilePath}"
						return $false
					}
					$CustomKernelLabel = "localfile:{0}" -f @((Split-Path -Leaf $CustomKernel.Replace('localfile:','')))
				}

				$Null = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "chmod +x *.sh" -runAsSudo
				$currentKernelVersion = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "uname -r"
				Write-LogInfo "Executing $scriptName ..."
				$jobID = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user `
					-password $password -command "/home/$user/$scriptName -CustomKernel '$CustomKernelLabel' -logFolder /home/$user" `
					-RunInBackground -runAsSudo
				$packageInstallObj = New-Object PSObject
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name ID -Value $jobID
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name RoleName -Value $vmData.RoleName
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name PublicIP -Value $vmData.PublicIP
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name SSHPort -Value $vmData.SSHPort
				$packageInstallJobs += $packageInstallObj
				$jobCount += 1
				#endregion
			}
			$packageInstallJobsRunning = $true
			$kernelMatchSuccess = "CUSTOM_KERNEL_SUCCESS"
			while ($packageInstallJobsRunning)
			{
				$packageInstallJobsRunning = $false
				foreach ( $job in $packageInstallJobs )
				{
					if ( (Get-Job -Id $($job.ID)).State -eq "Running" )
					{
						$currentStatus = Run-LinuxCmd -ip $job.PublicIP -port $job.SSHPort -username $user -password $password -command "tail -n 1 build-CustomKernel.txt"
						Write-LogInfo "Package Installation Status for $($job.RoleName) : $currentStatus"
						$packageInstallJobsRunning = $true
						if ($currentStatus -imatch $kernelMatchSuccess) {
							Stop-Job -Id $job.ID -Confirm:$false -ErrorAction SilentlyContinue
						}
					}
					else
					{
						if ( !(Test-Path -Path "$LogDir\$($job.RoleName)-build-CustomKernel.txt" ) )
						{
							Copy-RemoteFiles -download -downloadFrom $job.PublicIP -port $job.SSHPort -files "build-CustomKernel.txt" -username $user -password $password -downloadTo $LogDir
							if ( ( Get-Content "$LogDir\build-CustomKernel.txt" ) -imatch $kernelMatchSuccess )
							{
								$kernelSuccess += 1
							}
							Rename-Item -Path "$LogDir\build-CustomKernel.txt" -NewName "$($job.RoleName)-build-CustomKernel.txt" -Force | Out-Null
						}
					}
				}
				if ( $packageInstallJobsRunning )
				{
					Wait-Time -seconds 5
				}
			}
			if ( $kernelSuccess -eq $jobCount )
			{
				Write-LogInfo "Kernel upgraded to `"$CustomKernel`" successfully in $($allVMData.Count) VM(s)."
				if ( $RestartAfterUpgrade )
				{
					Write-LogInfo "Now restarting VMs..."
					if ( $TestProvider.RestartAllDeployments($allVMData) )
					{
						$retryAttempts = 5
						$isKernelUpgraded = $false
						while ( !$isKernelUpgraded -and ($retryAttempts -gt 0) )
						{
							$retryAttempts -= 1
							$upgradedKernelVersion = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "uname -r"
							Write-LogInfo "Old kernel: $currentKernelVersion"
							Write-LogInfo "New kernel: $upgradedKernelVersion"
							if ($currentKernelVersion -eq $upgradedKernelVersion)
							{
								Write-LogErr "Kernel version is same after restarting VMs."
								if ( ($CustomKernel -eq "latest") -or ($CustomKernel -eq "ppa") -or ($CustomKernel -eq "proposed") )
								{
									Write-LogInfo "Continuing the tests as default kernel is same as $CustomKernel."
									$isKernelUpgraded = $true
								}
								else
								{
									$isKernelUpgraded = $false
								}
							}
							else
							{
								$isKernelUpgraded = $true
							}
							Add-Content -Value "Old kernel: $currentKernelVersion" -Path ".\Report\AdditionalInfo-$TestID.html" -Force
							Add-Content -Value "New kernel: $upgradedKernelVersion" -Path ".\Report\AdditionalInfo-$TestID.html" -Force
							return $isKernelUpgraded
						}
					}
					else
					{
						return $false
					}
				}
				return $true
			}
			else
			{
				Write-LogErr "Kernel upgrade failed in $($jobCount-$kernelSuccess) VMs."
				return $false
			}
		}
	}
	catch
	{
		Write-LogErr "Exception in Install-CustomKernel."
		return $false
	}
}

function Install-CustomLIS ($CustomLIS, $customLISBranch, $allVMData, [switch]$RestartAfterUpgrade, $TestProvider)
{
	try
	{
		$CustomLIS = $CustomLIS.Trim()
		if( ($CustomLIS -ne "lisnext") -and !($CustomLIS.EndsWith("tar.gz")))
		{
			Write-LogErr "Only lisnext and *.tar.gz links are supported. Use -CustomLIS lisnext -LISbranch <branch name>. Or use -CustomLIS <link to tar.gz file>"
		}
		else
		{
			Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames none
			$scriptName = "customLISInstall.sh"
			$jobCount = 0
			$lisSuccess = 0
			$packageInstallJobs = @()
			foreach ( $vmData in $allVMData )
			{
				Copy-RemoteFiles -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files ".\Testscripts\Linux\$scriptName,.\Testscripts\Linux\DetectLinuxDistro.sh" -username "root" -password $password -upload
				$Null = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
				$currentlisVersion = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "modinfo hv_vmbus"
				Write-LogInfo "Executing $scriptName ..."
				$jobID = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "/root/$scriptName -CustomLIS $CustomLIS -LISbranch $customLISBranch" -RunInBackground -runAsSudo
				$packageInstallObj = New-Object PSObject
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name ID -Value $jobID
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name RoleName -Value $vmData.RoleName
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name PublicIP -Value $vmData.PublicIP
				Add-member -InputObject $packageInstallObj -MemberType NoteProperty -Name SSHPort -Value $vmData.SSHPort
				$packageInstallJobs += $packageInstallObj
				$jobCount += 1
				#endregion
			}

			$packageInstallJobsRunning = $true
			while ($packageInstallJobsRunning)
			{
				$packageInstallJobsRunning = $false
				foreach ( $job in $packageInstallJobs )
				{
					if ( (Get-Job -Id $($job.ID)).State -eq "Running" )
					{
						$currentStatus = Run-LinuxCmd -ip $job.PublicIP -port $job.SSHPort -username "root" -password $password -command "tail -n 1 build-CustomLIS.txt"
						Write-LogInfo "Package Installation Status for $($job.RoleName) : $currentStatus"
						$packageInstallJobsRunning = $true
					}
					else
					{
						if ( !(Test-Path -Path "$LogDir\$($job.RoleName)-build-CustomLIS.txt" ) )
						{
							Copy-RemoteFiles -download -downloadFrom $job.PublicIP -port $job.SSHPort -files "build-CustomLIS.txt" -username "root" -password $password -downloadTo $LogDir
							if ( ( Get-Content "$LogDir\build-CustomLIS.txt" ) -imatch "CUSTOM_LIS_SUCCESS" )
							{
								$lisSuccess += 1
							}
							Rename-Item -Path "$LogDir\build-CustomLIS.txt" -NewName "$($job.RoleName)-build-CustomLIS.txt" -Force | Out-Null
						}
					}
				}
				if ( $packageInstallJobsRunning )
				{
					Wait-Time -seconds 10
				}
			}

			if ( $lisSuccess -eq $jobCount )
			{
				Write-LogInfo "lis upgraded to `"$CustomLIS`" successfully in all VMs."
				if ( $RestartAfterUpgrade )
				{
					Write-LogInfo "Now restarting VMs..."
					if ( $TestProvider.RestartAllDeployments($allVMData) )
					{
						$upgradedlisVersion = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "modinfo hv_vmbus"
						Write-LogInfo "Old lis: $currentlisVersion"
						Write-LogInfo "New lis: $upgradedlisVersion"
						Add-Content -Value "Old lis: $currentlisVersion" -Path ".\Report\AdditionalInfo-$TestID.html" -Force
						Add-Content -Value "New lis: $upgradedlisVersion" -Path ".\Report\AdditionalInfo-$TestID.html" -Force
						return $true
					}
					else
					{
						return $false
					}
				}
				return $true
			}
			else
			{
				Write-LogErr "lis upgrade failed in $($jobCount-$lisSuccess) VMs."
				return $false
			}
		}
	}
	catch
	{
		Write-LogErr "Exception in Install-CustomLIS."
		return $false
	}
}

function Verify-MellanoxAdapter($vmData)
{
	$maxRetryAttemps = 50
	$retryAttempts = 1
	$mellanoxAdapterDetected = $false
	while ( !$mellanoxAdapterDetected -and ($retryAttempts -lt $maxRetryAttemps))
	{
		$pciDevices = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "lspci" -runAsSudo
		if ( $pciDevices -imatch "Mellanox")
		{
			Write-LogInfo "[Attempt $retryAttempts/$maxRetryAttemps] Mellanox Adapter detected in $($vmData.RoleName)."
			$mellanoxAdapterDetected = $true
		}
		else
		{
			Write-LogErr "[Attempt $retryAttempts/$maxRetryAttemps] Mellanox Adapter NOT detected in $($vmData.RoleName)."
			$retryAttempts += 1
		}
	}
	return $mellanoxAdapterDetected
}

function Enable-SRIOVInAllVMs($allVMData, $TestProvider)
{
	try
	{
		$scriptName = "ConfigureSRIOV.sh"
		$sriovDetectedCount = 0
		$vmCount = 0

		foreach ( $vmData in $allVMData )
		{
			$vmCount += 1
			$currentMellanoxStatus = Verify-MellanoxAdapter -vmData $vmData
			if ( $currentMellanoxStatus )
			{
				Write-LogInfo "Mellanox Adapter detected in $($vmData.RoleName)."
				Copy-RemoteFiles -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files ".\Testscripts\Linux\$scriptName" -username $user -password $password -upload
				$Null = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "chmod +x *.sh" -runAsSudo
				$sriovOutput = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "/home/$user/$scriptName" -runAsSudo
				$sriovDetectedCount += 1
			}
			else
			{
				Write-LogErr "Mellanox Adapter not detected in $($vmData.RoleName)."
			}
			#endregion
		}

		if ($sriovDetectedCount -gt 0)
		{
			if ($sriovOutput -imatch "SYSTEM_RESTART_REQUIRED")
			{
				Write-LogInfo "Updated SRIOV configuration. Now restarting VMs..."
				$restartStatus = $TestProvider.RestartAllDeployments($allVMData)
			}
			if ($sriovOutput -imatch "DATAPATH_SWITCHED_TO_VF")
			{
				$restartStatus=$true
			}
		}
		$vmCount = 0
		$bondSuccess = 0
		$bondError = 0
		if ( $restartStatus )
		{
			foreach ( $vmData in $allVMData )
			{
				$vmCount += 1
				if ($sriovOutput -imatch "DATAPATH_SWITCHED_TO_VF")
				{
					$AfterIfConfigStatus = $null
					$AfterIfConfigStatus = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "dmesg" -runMaxAllowedTime 30 -runAsSudo
					if ($AfterIfConfigStatus -imatch "Data path switched to VF")
					{
						Write-LogInfo "Data path already switched to VF in $($vmData.RoleName)"
						$bondSuccess += 1
					}
					else
					{
						Write-LogErr "Data path not switched to VF in $($vmData.RoleName)"
						$bondError += 1
					}
				}
				else
				{
					$AfterIfConfigStatus = $null
					$AfterIfConfigStatus = Run-LinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "/sbin/ifconfig -a" -runAsSudo
					if ($AfterIfConfigStatus -imatch "bond")
					{
						Write-LogInfo "New bond detected in $($vmData.RoleName)"
						$bondSuccess += 1
					}
					else
					{
						Write-LogErr "New bond not detected in $($vmData.RoleName)"
						$bondError += 1
					}
				}
			}
		}
		else
		{
			return $false
		}
		if ($vmCount -eq $bondSuccess)
		{
			return $true
		}
		else
		{
			return $false
		}
	}
	catch
	{
		$line = $_.InvocationInfo.ScriptLineNumber
		$script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
		$ErrorMessage =  $_.Exception.Message
		Write-LogErr "EXCEPTION : $ErrorMessage"
		Write-LogErr "Source : Line $line in script $script_name."
		return $false
	}
}

Function Set-CustomConfigInVMs($CustomKernel, $CustomLIS, $EnableSRIOV, $AllVMData, $TestProvider) {
	$retValue = $true
	if ( $CustomKernel)
	{
		Write-LogInfo "Custom kernel: $CustomKernel will be installed on all machines..."
		$kernelUpgradeStatus = Install-CustomKernel -CustomKernel $CustomKernel -allVMData $AllVMData -RestartAfterUpgrade -TestProvider $TestProvider
		if ( !$kernelUpgradeStatus )
		{
			Write-LogErr "Custom Kernel: $CustomKernel installation FAIL. Aborting tests."
			$retValue = $false
		}
	}
	if ( $CustomLIS)
	{
		Write-LogInfo "Custom LIS: $CustomLIS will be installed on all machines..."
		$LISUpgradeStatus = Install-CustomLIS -CustomLIS $CustomLIS -allVMData $AllVMData -customLISBranch $customLISBranch -RestartAfterUpgrade -TestProvider $TestProvider
		if ( !$LISUpgradeStatus )
		{
			Write-LogErr "Custom Kernel: $CustomKernel installation FAIL. Aborting tests."
			$retValue = $false
		}
	}
	if ( $EnableSRIOV)
	{
		$SRIOVStatus = Enable-SRIOVInAllVMs -allVMData $AllVMData -TestProvider $TestProvider
		if ( !$SRIOVStatus)
		{
			Write-LogErr "Failed to enable Accelerated Networking. Aborting tests."
			$retValue = $false
		}
	}
    return $retValue
}

Function Detect-LinuxDistro() {
	param(
		[Parameter(Mandatory=$true)][string]$VIP,
		[Parameter(Mandatory=$true)][string]$SSHPort,
		[Parameter(Mandatory=$true)][string]$testVMUser,
		[Parameter(Mandatory=$true)][string]$testVMPassword
	)

	$null = Copy-RemoteFiles  -upload -uploadTo $VIP -port $SSHport -files ".\Testscripts\Linux\DetectLinuxDistro.sh" -username $testVMUser -password $testVMPassword 2>&1 | Out-Null
	$null = Run-LinuxCmd -username $testVMUser -password $testVMPassword -ip $VIP -port $SSHport -command "chmod +x *.sh" -runAsSudo 2>&1 | Out-Null

	$DistroName = Run-LinuxCmd -username $testVMUser -password $testVMPassword -ip $VIP -port $SSHport -command "/home/$user/DetectLinuxDistro.sh" -runAsSudo

	if(($DistroName -imatch "Unknown") -or (!$DistroName)) {
		Write-LogErr "Linux distro detected : $DistroName"
		# Instead of throw, it sets 'Unknown' if it does not exist
		$CleanedDistroName = "Unknown"
	} else {
		$CleanedDistroName = $DistroName
		Set-Variable -Name detectedDistro -Value $CleanedDistroName -Scope Global
		Set-DistroSpecificVariables -detectedDistro $detectedDistro
		Write-LogInfo "Linux distro detected : $CleanedDistroName"
	}

	return $CleanedDistroName
}

Function Remove-AllFilesFromHomeDirectory($AllDeployedVMs, $User, $Password)
{
	foreach ($DeployedVM in $AllDeployedVMs)
	{
		$testIP = $DeployedVM.PublicIP
		$testPort = $DeployedVM.SSHPort
		try
		{
			Write-LogInfo "Removing all files logs from IP : $testIP PORT : $testPort"
			$Null = Run-LinuxCmd -username $User -password $Password -ip $testIP -port $testPort -command 'rm -rf *' -runAsSudo
			Write-LogInfo "All files removed from /home/$user successfully. VM IP : $testIP PORT : $testPort"
		}
		catch
		{
			$ErrorMessage =  $_.Exception.Message
			Write-Output "EXCEPTION : $ErrorMessage"
			Write-Output "Unable to remove files from IP : $testIP PORT : $testPort"
		}
	}
}

function Get-VMFeatureSupportStatus {
	<#
	.Synopsis
		Check if VM supports a feature or not.
	.Description
		Check if VM supports one feature or not based on comparison
			of current kernel version with feature supported kernel version.
		If the current version is lower than feature supported version,
			return false, otherwise return true.
	.Parameter Ipv4
		IPv4 address of the Linux VM.
	.Parameter SSHPort
		SSH port used to connect to VM.
	.Parameter Username
		Username used to connect to the Linux VM.
	.Parameter Password
		Password used to connect to the Linux VM.
	.Parameter Supportkernel
		The kernel version number starts to support this feature, e.g. supportkernel = "3.10.0.383"
	.Example
		Get-VMFeatureSupportStatus $ipv4 $SSHPort $Username $Password $Supportkernel
	#>

	param (
		[String] $Ipv4,
		[String] $SSHPort,
		[String] $Username,
		[String] $Password,
		[String] $SupportKernel
	)

	Write-Output "yes" | .\Tools\plink.exe -C -pw $Password -P $SSHPort $Username@$Ipv4 'exit 0'
	$currentKernel = Write-Output "yes" | .\Tools\plink.exe -C -pw $Password -P $SSHPort $Username@$Ipv4  "uname -r"
	if( $LASTEXITCODE -eq $false){
		Write-LogInfo "Warning: Could not get kernel version".
	}
	$sKernel = $SupportKernel.split(".-")
	$cKernel = $currentKernel.split(".-")

	for ($i=0; $i -le 3; $i++) {
		if ($cKernel[$i] -lt $sKernel[$i] ) {
			$cmpResult = $false
			break;
		}
		if ($cKernel[$i] -gt $sKernel[$i] ) {
			$cmpResult = $true
			break
		}
		if ($i -eq 3) { $cmpResult = $True }
	}
	return $cmpResult
}

function Get-SelinuxAVCLog() {
	<#
	.Synopsis
		Check selinux audit.log in Linux VM for avc denied log.
	.Description
		Check audit.log in Linux VM for avc denied log.
		If get avc denied log for hyperv daemons, return $true, else return $false.
	#>

	param (
		[String] $Ipv4,
		[String] $SSHPort,
		[String] $Username,
		[String] $Password
	)

	$FILE_NAME = ".\audit.log"
	$TEXT_HV = "hyperv"
	$TEXT_AVC = "type=avc"

	Write-Output "yes" | .\Tools\plink.exe -C -pw $Password -P $SSHPort $Username@$Ipv4 "ls /var/log/audit/audit.log > /dev/null 2>&1"
	if (-not $LASTEXITCODE) {
		Write-LogErr "Warning: Unable to find audit.log from the VM, ignore audit log check"
		return $True
	}
	Write-Output "yes" | .\Tools\pscp -C -pw $Password -P $SSHPort $Username@${Ipv4}:/var/log/audit/audit.log $filename
	if (-not $LASTEXITCODE) {
		Write-LogErr "ERROR: Unable to copy audit.log from the VM"
		return $False
	}

	$file = Get-Content $FILE_NAME
	Remove-Item $FILE_NAME
	foreach ($line in $file) {
		if ($line -match $TEXT_HV -and $line -match $TEXT_AVC){
			Write-LogErr "ERROR: get the avc denied log: $line"
			return $True
		}
	}
	Write-LogErr "Info: no avc denied log in audit log as expected"
	return $False
}

function Check-FileInLinuxGuest{
	param (
		[String] $vmPassword,
		[String] $vmPort,
		[string] $vmUserName,
		[string] $ipv4,
		[string] $fileName,
		[boolean] $checkSize = $False ,
		[boolean] $checkContent = $False
	)
<#
	.Synopsis
		Checks if test file is present or not
	.Description
		Checks if test file is present or not, if set $checkSize as $True, return file size,
		if set checkContent as $True, will return file content.
#>
	if ($checkSize) {

		Write-Output "yes" | .\Tools\plink.exe -C -pw $vmPassword -P $vmPort $vmUserName@$ipv4 "wc -c < $fileName"
	}
	else {
		Write-Output "yes" | .\Tools\plink.exe -C -pw $vmPassword -P $vmPort $vmUserName@$ipv4 "stat ${fileName} >/dev/null"
	}

	if (-not $?) {
		return $False
	}
	if ($checkContent) {

		Write-Output "yes" | .\Tools\plink.exe -C -pw $vmPassword -P $vmPort $vmUserName@$ipv4 "cat ${fileName}"
		if (-not $?) {
			return $False
		}
	}
	return  $True
}

function Mount-Disk{
	param(
		[string] $vmUsername,
		[string] $vmPassword,
		[string] $vmPort,
		[string] $ipv4
	)
<#
	.Synopsis
	Mounts and formats to ext4 a disk on vm
	.Description
	Mounts and formats to ext4 a disk on vm

	#>

	$cmdToVM = @"
	#!/bin/bash
	# /dev/sdc is used as /dev/sdb is the resource disk by default
	(echo d;echo;echo w)|fdisk /dev/sdc
	(echo n;echo p;echo 1;echo;echo;echo w)|fdisk /dev/sdc
	if [ $? -ne 0 ];then
		echo "Failed to create partition..."
		exit 1
	fi
	mkfs.ext4 /dev/sdc1
	mkdir -p /mnt/test
	mount /dev/sdc1 /mnt/test
	if [ $? -ne 0 ];then
		echo "Failed to mount partition to /mnt/test..."
		exit 1
	fi
"@
	$filename = "MountDisk.sh"
	if (Test-Path ".\${filename}") {
		Remove-Item ".\${filename}"
	}
		Add-Content $filename "$cmdToVM"
		Copy-RemoteFiles -uploadTo $ipv4 -port $vmPort -files $filename -username $vmUsername -password $vmPassword -upload
		$MountDisk = Run-LinuxCmd -username $vmUsername -password $vmPassword -ip $ipv4 -port $vmPort -command  `
		"chmod u+x ${filename} && ./${filename}" -runAsSudo
	if ($MountDisk){
		Write-LogInfo "Mounted /dev/sdc1 to /mnt/test"
		return $True
	}
}

function Remove-TestFile{
	param(
		[String] $pathToFile,
		[String] $testfile
	)
<#
	.Synopsis
	Delete temporary test file
	.Description
	Delete temporary test file

	#>

	Remove-Item -Path $pathToFile -Force
	if ($? -ne "True") {
		Write-LogErr "cannot remove the test file '${testfile}'!"
		return $False
	}
}

function Get-RemoteFileInfo{
	param (
		[String] $filename,
		[String] $server
	)

	$fileInfo = $null

	if (-not $filename)
	{
		return $null
	}

	if (-not $server)
	{
		return $null
	}

	$remoteFilename = $filename.Replace("\", "\\")
	$fileInfo = Get-WmiObject -query "SELECT * FROM CIM_DataFile WHERE Name='${remoteFilename}'" -computer $server

	return $fileInfo
}

function Check-Systemd {
	param (
		[String] $Ipv4,
		[String] $SSHPort,
		[String] $Username,
		[String] $Password
	)

	$check1 = $true
	$check2 = $true

	Write-Output "yes" | .\Tools\plink.exe -C -pw $Password -P $SSHPort $Username@$Ipv4 "ls -l /sbin/init | grep systemd"
	if ($LASTEXITCODE -gt "0") {
	Write-LogInfo "Systemd not found on VM"
	$check1 = $false
	}
	Write-Output "yes" | .\Tools\plink.exe -C -pw $Password -P $SSHPort $Username@$Ipv4 "systemd-analyze --help"
	if ($LASTEXITCODE -gt "0") {
		Write-LogInfo "Systemd-analyze not present on VM."
		$check2 = $false
	}

	return ($check1 -and $check2)
}


function Wait-ForVMToStartSSH {
	#  Wait for a Linux VM to start SSH. This is done by testing
	# if the target machine is listening on port 22.
	param (
		[String] $Ipv4addr,
		[int] $StepTimeout
	)
	$retVal = $False

	$waitTimeOut = $StepTimeout
	while ($waitTimeOut -gt 0) {
		$sts = Test-Port -ipv4addr $Ipv4addr -timeout 5
		if ($sts) {
			return $True
		}

		$waitTimeOut -= 15  # Note - Test Port will sleep for 5 seconds
		Start-Sleep -s 10
	}

	if (-not $retVal) {
		Write-LogErr "Wait-ForVMToStartSSH: VM did not start SSH within timeout period ($StepTimeout)"
	}

	return $retVal
}

function Test-Port {
	# Test if a remote host is listening on a specific TCP port
	# Wait only timeout seconds.
	param (
		[String] $Ipv4addr,
		[String] $PortNumber=22,
		[int] $Timeout=5
	)

	$retVal = $False
	$to = $Timeout * 1000

	# Try an async connect to the specified machine/port
	$tcpClient = New-Object system.Net.Sockets.TcpClient
	$iar = $tcpclient.BeginConnect($Ipv4addr,$PortNumber,$null,$null)

	# Wait for the connect to complete. Also set a timeout
	# so we don't wait all day
	$connected = $iar.AsyncWaitHandle.WaitOne($to,$false)

	# Check to see if the connection is done
	if ($connected) {
		# Close our connection
		try {
			$Null = $tcpclient.EndConnect($iar)
			$retVal = $true
		} catch {
			Write-LogInfo $_.Exception.Message
		}
	}
	$tcpclient.Close()

	return $retVal
}

Function Test-SRIOVInLinuxGuest {
	param (
		#Required
		[string]$username,
		[string]$password,
		[string]$IpAddress,
		[int]$SSHPort,

		#Optional
		[int]$ExpectedSriovNics
	)

	$MaximumAttempts = 10
	$Attempts = 1
	$VerificationCommand = "lspci | grep Mellanox | wc -l"
	$retValue = $false
	while ($retValue -eq $false -and $Attempts -le $MaximumAttempts) {
		Write-LogInfo "[Attempt $Attempts/$MaximumAttempts] Detecting Mellanox NICs..."
		$DetectedSRIOVNics = Run-LinuxCmd -username $username -password $password -ip $IpAddress -port $SSHPort -command $VerificationCommand -runAsSudo
		$DetectedSRIOVNics = [int]$DetectedSRIOVNics
		if ($ExpectedSriovNics -ge 0) {
			if ($DetectedSRIOVNics -eq $ExpectedSriovNics) {
				$retValue = $true
				Write-LogInfo "$DetectedSRIOVNics Mellanox NIC(s) deteted in VM. Expected: $ExpectedSriovNics."
			} else {
				$retValue = $false
				Write-LogErr "$DetectedSRIOVNics Mellanox NIC(s) deteted in VM. Expected: $ExpectedSriovNics."
				Start-Sleep -Seconds 20
			}
		} else {
			if ($DetectedSRIOVNics -gt 0) {
				$retValue = $true
				Write-LogInfo "$DetectedSRIOVNics Mellanox NIC(s) deteted in VM."
			} else {
				$retValue = $false
				Write-LogErr "$DetectedSRIOVNics Mellanox NIC(s) deteted in VM."
				Start-Sleep -Seconds 20
			}
		}
		$Attempts += 1
	}
	return $retValue
}

Function Set-SRIOVInVMs {
    param (
        [object]$AllVMData,
        [string]$VMNames,
        [switch]$Enable,
        [switch]$Disable
    )

    if ( $TestPlatform -eq "Azure") {
        Write-LogInfo "Set-SRIOVInVMs running in 'Azure' mode."
        if ($Enable) {
            if ($VMNames) {
                $retValue = Set-SRIOVinAzureVMs -AllVMData $AllVMData -VMNames $VMNames -Enable
            }
            else {
                $retValue = Set-SRIOVinAzureVMs -AllVMData $AllVMData -Enable
            }
        }
        elseif ($Disable) {
            if ($VMNames) {
                $retValue = Set-SRIOVinAzureVMs -AllVMData $AllVMData -VMNames $VMNames -Disable
            }
            else {
                $retValue = Set-SRIOVinAzureVMs -AllVMData $AllVMData -Disable
            }
        }
    }
    elseif ($TestPlatform -eq "HyperV") {
        <#
        ####################################################################
        # Note: Function Set-SRIOVinHypervVMs needs to be implemented in HyperV.psm1.
        # It should allow the same parameters as implemented for Azure.
        #   -HyperVGroup [string]
        #   -VMNames [string] ... comma separated VM names. [Optional]
        #        If no VMNames is provided, it should pick all the VMs from HyperVGroup
        #   -Enable
        #   -Disable
        ####################################################################
        Write-LogInfo "Set-SRIOVInVMs running in 'HyperV' mode."
        if ($Enable) {
            if ($VMNames) {
                $retValue = Set-SRIOVinHypervVMs -HyperVGroup $VirtualMachinesGroupName -VMNames $VMNames -Enable
            }
            else {
                $retValue = Set-SRIOVinHypervVMs -HyperVGroup $VirtualMachinesGroupName -Enable
            }
        }
        elseif ($Disable) {
            if ($VMNames) {
                $retValue = Set-SRIOVinHypervVMs -HyperVGroup $VirtualMachinesGroupName -VMNames $VMNames -Disable
            }
            else {
                $retValue = Set-SRIOVinHypervVMs -HyperVGroup $VirtualMachinesGroupName -Disable
            }
        }
        #>
        $retValue = $false
    }
    return $retValue
}



# Returns an unused random MAC capable
# The address will be outside of the dynamic MAC pool
# Note that the Manufacturer bytes (first 3 bytes) are also randomly generated
function Get-RandUnusedMAC {
    param (
        [String] $HvServer,
        [Char] $Delim
    )
    # First get the dynamic pool range
    $dynMACStart = (Get-VMHost -ComputerName $HvServer).MacAddressMinimum
    $validMac = Is-ValidMAC $dynMACStart
    if (-not $validMac) {
        return $false
    }

    $dynMACEnd = (Get-VMHost -ComputerName $HvServer).MacAddressMaximum
    $validMac = Is-ValidMAC $dynMACEnd
    if (-not $validMac) {
        return $false
    }

    [uint64]$lowerDyn = "0x$dynMACStart"
    [uint64]$upperDyn = "0x$dynMACEnd"
    if ($lowerDyn -gt $upperDyn) {
        return $false
    }

    # leave out the broadcast address
    [uint64]$maxMac = 281474976710655 #FF:FF:FF:FF:FF:FE

    # now random from the address space that has more macs
    [uint64]$belowPool = $lowerDyn - [uint64]1
    [uint64]$abovePool = $maxMac - $upperDyn

    if ($belowPool -gt $abovePool) {
        [uint64]$randStart = [uint64]1
        [uint64]$randStop = [uint64]$lowerDyn - [uint64]1
    } else {
        [uint64]$randStart = $upperDyn + [uint64]1
        [uint64]$randStop = $maxMac
    }

    # before getting the random number, check all VMs for static MACs
    $staticMacs = (get-VM -computerName $hvServer | Get-VMNetworkAdapter | where { $_.DynamicMacAddressEnabled -like "False" }).MacAddress
    do {
        # now get random number
        [uint64]$randDecAddr = Get-Random -minimum $randStart -maximum $randStop
        [String]$randAddr = "{0:X12}" -f $randDecAddr

        # Now set the unicast/multicast flag bit.
        [Byte] $firstbyte = "0x" + $randAddr.substring(0,2)
        # Set low-order bit to 0: unicast
        $firstbyte = [Byte] $firstbyte -band [Byte] 254 #254 == 11111110

        $randAddr = ("{0:X}" -f $firstbyte).padleft(2,"0") + $randAddr.substring(2)

    } while ($staticMacs -contains $randAddr) # check that we didn't random an already assigned MAC Address

    # randAddr now contains the new random MAC Address
    # add delim if specified
    if ($Delim) {
        for ($i = 2 ; $i -le 14 ; $i += 3) {
            $randAddr = $randAddr.insert($i,$Delim)
        }
    }

    $validMac = Is-ValidMAC $randAddr
    if (-not $validMac) {
        return $false
    }

    return $randAddr
}

function Start-VMandGetIP {
    param (
        $VMName,
        $HvServer,
        $VMPort,
        $VMUserName,
        $VMPassword
    )
    $newIpv4 = $null

    Start-VM -Name $VMName -ComputerName $HvServer
    if (-not $?) {
        Write-LogErr "Error: Failed to start VM $VMName on $HvServer"
        return $False
    } else {
        Write-LogInfo "$VMName started on $HvServe"
    }

    # Wait for VM to boot
    $newIpv4 = Get-Ipv4AndWaitForSSHStart $VMName $HvServer $VMPort $VMUserName `
                $VMPassword 300
    if ($null -ne $newIpv4) {
        Write-LogInfo "$VMName IP address: $newIpv4"
        return $newIpv4
    } else {
        Write-LogErr "Error: Failed to get IP of $VMName on $HvServer"
        return $False
    }
}

# Generates an unused IP address based on an old IP address.
function Generate-IPv4{
    param (
        $TempIpv4,
        $OldIpv4
    )
    [int]$check = $null

    if ($OldIpv4 -eq $null){
        [int]$octet = 102
    } else {
        $oldIpPart = $OldIpv4.Split(".")
        [int]$octet  = $oldIpPart[3]
    }

    $ipPart = $TempIpv4.Split(".")
    $newAddress = ($ipPart[0]+"."+$ipPart[1]+"."+$ipPart[2])

    while ($check -ne 1 -and $octet -lt 255) {
        $octet = 1 + $octet
        if (!(Test-Connection "$newAddress.$octet" -Count 1 -Quiet)) {
            $splitIp = $newAddress + "." + $octet
            $check = 1
        }
    }

    return $splitIp.ToString()
}

# CIDR to netmask
function Convert-CIDRtoNetmask{
    param (
        [int]$CIDR
    )
    $mask = ""

    for ($i=0; $i -lt 32; $i+=1) {
        if($i -lt $CIDR){
            $ip+="1"
        }else{
            $ip+= "0"
        }
    }
    for ($byte=0; $byte -lt $ip.Length/8; $byte+=1) {
        $decimal = 0
        for ($bit=0;$bit -lt 8; $bit+=1) {
            $poz = $byte * 8 + $bit
            if ($ip[$poz] -eq "1") {
                $decimal += [math]::Pow(2, 8 - $bit -1)
            }
        }
        $mask +=[convert]::ToString($decimal)
        if ($byte -ne $ip.Length /8 -1) {
             $mask += "."
        }
    }
    return $mask
}

function Set-GuestInterface {
    param (
        $VMUser,
        $VMIpv4,
        $VMPort,
        $VMPassword,
        $InterfaceMAC,
        $VMStaticIP,
        $Bootproto,
        $Netmask,
        $VMName,
        $VlanID
    )

    Copy-RemoteFiles -upload -uploadTo $VMIpv4 -Port $VMPort `
        -files ".\Testscripts\Linux\utils.sh" -Username $VMUser -password $VMPassword
    if (-not $?) {
        Write-LogErr "Failed to send utils.sh to VM!"
        return $False
    }

    # Configure NIC on the guest
    Write-LogInfo "Configuring test interface ($InterfaceMAC) on $VMName ($VMIpv4)"
    # Get the interface name that corresponds to the MAC address
    $cmdToSend = "testInterface=`$(grep -il ${InterfaceMAC} /sys/class/net/*/address) ; basename `"`$(dirname `$testInterface)`""
    $testInterfaceName = Run-LinuxCmd -username $VMUser -password $VMPassword -ip $VMIpv4 -port $VMPort `
        -command $cmdToSend -runAsSudo
    if (-not $testInterfaceName) {
        Write-LogErr "Failed to get the interface name that has $InterfaceMAC MAC address"
        return $False
    } else {
        Write-LogInfo "The interface that will be configured on $VMName is $testInterfaceName"
    }
    $configFunction = "CreateIfupConfigFile"
    if ($VlanID) {
        $configFunction = "CreateVlanConfig"
    }

    # Configure the interface
    $cmdToSend = ". utils.sh; $configFunction $testInterfaceName $Bootproto $VMStaticIP $Netmask $VlanID"
    Run-LinuxCmd -username $VMUser -password $VMPassword -ip $VMIpv4 -port $VMPort -command $cmdToSend `
    -runAsSudo
    if (-not $?) {
        Write-LogErr "Failed to configure $testInterfaceName NIC on vm $VMName"
        return $False
    }
    Write-LogInfo "Sucessfuly configured $testInterfaceName on $VMName"
    return $True
}

function Test-GuestInterface {
    param (
        $VMUser,
        $AddressToPing,
        $VMIpv4,
        $VMPort,
        $VMPassword,
        $InterfaceMAC,
        $PingVersion,
        $PacketNumber,
        $Vlan
    )

    $nicPath = "/sys/class/net/*/address"
    if ($Vlan -eq "yes") {
        $nicPath = "/sys/class/net/*.*/address"
    }
    $cmdToSend = "testInterface=`$(grep -il ${InterfaceMAC} ${nicPath}) ; basename `"`$(dirname `$testInterface)`""
    $testInterfaceName = Run-LinuxCmd -username $VMUser -password $VMPassword -ip $VMIpv4 -port $VMPort `
        -command $cmdToSend -runAsSudo

    $cmdToSend = "$PingVersion -I $testInterfaceName $AddressToPing -c $PacketNumber -p `"cafed00d00766c616e0074616700`""
    $pingResult = Run-LinuxCmd -username $VMUser -password $VMPassword -ip $VMIpv4 -port $VMPort `
        -command $cmdToSend -ignoreLinuxExitCode:$true -runAsSudo

    if ($pingResult -notMatch "$PacketNumber received") {
        return $False
    }
    return $True
}

#Check if stress-ng is installed
Function Is-StressNgInstalled {
    param (
        [String] $VMIpv4,
        [String] $VMSSHPort
    )

    $cmdToVM = @"
#!/bin/bash
        command -v stress-ng
        sts=`$?
        exit `$sts
"@
    #"pingVMs: sending command to vm: $cmdToVM"
    $FILE_NAME  = "CheckStress-ng.sh"
    Set-Content $FILE_NAME "$cmdToVM"
    # send file
    Copy-RemoteFiles -uploadTo $VMIpv4 -port $VMSSHPort -files $FILE_NAME -username $user -password $password -upload
    # execute command
    $retVal = Run-LinuxCmd -username $user -password $password -ip $VMIpv4 -port $VMSSHPort `
        -command "echo $password | sudo -S cd /root && chmod u+x ${FILE_NAME} && sed -i 's/\r//g' ${FILE_NAME} && ./${FILE_NAME}"
    return $retVal
}

# function for starting stress-ng
Function Start-StressNg {
    param (
        [String] $VMIpv4,
        [String] $VMSSHPort
    )
    Write-LogInfo "IP is $VMIpv4"
    Write-LogInfo "port is $VMSSHPort"
      $cmdToVM = @"
#!/bin/bash
        __freeMem=`$(cat /proc/meminfo | grep -i MemFree | awk '{ print `$2 }')
        __freeMem=`$((__freeMem/1024))
        echo ConsumeMemory: Free Memory found `$__freeMem MB >> /root/HotAdd.log 2>&1
        __threads=32
        __chunks=`$((`$__freeMem / `$__threads))
        echo "Going to start `$__threads instance(s) of stress-ng every 2 seconds, each consuming 128MB memory" >> /root/HotAdd.log 2>&1
        stress-ng -m `$__threads --vm-bytes `${__chunks}M -t 120 --backoff 1500000
        echo "Waiting for jobs to finish" >> /root/HotAdd.log 2>&1
        wait
        exit 0
"@
    #"pingVMs: sending command to vm: $cmdToVM"
    $FILE_NAME = "ConsumeMem.sh"
    Set-Content $FILE_NAME "$cmdToVM"
    # send file
    Copy-RemoteFiles -uploadTo $VMIpv4 -port $VMSSHPort -files $FILE_NAME `
        -username $user -password $password -upload
    # execute command as job
    $retVal = Run-LinuxCmd -username $user -password $password -ip $VMIpv4 -port $VMSSHPort `
        -command "echo $password | sudo -S cd /root && chmod u+x ${FILE_NAME} && sed -i 's/\r//g' ${FILE_NAME} && ./${FILE_NAME}"
    return $retVal
}
# This function runs the remote script on VM.
# It checks the state of execution of remote script
Function Invoke-RemoteScriptAndCheckStateFile
{
    param (
        $remoteScript,
        $VMUser,
        $VMPassword,
        $VMIpv4,
        $VMPort
        )
    $stateFile = "${remoteScript}.state.txt"
    $Hypervcheck = "echo '${VMPassword}' | sudo -S -s eval `"export HOME=``pwd``;bash ${remoteScript} > ${remoteScript}.log`""
    Run-LinuxCmd -username $VMUser -password $VMPassword -ip $VMIpv4 -port $VMPort $Hypervcheck -runAsSudo
    Copy-RemoteFiles -download -downloadFrom $VMIpv4 -files "/home/${user}/state.txt" `
        -downloadTo $LogDir -port $VMPort -username $VMUser -password $password
    Copy-RemoteFiles -download -downloadFrom $VMIpv4 -files "/home/${user}/${remoteScript}.log" `
        -downloadTo $LogDir -port $VMPort -username $VMUser -password $VMPassword
    rename-item -path "${LogDir}\state.txt" -newname $stateFile
    $contents = Get-Content -Path $LogDir\$stateFile
    if (($contents -eq "TestAborted") -or ($contents -eq "TestFailed")) {
        return $False
    }
    return $True
}


#This function does hot add/remove of Max NICs
function Test-MaxNIC {
    param(
    $vmName,
    $hvServer,
    $switchName,
    $actionType,
    [int] $nicsAmount
    )
    for ($i=1; $i -le $nicsAmount; $i++)
    {
    $nicName = "External" + $i

    if ($actionType -eq "add")
    {
        Write-LogInfo "Ensure the VM does not have a Synthetic NIC with the name '${nicName}'"
        $null = Get-VMNetworkAdapter -vmName $vmName -Name "${nicName}" -ComputerName $hvServer -ErrorAction SilentlyContinue
        if ($?)
        {
        Write-LogErr "VM '${vmName}' already has a NIC named '${nicName}'"
        }
    }

    Write-LogInfo "Hot '${actionType}' a synthetic NIC with name of '${nicName}' using switch '${switchName}'"
    Write-LogInfo "Hot '${actionType}' '${switchName}' to '${vmName}'"
    if ($actionType -eq "add")
    {
        Add-VMNetworkAdapter -VMName $vmName -SwitchName $switchName -ComputerName $hvServer -Name ${nicName} #-ErrorAction SilentlyContinue
    }
    else
    {
        Remove-VMNetworkAdapter -VMName $vmName -Name "${nicName}" -ComputerName $hvServer -ErrorAction SilentlyContinue
    }
    if (-not $?)
    {
        Write-LogErr "Unable to Hot '${actionType}' NIC to VM '${vmName}' on server '${hvServer}'"
        }
    }
}

# This function is used for generating load using Stress NG tool
function Get-MemoryStressNG([String]$VMIpv4, [String]$VMSSHPort, [int]$timeoutStress, [int64]$memMB, [int]$duration, [int64]$chunk)
{
    Write-LogInfo "Get-MemoryStressNG started to generate memory load"
    $cmdToVM = @"
#!/bin/bash
        if [ ! -e /proc/meminfo ]; then
          echo "ConsumeMemory: no meminfo found. Make sure /proc is mounted" >> /root/HotAdd.log 2>&1
          exit 100
        fi

        rm ~/HotAddErrors.log -f
        __totalMem=`$(cat /proc/meminfo | grep -i MemTotal | awk '{ print `$2 }')
        __totalMem=`$((__totalMem/1024))
        echo "ConsumeMemory: Total Memory found `$__totalMem MB" >> /root/HotAdd.log 2>&1
        declare -i __chunks
        declare -i __threads
        declare -i duration
        declare -i timeout
        if [ $chunk -le 0 ]; then
            __chunks=128
        else
            __chunks=512
        fi
        __threads=`$(($memMB/__chunks))
        if [ $timeoutStress -eq 0 ]; then
            timeout=10000000
            duration=`$((10*__threads))
        elif [ $timeoutStress -eq 1 ]; then
            timeout=5000000
            duration=`$((5*__threads))
        elif [ $timeoutStress -eq 2 ]; then
            timeout=1000000
            duration=`$__threads
        else
            timeout=1
            duration=30
            __threads=4
            __chunks=2048
        fi

        if [ $duration -ne 0 ]; then
            duration=$duration
        fi
        echo "Stress-ng info: `$__threads threads :: `$__chunks MB chunk size :: `$((`$timeout/1000000)) seconds between chunks :: `$duration seconds total stress time" >> /root/HotAdd.log 2>&1
        stress-ng -m `$__threads --vm-bytes `${__chunks}M -t `$duration --backoff `$timeout
        echo "Waiting for jobs to finish" >> /root/HotAdd.log 2>&1
        wait
        exit 0
"@

    $FILE_NAME = "ConsumeMem.sh"
    Set-Content $FILE_NAME "$cmdToVM"
    # send file
    Copy-RemoteFiles -uploadTo $VMIpv4 -port $VMSSHPort -files $FILE_NAME -username $user -password $password -upload
    Write-LogInfo "Copy-RemoteFiles done"
    # execute command
    $sendCommand = "echo $password | sudo -S cd /root && chmod u+x ${FILE_NAME} && sed -i 's/\r//g' ${FILE_NAME} && ./${FILE_NAME}"
    $retVal = Run-LinuxCmd -username $user -password $password -ip $VMIpv4 -port $VMSSHPort -command $sendCommand  -runAsSudo
    return $retVal
}

# This function installs Stress NG/Stress APP
Function Publish-App([string]$appName, [string]$customIP, [string]$appGitURL, [string]$appGitTag,[String] $VMSSHPort)
{
    # check whether app is already installed
    if ($null -eq $appGitURL) {
        Write-LogInfo "ERROR: $appGitURL is not set"
        return $False
    }
    $retVal = Run-LinuxCmd -username $user -password $password -ip $customIP -port $VMSSHPort `
        -command "echo $password | sudo -S cd /root; git clone $appGitURL $appName > /dev/null 2>&1"
    if ($appGitTag) {
        $retVal = Run-LinuxCmd -username $user -password $password -ip $customIP -port $VMSSHPort `
        -command "cd $appName; git checkout tags/$appGitTag > /dev/null 2>&1"
    }
    if ($appName -eq "stress-ng") {
        $appInstall = "cd $appName; echo '${password}' | sudo -S make install"
        $retVal = Run-LinuxCmd -username $user -password $password -ip $customIP -port $VMSSHPort `
             -command $appInstall
    }
    else {
    $appInstall = "cd $appName;./configure;make;echo '${password}' | sudo -S make install"
    $retVal = Run-LinuxCmd -username $user -password $password -ip $customIP -port $VMSSHPort `
        -command $appInstall
    }
    Write-LogInfo "App $appName Installation is completed"
    return $retVal
}

#######################################################################
# Fix snapshots. If there are more than one remove all except latest.
#######################################################################
function Restore-LatestVMSnapshot($vmName, $hvServer)
{
    # Get all the snapshots
    $vmsnapshots = Get-VMSnapshot -VMName $vmName -ComputerName $hvServer
    $snapnumber = ${vmsnapshots}.count
    # Get latest snapshot
    $latestsnapshot = Get-VMSnapshot -VMName $vmName -ComputerName $hvServer | Sort-Object CreationTime | Select-Object -Last 1
    $LastestSnapName = $latestsnapshot.name
    # Delete all snapshots except the latest
    if (1 -lt $snapnumber) {
        Write-LogInfo "$vmName has $snapnumber snapshots. Removing all except $LastestSnapName"
        foreach ($snap in $vmsnapshots) {
            if ($snap.id -ne $latestsnapshot.id) {
                $snapName = ${snap}.Name
                $sts = Remove-VMSnapshot -Name $snap.Name -VMName $vmName -ComputerName $hvServer
                if (-not $?) {
                    Write-LogErr "Unable to remove snapshot $snapName of ${vmName}: `n${sts}"
                    return $False
                }
                Write-LogInfo "Removed snapshot $snapName"
            }
        }
    }
    # If there are no snapshots, create one.
    ElseIf (0 -eq $snapnumber) {
        Write-LogInfo "There are no snapshots for $vmName. Creating one ..."
        $sts = Checkpoint-VM -VMName $vmName -ComputerName $hvServer
        if (-not $?) {
           Write-LogErr "Unable to create snapshot of ${vmName}: `n${sts}"
           return $False
        }
    }
    return $True
}

function Enable-RootUser {
    <#
    .DESCRIPTION
    Sets a new password for the root user for all VMs in deployment.
    #>

    param(
        $VMData,
        [string]$RootPassword,
        [string]$Username,
        [string]$Password
    )

    $deploymentResult = $True

    foreach ($VM in $VMData) {
        Copy-RemoteFiles -upload -uploadTo $VM.PublicIP -Port $VM.SSHPort `
             -files ".\Testscripts\Linux\utils.sh,.\Testscripts\Linux\enableRoot.sh" -Username $Username -password $Password
        $cmdResult = Run-LinuxCmd -Command "bash enableRoot.sh -password ${RootPassword}" -runAsSudo `
             -Username $Username -password $Password -ip $VM.PublicIP -Port $VM.SSHPort
        if (-not $cmdResult) {
            Write-LogInfo "Fail to enable root user for VM: $($VM.RoleName)"
        }
        $deploymentResult = $deploymentResult -and $cmdResult
    }

    return $deploymentResult
}