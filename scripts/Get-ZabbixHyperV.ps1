#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()][string]$FixturePath,
    [Parameter()][switch]$Pretty
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-PropertyValue {
    param([Parameter(Mandatory=$true)]$Object,[Parameter(Mandatory=$true)][string[]]$Names,$Default=$null)
    foreach ($name in $Names) {
        if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$name]) { return $Object.$name }
    }
    return $Default
}

function ConvertTo-EpochSeconds {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [int64]0 }
    try {
        $dto = [DateTimeOffset]::new(([datetime]$Value).ToUniversalTime())
        return [int64]$dto.ToUnixTimeSeconds()
    } catch { return [int64]0 }
}

function ConvertTo-IntegerSeconds {
    param($Value,[int64]$Default=0)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    if ($Value -is [timespan]) { return [int64][math]::Floor($Value.TotalSeconds) }
    try { return [int64]$Value } catch { return $Default }
}

function Get-StateCode {
    param([string]$State)
    $map = @{
        'Other'=1; 'Running'=2; 'Off'=3; 'Stopping'=4; 'Saved'=6; 'Paused'=9; 'Starting'=10;
        'Reset'=11; 'Saving'=12; 'Pausing'=13; 'Resuming'=14; 'FastSaved'=15; 'FastSaving'=16;
        'ForceShutdown'=17; 'ForceReboot'=18; 'Hibernated'=19; 'ComponentServicing'=20;
        'RunningCritical'=101; 'OffCritical'=102; 'StoppingCritical'=103; 'SavedCritical'=104;
        'PausedCritical'=105; 'StartingCritical'=106; 'ResetCritical'=107; 'SavingCritical'=108;
        'PausingCritical'=109; 'ResumingCritical'=110; 'FastSavedCritical'=111; 'FastSavingCritical'=112
    }
    if ($map.ContainsKey($State)) { return [int]$map[$State] }
    return [int]0
}

function Get-HeartbeatCode {
    param([string]$VmState,[string]$Heartbeat,$Enabled)
    if ($VmState -notin @('Running','RunningCritical')) { return 4 } # powered off/non-running
    if ($null -ne $Enabled -and -not [bool]$Enabled) { return 3 }
    if ([string]::IsNullOrWhiteSpace($Heartbeat)) { return 3 }
    if ($Heartbeat -match '^(Ok|OK)' -or $Heartbeat -match '^OperatingNormally$') { return 1 }
    if ($Heartbeat -match 'NoContact|No Contact|LostCommunication|Lost Communication|Error') { return 2 }
    return 0
}

function New-FailureDocument {
    param([string]$Message,[int]$ModuleAvailable=0,[int]$RoleAvailable=0,[int]$VmmsRunning=0)
    return [ordered]@{
        schemaVersion = 1
        collectedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        collection = [ordered]@{ ok=0; error=$Message; moduleAvailable=$ModuleAvailable; roleAvailable=$RoleAvailable }
        host = [ordered]@{ vmmsRunning=$VmmsRunning; vmTotal=0; vmRunning=0; vmOff=0; vmPaused=0; vmSaved=0; vmAbnormal=0; replicaPrimary=0; replicaReplica=0; replicaUnhealthy=0 }
        vms = @()
        replicas = @()
    }
}

