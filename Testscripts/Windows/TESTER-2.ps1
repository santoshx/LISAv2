# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Synopsis
	Tester-2
.Parameter testParams
#>

Param([String] $TestParams)

$ErrorActionPreference = "Stop"
$testResult = "FAIL"

Function Main
{
	param ($VM1, $VM2, $VM3)
	$resultArr = @()
	$tPs = Parse-TestParameters -XMLParams $CurrentTestData.TestParameters -XMLConfig $xmlConfig
	LogMsg "tester-2"
	LogMsg "params recived $tps"
	return $true
} # End main

Main -VM1 $allVMData[0] -VM2 $allVMData[1] -VM3 $allVMData[2]
