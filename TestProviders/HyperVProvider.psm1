##############################################################################################
# HyperVProvider.psm1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# Operations :
#
<#
.SYNOPSIS
	PS modules for LISAv2 test automation
	This module provides the test operations on HyperV

.PARAMETER
	<Parameters>

.INPUTS


.NOTES
	Creation Date:
	Purpose/Change:

.EXAMPLE


#>
###############################################################################################
using Module ".\TestProvider.psm1"

Class HyperVProvider : TestProvider
{
	[string] $VMGeneration

	[object] DeployVMs([xml] $GlobalConfig, [object] $SetupTypeData, [object] $TestCaseData, [string] $TestLocation) {
		$allVMData = @()
		try {
			$isAllDeployed = Create-AllHyperVGroupDeployments -SetupTypeData $SetupTypeData -GlobalConfig $GlobalConfig -TestLocation $TestLocation `
				-Distro $global:RGIdentifier -VMGeneration $this.VMGeneration -TestCaseData $TestCaseData
			if($isAllDeployed[0] -eq "True")
			{
				$DeployedHyperVGroup = $isAllDeployed[1]
				$DeploymentElapsedTime = $isAllDeployed[3]
				$allVMData = Get-AllHyperVDeployementData -HyperVGroupNames $DeployedHyperVGroup -GlobalConfig $GlobalConfig
				if (!$allVMData) {
					Write-LogErr "One or more deployments failed..!"
				} else {
					$isVmAlive = Is-VmAlive -AllVMDataObject $allVMData
					if ($isVmAlive -eq "True") {
						Inject-HostnamesInHyperVVMs -allVMData $allVMData
						$this.RestartAllDeployments($allVMData)

						if ( Test-Path -Path  .\Extras\UploadDeploymentDataToDB.ps1 )
						{
							.\Extras\UploadDeploymentDataToDB.ps1 -allVMData $allVMData -DeploymentTime $DeploymentElapsedTime.TotalSeconds
						}

						$customStatus = Set-CustomConfigInVMs -CustomKernel $this.CustomKernel -CustomLIS $this.CustomLIS `
							-AllVMData $allVMData -TestProvider $this
						if (!$customStatus) {
							Write-LogErr "Failed to set custom config in VMs, abort the test"
							return $null
						}

						# Create the initial checkpoint
						Create-HyperVCheckpoint -VMData $AllVMData -CheckpointName "ICAbase"
						$allVMData = Check-IP -VMData $AllVMData
					}
					else
					{
						Write-LogErr "Unable to connect SSH ports.."
					}
				}
				if ($SetupTypeData.ClusteredVM) {
					foreach ($VM in $allVMData) {
						Remove-VMGroupMember -Name $VM.HyperVGroupName -VM $(Get-VM -name $VM.RoleName -ComputerName $VM.HyperVHost)
					}
				}
			}
			else
			{
				Write-LogErr "One or More Deployments are Failed..!"
			}
		}
		catch
		{
			Write-LogErr "Exception detected. Source : DeployVMs()"
			$line = $_.InvocationInfo.ScriptLineNumber
			$script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
			$ErrorMessage =  $_.Exception.Message
			Write-LogErr "EXCEPTION : $ErrorMessage"
			Write-LogErr "Source : Line $line in script $script_name."
		}
		return $allVMData
	}

	[void] RunSetup($VmData, $CurrentTestData, $TestParameters) {
		if ($CurrentTestData.AdditionalHWConfig.HyperVApplyCheckpoint -eq "False") {
			Remove-AllFilesFromHomeDirectory -allDeployedVMs $VmData
			Write-LogInfo "Removed all files from home directory."
		} else  {
			Apply-HyperVCheckpoint -VMData $VmData -CheckpointName "ICAbase"
			$VmData = Check-IP -VMData $VmData
			Write-LogInfo "Public IP found for all VMs in deployment after checkpoint restore"
		}

		if ($CurrentTestData.SetupScript) {
			if ($null -eq $CurrentTestData.runSetupScriptOnlyOnce) {
				foreach ($VM in $VmData) {
					if (Get-VM -Name $VM.RoleName -ComputerName $VM.HyperVHost -EA SilentlyContinue) {
						Stop-VM -Name $VM.RoleName -TurnOff -Force -ComputerName $VM.HyperVHost
					}
					foreach ($script in $($CurrentTestData.SetupScript).Split(",")) {
						$null = Run-SetupScript -Script $script -Parameters $TestParameters -VMData $VM -CurrentTestData $CurrentTestData
					}
					if (Get-VM -Name $VM.RoleName -ComputerName $VM.HyperVHost -EA SilentlyContinue) {
						Start-VM -Name $VM.RoleName -ComputerName $VM.HyperVHost
					}
				}
			}
			else {
				foreach ($script in $($CurrentTestData.SetupScript).Split(",")) {
					$null = Run-SetupScript -Script $script -Parameters $TestParameters -VMData $VmData -CurrentTestData $CurrentTestData
				}
			}
		}
	}

	[void] RunTestCaseCleanup ($AllVMData, $CurrentTestData, $CurrentTestResult, $CollectVMLogs, $RemoveFiles, $User, $Password, $SetupTypeData, $TestParameters){
		try
		{
			if ($CurrentTestData.CleanupScript) {
				foreach ($VM in $AllVMData) {
					if (Get-VM -Name $VM.RoleName -ComputerName `
						$VM.HyperVHost -EA SilentlyContinue) {
						Stop-VM -Name $VM.RoleName -TurnOff -Force -ComputerName `
							$VM.HyperVHost
					}
					foreach ($script in $($CurrentTestData.CleanupScript).Split(",")) {
						$null = Run-SetupScript -Script $script -Parameters $TestParameters -VMData $VM -CurrentTestData $CurrentTestData
					}
					if (Get-VM -Name $VM.RoleName -ComputerName $VM.HyperVHost `
						-EA SilentlyContinue) {
						Start-VM -Name $VM.RoleName -ComputerName `
							$VM.HyperVHost
					}
				}
			}

			if ($SetupTypeData.ClusteredVM) {
				foreach ($VM in $AllVMData) {
					Add-VMGroupMember -Name $VM.HyperVGroupName -VM (Get-VM -name $VM.RoleName -ComputerName $VM.HyperVHost) `
						-ComputerName $VM.HyperVHost
				}
			}

			([TestProvider]$this).RunTestCaseCleanup($AllVMData, $CurrentTestData, $CurrentTestResult, $CollectVMLogs, $RemoveFiles, $User, $Password, $SetupTypeData)

			if ($CurrentTestResult.TestResult -ne "PASS") {
				Create-HyperVCheckpoint -VMData $AllVMData -CheckpointName "$($CurrentTestData.TestName)-$($CurrentTestResult.TestResult)" `
					-ShouldTurnOffVMBeforeCheckpoint $false -ShouldTurnOnVMAfterCheckpoint $false
			}
		}
		catch
		{
			$ErrorMessage =  $_.Exception.Message
			Write-Output "EXCEPTION in RunTestCaseCleanup : $ErrorMessage"
		}
	}

	[void] DeleteTestVMs($allVMData, $SetupTypeData) {
		foreach ($vmData in $AllVMData) {
			$isCleaned = Delete-HyperVGroup -HyperVGroupName $vmData.HyperVGroupName -HyperVHost $vmData.HyperVHost -SetupTypeData $SetupTypeData
			if (Get-Variable 'DependencyVmHost' -Scope 'Global' -EA 'Ig') {
				if ($global:DependencyVmHost -ne $vmData.HyperVHost) {
					Delete-HyperVGroup -HyperVGroupName $vmData.HyperVGroupName -HyperVHost $global:DependencyVmHost
				}
			}
			if (!$isCleaned)
			{
				Write-LogInfo "Failed to delete HyperV group $($vmData.HyperVGroupName).. Please delete it manually."
			}
			else
			{
				Write-LogInfo "Successfully delete HyperV group $($vmData.HyperVGroupName).."
			}
		}
	}

	[bool] RestartAllDeployments($allVMData) {
		foreach ( $VM in $allVMData )
		{
			Stop-HyperVGroupVMs -HyperVGroupName $VM.HyperVGroupName -HyperVHost $VM.HyperVHost
		}
		foreach ( $VM in $allVMData )
		{
			Start-HyperVGroupVMs -HyperVGroupName $VM.HyperVGroupName -HyperVHost $VM.HyperVHost
		}
		if ((Is-VmAlive -AllVMDataObject $AllVMData) -eq "True") {
			return $true
		}
		return $false
	}
}