function Convert-SourceData {
    param([Parameter(Mandatory=$true)]$Source)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $vmRows = @()
    foreach ($vm in @($Source.vms)) {
        $vmId = ([guid](Get-PropertyValue $vm @('Id','VMId'))).ToString('D').ToLowerInvariant()
        $state = [string](Get-PropertyValue $vm @('State') 'Other')
        $uptimeRaw = Get-PropertyValue $vm @('UptimeSeconds','Uptime') 0
        $uptime = ConvertTo-IntegerSeconds $uptimeRaw 0
        $heartbeat = [string](Get-PropertyValue $vm @('Heartbeat') '')
        $heartbeatEnabledRaw = Get-PropertyValue $vm @('HeartbeatEnabled') $null

        $snapshots = @(Get-PropertyValue $vm @('Snapshots','Checkpoints') @())
        $monitorSnapshots = @($snapshots | Where-Object { [string](Get-PropertyValue $_ @('SnapshotType') 'Standard') -notin @('Recovery','Replica','AppConsistentReplica','SyncedReplica','Planned') })
        $oldestEpoch = [int64]0
        $types = @()
        foreach ($snapshot in $monitorSnapshots) {
            $epoch = ConvertTo-EpochSeconds (Get-PropertyValue $snapshot @('CreationTime'))
            if ($epoch -gt 0 -and ($oldestEpoch -eq 0 -or $epoch -lt $oldestEpoch)) { $oldestEpoch = $epoch }
            $types += [string](Get-PropertyValue $snapshot @('SnapshotType') 'Unknown')
        }
        $oldestAge = if ($oldestEpoch -gt 0) { [math]::Max([int64]0,$now-$oldestEpoch) } else { [int64]0 }
        $vmRows += [ordered]@{
            vmId=$vmId; vmName=[string](Get-PropertyValue $vm @('Name','VMName') ''); state=$state;
            stateCode=(Get-StateCode $state); uptimeSeconds=$uptime;
            heartbeat=[string]$heartbeat; heartbeatCode=(Get-HeartbeatCode $state $heartbeat $heartbeatEnabledRaw);
            heartbeatEnabled=if ($null -eq $heartbeatEnabledRaw) { -1 } elseif ([bool]$heartbeatEnabledRaw) { 1 } else { 0 };
            checkpointCount=[int]$monitorSnapshots.Count; checkpointExists=if ($monitorSnapshots.Count -gt 0) { 1 } else { 0 }; checkpointOldestAgeSeconds=$oldestAge;
            checkpointTypes=[string](($types | Sort-Object -Unique) -join ',')
        }
    }

    $replicaRows = @()
    foreach ($rep in @($Source.replicas)) {
        $vmId = ([guid](Get-PropertyValue $rep @('VMId','Id'))).ToString('D').ToLowerInvariant()
        $mode = [string](Get-PropertyValue $rep @('ReplicationMode','Mode') 'None')
        $relationship = [string](Get-PropertyValue $rep @('ReplicationRelationshipType','Relationship') 'Simple')
        $state = [string](Get-PropertyValue $rep @('ReplicationState','State') 'Disabled')
        $health = [string](Get-PropertyValue $rep @('ReplicationHealth','Health') 'NotApplicable')
        $lastEpoch = ConvertTo-EpochSeconds (Get-PropertyValue $rep @('LastReplicationTime'))
        $lag = if ($lastEpoch -gt 0) { [math]::Max([int64]0,$now-$lastEpoch) } else { [int64]0 }
        $stateSeverity = if ($state -in @('Replicating','PreparedForFailover','FailedOver','FailbackComplete','PreparedForSyncReplication','PreparedForGroupReverseReplication')) { 0 } elseif ($state -in @('ReadyForInitialReplication','InitialReplicationInProgress','WaitingForInitialReplication','Resynchronizing','RecoveryInProgress','FailbackInProgress','WaitingForUpdateCompletion','WaitingForRepurposeCompletion','FiredrillInProgress','FailedOverWaitingCompletion','WaitingForStartResynchronize')) { 1 } elseif ($state -in @('Suspended','ResynchronizeSuspended','Disabled')) { 2 } else { 3 }
        $healthCode = switch ($health) { 'Normal' {1}; 'Warning' {2}; 'Critical' {3}; default {0} }
        $detail = Get-PropertyValue $rep @('ReplicationHealthDetails','HealthDetails') @()
        if ($detail -isnot [System.Collections.IEnumerable] -or $detail -is [string]) { $detail = @([string]$detail) }
        $replicaRows += [ordered]@{
            replicaId=('{0}|{1}|{2}' -f $vmId,$mode.ToLowerInvariant(),$relationship.ToLowerInvariant());
            vmId=$vmId; vmName=[string](Get-PropertyValue $rep @('VMName','Name') ''); role=$mode.ToLowerInvariant();
            relationship=$relationship; state=$state; stateSeverity=[int]$stateSeverity; health=$health; healthCode=[int]$healthCode;
            frequencySeconds=[int](ConvertTo-IntegerSeconds (Get-PropertyValue $rep @('ReplicationFrequencySec','FrequencySec') 0) 0);
            lastReplicationEpoch=$lastEpoch; lagSeconds=$lag;
            replicationErrors=[int](Get-PropertyValue $rep @('ReplicationErrors','ReplicationFailureCount') 0);
            missedReplications=[int](Get-PropertyValue $rep @('MissedReplicationCount','ReplicationMissCount') 0);
            pendingBytes=[int64](Get-PropertyValue $rep @('PendingReplicationSize') 0);
            averageLatencySeconds=[int64](Get-PropertyValue $rep @('AverageReplicationLatency','ReplicationLatency') 0);
            healthDetails=[string](@($detail) -join '; ')
        }
    }
    $states = @($vmRows | ForEach-Object { $_.state })
    return [ordered]@{
        schemaVersion=1; collectedAt=$now;
        collection=[ordered]@{ ok=1; error=''; moduleAvailable=1; roleAvailable=1 }
        host=[ordered]@{
            vmmsRunning=[int](Get-PropertyValue $Source.host @('VmmsRunning') 1);
            vmTotal=[int]$vmRows.Count; vmRunning=[int]@($states | Where-Object { $_ -in @('Running','RunningCritical') }).Count;
            vmOff=[int]@($states | Where-Object { $_ -in @('Off','OffCritical') }).Count;
            vmPaused=[int]@($states | Where-Object { $_ -in @('Paused','PausedCritical') }).Count;
            vmSaved=[int]@($states | Where-Object { $_ -in @('Saved','FastSaved','SavedCritical','FastSavedCritical') }).Count;
            vmAbnormal=[int]@($states | Where-Object { $_ -eq 'Other' -or $_ -match 'Critical$' }).Count;
            replicaPrimary=[int]@($replicaRows | Where-Object { $_.role -eq 'primary' }).Count;
            replicaReplica=[int]@($replicaRows | Where-Object { $_.role -in @('replica','extendedreplica') }).Count;
            replicaUnhealthy=[int]@($replicaRows | Where-Object { $_.health -in @('Warning','Critical') -or $_.stateSeverity -ge 2 }).Count
        }
        vms=$vmRows; replicas=$replicaRows
    }
}

