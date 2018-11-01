# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Synopsis
	Verify that a VM with low memory pressure looses memory when another
	VM has a high memory demand. 3 VMs are required for this test.
	
	The testParams have the format of:
	vmName=Name of a VM, enable=[yes|no], minMem= (decimal) [MB|GB|%],
	maxMem=(decimal) [MB|GB|%], startupMem=(decimal) [MB|GB|%],
	memWeight=(0 < decimal < 100)

	Tries=(decimal): This controls the number of times the script tries
	to start the second VM. If not set, a default value of 3 is set. This
	is necessary because Hyper-V usually removes memory from a VM only when
	a second one applies pressure. However, the second VM can fail to start
	while memory is removed from the first. There is a 30 second timeout
	between tries, so 3 tries is a conservative value.

	Example of testParam to configure Dynamic Memory:
	"Tries=3;vmName=sles11x64sp3;enable=yes;minMem=512MB;maxMem=80%;
	startupMem=80%;memWeight=0;vmName=sles11x64sp3_2;enable=yes;
	minMem=512MB;maxMem=25%;startupMem=25%;memWeight=0"

.Parameter testParams
	Test data for this test case
#>

Param([String] $TestParams)

$ErrorActionPreference = "Stop"
$testResult = "FAIL"

# This function installs stress-ng
Function Install-StressNg([string]$IP, [String]$port)
{
	$ret = RunLinuxCmd -username $user -password $password -ip $IP -port $port -command "git clone https://github.com/ColinIanKing/stress-ng > /dev/null 2>&1" -runAsSudo
	$ret = RunLinuxCmd -username $user -password $password -ip $IP -port $port -command "cd stress-ng; git checkout tags/V0.07.16 > /dev/null 2>&1" -runAsSudo
	$ret = RunLinuxCmd -username $user -password $password -ip $IP -port $port -command "cd stress-ng; make install" -runAsSudo
	LogMsg "stress-ng install done"
}

Function Configure-VmMemory
{
	param ($VM, $minMem, $maxMem, $startupMem, $memWeight)

	$minMem = Convert-ToMemSize $minMem $VM.HyperVHost
	$maxMem = Convert-ToMemSize $maxMem $VM.HyperVHost
	$startupMem = Convert-ToMemSize $startupMem $VM.HyperVHost
	#$memWeight = [Convert]::ToInt32($memWeight)

	Set-VMMemory -vmName $VM.RoleName -ComputerName $VM.HyperVHost -DynamicMemoryEnabled $true -MinimumBytes $minMem -MaximumBytes $maxMem -StartupBytes $startupMem -Priority $memWeight

	# check if mem is set correctly
	$vmMem = (Get-VMMemory -vmName $VM.RoleName -ComputerName $VM.HyperVHost).Startup
	if( $vmMem -eq $startupMem ) {
		LogMsg "Set VM Startup Memory for $VM.RoleName to $startupMem. Success."
	} else {
		LogErr "Unable to set VM Startup Memory for $VM.RoleName to $startupMem"
		return $false
	}
}

