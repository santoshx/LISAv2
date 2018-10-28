# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Synopsis
	Sample test to demo usage of two VMs for DM tests
.Description
	Sample test to demo usage of two VMs for DM tests
.Parameter testParams
	Test data for this test case
#>

Param([String] $TestParams)

$ErrorActionPreference = "Stop"
$testResult = "FAIL"

Function Main
{
	param ($VM1, $VM2, $VM3)
	$resultArr = @()

	try {
		LogMsg "VM1 = $VM1"
		LogMsg "VM2 = $VM2"
		LogMsg "VM3 = $VM3"

		$testResult = "PASS"

	} catch {
		$testResult = "FAIL"
		$ErrorMessage =  $_.Exception.Message
		$ErrorLine = $_.InvocationInfo.ScriptLineNumber
		LogErr "$ErrorMessage at line: $ErrorLine"

	} finally {
		$resultArr += $testResult
	}

	return GetFinalResultHeader -resultarr $resultArr
} # end Main

Main -VM1 $allVMData[0] -VM2 $allVMData[1] -VM3 $allVMData[2]