$document = $null
try {
    if ($FixturePath) {
        if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) { throw "Fixture not found: $FixturePath" }
        $source = Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $source.PSObject.Properties['fixtureFailure']) {
            $failure = $source.fixtureFailure
            $document = New-FailureDocument ([string](Get-PropertyValue $failure @('message') 'Fixture collection failure.')) ([int](Get-PropertyValue $failure @('moduleAvailable') 0)) ([int](Get-PropertyValue $failure @('roleAvailable') 0)) ([int](Get-PropertyValue $failure @('vmmsRunning') 0))
        } else {
            $document = Convert-SourceData $source
        }
    } else {
        if (-not (Get-Module -ListAvailable -Name Hyper-V)) { $document = New-FailureDocument 'Hyper-V PowerShell module is unavailable.' 0 0 0 }
        else {
            Import-Module Hyper-V -ErrorAction Stop
            $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
            if ($null -eq $vmms) { $document = New-FailureDocument 'VMMS service is unavailable; Hyper-V role is not installed or accessible.' 1 0 0 }
            elseif ($vmms.Status -ne 'Running') { $document = New-FailureDocument ("VMMS service is {0}." -f $vmms.Status) 1 1 0 }
            else {
                $vms = @(Get-VM -ErrorAction Stop)
                $integrations = @()
                if ($vms.Count -gt 0) { $integrations = @($vms | Get-VMIntegrationService -ErrorAction Stop) }
                $snapshots = @()
                if ($vms.Count -gt 0) { $snapshots = @($vms | Get-VMSnapshot -ErrorAction Stop) }
                $vmSource = foreach ($vm in $vms) {
                    $vmId = ([guid]$vm.Id).ToString('D').ToLowerInvariant()
                    # Heartbeat integration component GUID is stable; Name is a localized display string.
                    $hb = @($integrations | Where-Object { ([string]$_.VMId).ToLowerInvariant() -eq $vmId -and ([string]$_.Id -match '(?i)84eaae65-2f2e-45f5-9bb5-0e857dc8eb47$') }) | Select-Object -First 1
                    [pscustomobject]@{
                        Id=$vm.Id; Name=$vm.Name; State=[string]$vm.State; UptimeSeconds=[int64][math]::Floor($vm.Uptime.TotalSeconds);
                        Heartbeat=[string]$vm.Heartbeat; HeartbeatEnabled=if ($null -eq $hb) { $null } else { [bool]$hb.Enabled };
                        Snapshots=@($snapshots | Where-Object { ([string]$_.VMId).ToLowerInvariant() -eq $vmId } | ForEach-Object { [pscustomobject]@{ CreationTime=$_.CreationTime; SnapshotType=[string]$_.SnapshotType } })
                    }
                }
                $repSettings = @(Get-VMReplication -ErrorAction Stop)
                $repStats = @(Measure-VMReplication -ErrorAction Stop)
                $repSource = foreach ($rep in $repSettings) {
                    $vmId = ([guid](Get-PropertyValue $rep @('VMId','Id'))).ToString('D').ToLowerInvariant()
                    $rel = [string](Get-PropertyValue $rep @('ReplicationRelationshipType','Relationship') 'Simple')
                    $stats = @($repStats | Where-Object { ([string](Get-PropertyValue $_ @('VMId','Id') '')).ToLowerInvariant() -eq $vmId -and [string](Get-PropertyValue $_ @('ReplicationRelationshipType','Relationship') 'Simple') -eq $rel }) | Select-Object -First 1
                    [pscustomobject]@{
                        VMId=$vmId; VMName=[string](Get-PropertyValue $rep @('VMName','Name') ''); ReplicationMode=[string](Get-PropertyValue $rep @('ReplicationMode','Mode') 'None');
                        ReplicationRelationshipType=$rel; ReplicationState=[string](Get-PropertyValue $rep @('ReplicationState','State') 'Disabled');
                        ReplicationHealth=[string](Get-PropertyValue $rep @('ReplicationHealth','Health') 'NotApplicable');
                        ReplicationFrequencySec=[int](ConvertTo-IntegerSeconds (Get-PropertyValue $rep @('ReplicationFrequencySec','FrequencySec') 0) 0);
                        LastReplicationTime=Get-PropertyValue $rep @('LastReplicationTime') (Get-PropertyValue $stats @('LastReplicationTime'));
                        ReplicationHealthDetails=Get-PropertyValue $stats @('ReplicationHealthDetails') @();
                        ReplicationErrors=[int](Get-PropertyValue $stats @('ReplicationErrors','ReplicationFailureCount') 0);
                        MissedReplicationCount=[int](Get-PropertyValue $stats @('MissedReplicationCount','ReplicationMissCount') 0);
                        PendingReplicationSize=[int64](Get-PropertyValue $stats @('PendingReplicationSize') 0);
                        AverageReplicationLatency=[int64](Get-PropertyValue $stats @('AverageReplicationLatency','ReplicationLatency') 0)
                    }
                }
                $source = [pscustomobject]@{ host=[pscustomobject]@{ VmmsRunning=1 }; vms=@($vmSource); replicas=@($repSource) }
                $document = Convert-SourceData $source
            }
        }
    }
} catch {
    $moduleAvailable = if (Get-Module -ListAvailable -Name Hyper-V) { 1 } else { 0 }
    $document = New-FailureDocument (($_.Exception.Message -replace '[\r\n]+',' ').Trim()) $moduleAvailable 0 0
}

if ($Pretty) { $document | ConvertTo-Json -Depth 8 }
else { $document | ConvertTo-Json -Depth 8 -Compress }
exit 0
