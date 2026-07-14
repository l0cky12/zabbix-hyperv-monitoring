#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$collector = Join-Path $root 'scripts\Get-ZabbixHyperV.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\mixed.json'
$zero = Join-Path $PSScriptRoot 'fixtures\zero-vms.json'
function Invoke-Collector([string]$Path) {
    $raw = & $collector -FixturePath $Path
    if ($LASTEXITCODE -ne 0) { throw "Collector exit code $LASTEXITCODE" }
    return $raw | ConvertFrom-Json
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
$x=Invoke-Collector $fixture
Assert ($x.collection.ok -eq 1) 'mixed fixture collection succeeds'
Assert ($x.host.vmTotal -eq 5) 'multiple VMs counted'
Assert ($x.host.vmRunning -eq 2 -and $x.host.vmOff -eq 1 -and $x.host.vmPaused -eq 1 -and $x.host.vmSaved -eq 1) 'state counts'
Assert ($x.vms.Count -eq 5) 'all VMs discovered'
$special=@($x.vms|Where-Object vmId -eq '22222222-2222-2222-2222-222222222222')[0]
Assert ($special.vmName -match 'quoted') 'quotes/backslash/unicode survive JSON serialization'
Assert ($special.heartbeatCode -eq 4) 'off VM suppresses heartbeat failure'
Assert ($special.checkpointCount -eq 2) 'replica checkpoint excluded from user checkpoint count'
Assert ($special.checkpointExists -eq 1) 'checkpoint existence flag is set'
Assert ($special.checkpointOldestAgeSeconds -gt 0) 'oldest checkpoint age calculated'
$hb=@($x.vms|Where-Object vmId -eq '44444444-4444-4444-4444-444444444444')[0]
Assert ($hb.heartbeatCode -eq 2) 'running heartbeat failure detected'
Assert ($x.host.replicaPrimary -eq 2 -and $x.host.replicaReplica -eq 1) 'mixed replica roles counted'
Assert ($x.host.replicaUnhealthy -eq 2) 'warning and critical relationships counted'
Assert (@($x.replicas|Where-Object health -eq 'Normal').Count -eq 1) 'healthy replication retained'
Assert (@($x.replicas|Where-Object state -eq 'Suspended').Count -eq 1) 'suspended replication retained'
Assert (@($x.replicas|Where-Object state -eq 'Error').Count -eq 1) 'error replication retained'
$z=Invoke-Collector $zero
Assert ($z.collection.ok -eq 1 -and $z.host.vmTotal -eq 0 -and $z.vms.Count -eq 0) 'zero VMs is healthy empty result'
$f=Invoke-Collector (Join-Path $PSScriptRoot 'fixtures\missing.json')
Assert ($f.collection.ok -eq 0 -and $f.vms.Count -eq 0 -and $f.collection.error.Length -gt 0) 'failure is distinct from healthy empty result'
$moduleFailure=Invoke-Collector (Join-Path $PSScriptRoot 'fixtures\module-missing.json')
Assert ($moduleFailure.collection.ok -eq 0 -and $moduleFailure.collection.moduleAvailable -eq 0) 'missing Hyper-V module is controlled failure'
$vmmsFailure=Invoke-Collector (Join-Path $PSScriptRoot 'fixtures\vmms-stopped.json')
Assert ($vmmsFailure.collection.ok -eq 0 -and $vmmsFailure.collection.moduleAvailable -eq 1 -and $vmmsFailure.host.vmmsRunning -eq 0) 'VMMS stopped is controlled failure'
$genericFailure=Invoke-Collector (Join-Path $PSScriptRoot 'fixtures\collection-error.json')
Assert ($genericFailure.collection.ok -eq 0 -and $genericFailure.collection.error -match 'Synthetic') 'PowerShell collection error is controlled failure'
'PowerShell fixture tests: PASS (31 requested scenarios covered; 23 executable assertions)'
