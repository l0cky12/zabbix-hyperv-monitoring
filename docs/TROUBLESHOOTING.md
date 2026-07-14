# Troubleshooting

## `hyperv.collect` is unsupported

1. Run `zabbix_agent2.exe -t hyperv.collect` locally.
2. Confirm the include file is under a path matched by `Include=`.
3. Confirm the configured absolute script path exists and is quoted.
4. Check `zabbix_agent2.log` for UserParameter timeout, access denied, or PowerShell policy messages.
5. Ensure `Timeout` is at least 10 seconds; large hosts may need 30 seconds. Do not set an excessive global timeout without measuring collector duration.

## JSON says module or role unavailable

```powershell
Get-Module -ListAvailable Hyper-V
Get-WindowsFeature Hyper-V,Hyper-V-PowerShell
Get-Service vmms
Import-Module Hyper-V
Get-VM
```

Install the Hyper-V management tools if the module is absent. The monitoring package never installs or changes the role.

## Access denied

Run the exact collector as the Zabbix service account. Add that service identity only to the host-local **Hyper-V Administrators** group if required, then restart the Zabbix service to rebuild its token. Do not use Domain Admin.

## Collection reports failure but zero VMs is expected

A healthy zero-VM host has `collection.ok=1`, `host.vmTotal=0`, and empty arrays. Any `collection.ok=0` is a real collection failure; inspect `hyperv.collection.error`.

## VMs or replica relationships are missing

```powershell
Get-VM | Select Id,Name
Get-VMReplication | Select VMId,VMName,ReplicationMode,ReplicationRelationshipType,ReplicationState,ReplicationHealth,ReplicationFrequencySec,LastReplicationTime
Measure-VMReplication | Format-List *
```

Confirm the master JSON contains the GUID under `vms[].vmId` or a relationship under `replicas[].replicaId`. Check preprocessing test results in Zabbix. LLD lost-resource lifetime is 7 days and disabled lifetime is 1 day.

## Heartbeat false alarms

Check `Get-VM -Id <GUID> | Select State,Heartbeat` and its heartbeat integration component. The collector identifies the component using GUID `84eaae65-2f2e-45f5-9bb5-0e857dc8eb47`, not the localized display name. Alerts require state `Running` and persistent heartbeat code 2.

## Replica lag alerts

Compare reported last time and configured frequency. Threshold is `2 * frequency + lag macro`, giving tolerance for normal scheduling. During initial replication/resynchronization, state severity can produce a separate persistent warning; tune macros based on RPO.

## Static validation versus real import

`tests/validate_template.py` checks YAML, UUID uniqueness/format, key uniqueness, dependencies, JSONPath shape, trigger template references, macros, and value maps. It is not the Zabbix server importer. If import fails, preserve the exact frontend/API error and compare against the installed 7.4 minor release export schema.