Function Main
{
	param ($VM1, $VM2, $VM3)
	$resultArr = @()
	$tPs = Parse-TestParameters -XMLParams $CurrentTestData.TestParameters -XMLConfig $xmlConfig

	Configure-VmMemory -VM $VM1 -minMem $tPs.minMem1 -maxMem $tPs.maxMem1 -startupMem $tPs.startupMem1 -memWeight $tPs.memWeight1
	Configure-VmMemory -VM $VM2 -minMem $tPs.minMem2 -maxMem $tPs.maxMem2 -startupMem $tPs.startupMem2 -memWeight $tPs.memWeight2
	Configure-VmMemory -VM $VM3 -minMem $tPs.minMem3 -maxMem $tPs.maxMem3 -startupMem $tPs.startupMem3 -memWeight $tPs.memWeight3

	# number of tries, default 3 if not specified.
	[int]$tries = 3
	if ($null -ne $tPs.tries) {
		$tries = $tPs.tries
	}

	# determine which is vm2 and whih is vm3 based on memory weight
	$vm2MemWeight = (Get-VMMemory -vmName $VM2.RoleName -ComputerName $VM2.HyperVHost).Priority
	if (-not $?) {
		LogErr "Unable to get $VM2.RoleName memory weight."
    		return $false
	}

	$vm3MemWeight = (Get-VMMemory -vmName $VM3.RoleName -ComputerName $VM3.HyperVHost).Priority
	if (-not $?) {
		LogErr "Unable to get $VM3.RoleName memory weight."
    		return $false
	}

	if ($vm3MemWeight -eq $vm2MemWeight) {
		LogErr "$VM3.RoleName must have a higher memory weight than $VM2.RoleName"
		return $false
	}

	if ($vm3MemWeight -lt $vm2MemWeight) {
		# switch vm2 with vm3
		$aux = $VM2.RoleName
		$VM2.RoleName = $VM3.RoleName
		$VM3.RoleName = $aux

		$VM2 = Get-VM -Name $VM2.RoleName -ComputerName $VM2.HyperVHost -ErrorAction SilentlyContinue
		if (-not $VM2) {
			LogErr "VM $VM2.RoleName does not exist anymore"
			return $false
		}

		$VM3 = Get-VM -Name $VM3.RoleName -ComputerName $VM3.HyperVHost -ErrorAction SilentlyContinue
		if (-not $VM3) {
			LogErr "VM $VM3.RoleName does not exist anymore"
			return $false
		}
	}

	# Install stress-ng
	Start-VM -Name $VM1.RoleName -ComputerName $VM1.HyperVHost
	Install-StressNg($VM1.PublicIP, $VM1.SSHPort)

	# LIS Started VM1, so start VM2
	$timeout = 120
	StartDependencyVM $VM2.RoleName $VM2.HyperVHost $tries
	WaitForVMToStartKVP $VM2.RoleName $VM2.HyperVHost $timeout
	$vm2ipv4 = GetIPv4 $VM2.RoleName $VM2.HyperVHost

	$timeoutStress = 1
	$sleepPeriod = 120 #seconds
	# get VM1 and VM2's Memory
	while ($sleepPeriod -gt 0) {
		[int64]$vm1BeforeAssigned = ($vm1.MemoryAssigned/[int64]1048576)
		[int64]$vm1BeforeDemand = ($vm1.MemoryDemand/[int64]1048576)
		[int64]$vm2BeforeAssigned = ($vm2.MemoryAssigned/[int64]1048576)
		[int64]$vm2BeforeDemand = ($vm2.MemoryDemand/[int64]1048576)
	
		if ($vm1BeforeAssigned -gt 0 -and $vm1BeforeDemand -gt 0 -and $vm2BeforeAssigned -gt 0 -and $vm2BeforeDemand -gt 0) {
			break
		}	
		$sleepPeriod-= 5
		Start-Sleep -s 5
	}

	if ($vm1BeforeAssigned -le 0 -or $vm1BeforeDemand -le 0) {
		LogErr "vm1 or vm2 reported 0 memory (assigned or demand)."
		Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
		return $False
	}

	LogMsg "Memory stats after both $VM1.RoleName and $VM2.RoleName started reporting:"
	LogMsg "${VM1.RoleName}: assigned - $vm1BeforeAssigned | demand - $vm1BeforeDemand"
	LogMsg "${VM2.RoleName}: assigned - $vm2BeforeAssigned | demand - $vm2BeforeDemand"

	# Install stress-ng
	Start-VM -Name $VM2.RoleName -ComputerName $VM2.HyperVHost
	Install-StressNg($VM2.PublicIP, $VM2.SSHPort)

	# Calculate the amount of memory to be consumed on VM1 and VM2 with stress-ng
	[int64]$vm1ConsumeMem = (Get-VMMemory -VM $vm1).Maximum
	[int64]$vm2ConsumeMem = (Get-VMMemory -VM $vm2).Maximum
	# only consume 75% of max memory
	$vm1ConsumeMem = ($vm1ConsumeMem / 4) * 3
	$vm2ConsumeMem = ($vm2ConsumeMem / 4) * 3
	# transform to MB
	$vm1ConsumeMem /= 1MB
	$vm2ConsumeMem /= 1MB

	# standard chunks passed to stress-ng
	[int64]$chunks = 512 #MB
	[int]$vm1Duration = 400 #seconds
	[int]$vm2Duration = 380 #seconds

	# Send Command to consume
	$job1 = Start-Job -ScriptBlock { param($ip, $sshKey, $rootDir, $timeoutStress, $vm1ConsumeMem, $vm1Duration, $chunks) ConsumeMemory $ip $sshKey $rootDir $timeoutStress $vm1ConsumeMem $vm1Duration $chunks } -InitializationScript $DM_scriptBlock -ArgumentList($ipv4,$sshKey,$rootDir,$timeoutStress,$vm1ConsumeMem,$vm1Duration,$chunks)
	if (-not $?) {
		LogErr "Unable to start job for creating pressure on $VM1.RoleName"
		Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
		return $false
	}	

	$job2 = Start-Job -ScriptBlock { param($ip, $sshKey, $rootDir, $timeoutStress, $vm2ConsumeMem, $vm2Duration, $chunks) ConsumeMemory $ip $sshKey $rootDir $timeoutStress $vm2ConsumeMem $vm2Duration $chunks } -InitializationScript $DM_scriptBlock -ArgumentList($vm2ipv4,$sshKey,$rootDir,$timeoutStress,$vm2ConsumeMem,$vm2Duration,$chunks)
	if (-not $?) {
		LogErr "Unable to start job for creating pressure on $VM2.RoleName"
		Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
		return $false
	}	

	# sleep a few seconds so all stress-ng processes start and the memory assigned/demand gets updated
	Start-Sleep -s 240
	# get memory stats for vm1 and vm2 just before vm3 starts
	[int64]$vm1Assigned = ($vm1.MemoryAssigned/[int64]1048576)
	[int64]$vm1Demand = ($vm1.MemoryDemand/[int64]1048576)
	[int64]$vm2Assigned = ($vm2.MemoryAssigned/[int64]1048576)
	[int64]$vm2Demand = ($vm2.MemoryDemand/[int64]1048576)

	LogMsg "Memory stats after $VM1.RoleName and $VM2.RoleName started stress-ng, but before $VM3.RoleName starts: "
	LogMsg "${VM1.RoleName}: assigned - $vm1Assigned | demand - $vm1Demand"
	LogMsg "${VM2.RoleName}: assigned - $vm2Assigned | demand - $vm2Demand"

	# Try to start VM3
	$timeout = 120
	StartDependencyVM $VM3.RoleName $VM3.HyperVHost $tries
	WaitForVMToStartKVP $VM3.RoleName $VM3.HyperVHost $timeout

	Start-sleep -s 60
	# get memory stats after vm3 started
	[int64]$vm1AfterAssigned = ($vm1.MemoryAssigned/[int64]1048576)
	[int64]$vm1AfterDemand = ($vm1.MemoryDemand/[int64]1048576)
	[int64]$vm2AfterAssigned = ($vm2.MemoryAssigned/[int64]1048576)
	[int64]$vm2AfterDemand = ($vm2.MemoryDemand/[int64]1048576)

	LogMsg "Memory stats after $VM1.RoleName and $VM2.RoleName started stress-ng and after $VM3.RoleName started: "
	LogMsg "${VM1.RoleName}: assigned - $vm1AfterAssigned | demand - $vm1AfterDemand"
	LogMsg "${VM2.RoleName}: assigned - $vm2AfterAssigned | demand - $vm2AfterDemand"

	# Wait for jobs to finish now and make sure they exited successfully
	$totalTimeout = $timeout = 120
	$timeout = 0
	$firstJobState = $false
	$secondJobState = $false
	$min = 0
	while ($true) {
		if ($job1.State -like "Completed" -and -not $firstJobState) {
			$firstJobState = $true
			$retVal = Receive-Job $job1
			if (-not $retVal[-1]) {
				LogErr "Consume Memory script returned false on VM1 $VM1.RoleName"
				Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
				Stop-VM -VMName $VM3.RoleName -ComputerName $VM3.HyperVHost -force
				return $false
			}
		LogMsg "Job1 finished in $min minutes."
		}
		if ($job2.State -like "Completed" -and -not $secondJobState) {
			$secondJobState = $true
			$retVal = Receive-Job $job2
			if (-not $retVal[-1]) {
				LogErr "Consume Memory script returned false on VM2 $VM2.RoleName"
				Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
				Stop-VM -VMName $VM3.RoleName -ComputerName $VM3.HyperVHost -force
				return $falses
			}
		$diff = $totalTimeout - $timeout
		LogMsg "Job2 finished in $min minutes."
		}
		if ($firstJobState -and $secondJobState) {
			break
		}
		if ($timeout%60 -eq 0) {
			LogMsg "$min minutes passed"
			$min += 1
		}
		if ($totalTimeout -le 0) {
			break
		}
		$timeout += 5
		$totalTimeout -= 5
		Start-Sleep -s 5
	}

	[int64]$vm1DeltaAssigned = [int64]$vm1Assigned - [int64]$vm1AfterAssigned
	[int64]$vm1DeltaDemand = [int64]$vm1Demand - [int64]$vm1AfterDemand
	[int64]$vm2DeltaAssigned = [int64]$vm2Assigned - [int64]$vm2AfterAssigned
	[int64]$vm2DeltaDemand = [int64]$vm2Demand - [int64]$vm2AfterDemand
	LogMsg "Deltas for $VM1.RoleName and $VM2.RoleName after $VM3.RoleName started:"
	LogMsg "${VM1.RoleName}: deltaAssigned - $vm1DeltaAssigned | deltaDemand - $vm1DeltaDemand"
	LogMsg "${VM2.RoleName}: deltaAssigned - $vm2DeltaAssigned | deltaDemand - $vm2DeltaDemand"

	# check that at least one of the first two VMs has lower assigned memory as a result of VM3 starting
	if ($vm1DeltaAssigned -le 0 -and $vm2DeltaAssigned -le 0) {
		LogErr "Error: Neither $VM1.RoleName, nor $VM2.RoleName didn't lower their assigned memory in response to $VM3.RoleName starting"
		Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
		Stop-VM -VMName $VM3.RoleName -ComputerName $VM3.HyperVHost -force
		return $false
	}

	[int64]$vm1EndAssigned = ($vm1.MemoryAssigned/[int64]1048576)
	[int64]$vm1EndDemand = ($vm1.MemoryDemand/[int64]1048576)
	[int64]$vm2EndAssigned = ($vm2.MemoryAssigned/[int64]1048576)
	[int64]$vm2EndDemand = ($vm2.MemoryDemand/[int64]1048576)

	$sleepPeriod = 120 #seconds
	# get VM3's Memory
	while ($sleepPeriod -gt 0) {
		[int64]$vm3EndAssigned = ($vm3.MemoryAssigned/[int64]1048576)
		[int64]$vm3EndDemand = ($vm3.MemoryDemand/[int64]1048576)
		if ($vm3EndAssigned -gt 0 -and $vm3EndDemand -gt 0) {
			break
		}
		$sleepPeriod -= 5
		Start-Sleep -s 5
	}

	if ($vm1EndAssigned -le 0 -or $vm1EndDemand -le 0 -or $vm2EndAssigned -le 0 -or $vm2EndDemand -le 0 -or $vm3EndAssigned -le 0 -or $vm3EndDemand -le 0) {
		LogErr "One of the VMs reports 0 memory (assigned or demand) after vm3 $VM3.RoleName started" | Tee-Object -Append -file $summaryLog
		Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
		Stop-VM -VMName $VM3.RoleName -ComputerName $VM3.HyperVHost -force
		return $false
	}	

	# stop vm2 and vm3
	Stop-VM -VMName $VM2.RoleName -ComputerName $VM2.HyperVHost -force
	Stop-VM -VMName $VM3.RoleName -ComputerName $VM3.HyperVHost -force

	# Verify if errors occured on guest
	$isAlive = WaitForVMToStartKVP $VM1.RoleName $VM1.HyperVHost 10
	if (-not $isAlive) {
		LogErr "VM is unresponsive after running the memory stress test"
		return $false
	}	

	$errorsOnGuest = echo y | bin\plink -i ssh\${sshKey} root@$ipv4 "cat HotAddErrors.log"
	if (-not  [string]::IsNullOrEmpty($errorsOnGuest)) {
		$errorsOnGuest
		return $false
	}

	# Everything ok
	LogMsg "Success: Memory was removed from a low priority VM with minimal memory pressure to a VM with high memory pressure!"
	return $true
} # End main

Main -VM1 $allVMData[0] -VM2 $allVMData[1] -VM3 $allVMData[2]
