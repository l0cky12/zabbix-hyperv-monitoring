# Zabbix Hyper-V Standalone Replica Monitoring

Production-oriented Zabbix 7.4 monitoring for standalone Windows Server 2019, 2022, and 2025 Hyper-V hosts and direct host-to-host Hyper-V Replica.

**Out of scope:** Failover Clustering, Hyper-V clusters, CSV, HA, SCVMM, and cluster cmdlets.

## Architecture

One local read-only PowerShell collector runs per host through a UserParameter. A single `ZABBIX_ACTIVE` master item returns compressed JSON; all host metrics, two LLD rules, VM prototypes, and replica prototypes are dependent objects. This avoids one PowerShell process per VM/metric. No WinRM or domain administrator account is required.

Zabbix Agent 2 is preferred because it is the current extensible agent and has improved plugin/process management. The solution uses only standard UserParameter behavior, so classic Zabbix Agent is compatible. Use the correct install path and include directory for that agent. Do not install both services with the same hostname.

## Files

- `template/template_hyperv_standalone_replica_nomma.yaml` - importable Zabbix 7.4 template.
- `scripts/Get-ZabbixHyperV.ps1` - Windows PowerShell 5.1-compatible collector.
- `agent/userparameter_hyperv.conf` - Agent 2/classic Agent UserParameter.
- `tests/Test-Collector.ps1` and `tests/fixtures/` - safe mocked tests.
- `tests/validate_template.py` - static YAML/template consistency checks.
- `docs/TROUBLESHOOTING.md` - diagnostics.

## Prerequisites and permissions

1. Zabbix server/proxy 7.4 and Zabbix Agent 2 (preferred) or classic Agent on each Hyper-V host.
2. Windows Server 2019/2022/2025 with Hyper-V and Hyper-V PowerShell management tools.
3. Windows PowerShell 5.1. PowerShell 7 is not required.
4. The agent service identity must be able to query Hyper-V. The practical least-privilege assignment is membership in the host-local **Hyper-V Administrators** group. Do not use Domain Admin.
5. If changing a service account's group membership, restart the Zabbix agent service so its logon token is rebuilt.

For Local System, test first: Hyper-V cmdlets commonly work locally, but security policy varies. If denied, use a dedicated local/domain service account in local `Hyper-V Administrators`, grant `Log on as a service`, configure the Zabbix service to use it, and restart. The scripts never change permissions.

## Install on one test host first

**This changes the agent configuration. Test on one Hyper-V host before bulk deployment.**

Run elevated PowerShell:

```powershell
$install = 'C:\Program Files\Zabbix Agent 2'
New-Item -ItemType Directory -Force "$install\scripts" | Out-Null
Copy-Item .\scripts\Get-ZabbixHyperV.ps1 "$install\scripts\Get-ZabbixHyperV.ps1" -Force
Copy-Item .\agent\userparameter_hyperv.conf "$install\zabbix_agent2.d\plugins.d\userparameter_hyperv.conf" -Force

# If files were downloaded, unblock only these reviewed files. Do not weaken system-wide execution policy.
Unblock-File "$install\scripts\Get-ZabbixHyperV.ps1"
Unblock-File "$install\zabbix_agent2.d\plugins.d\userparameter_hyperv.conf"

Restart-Service 'Zabbix Agent 2'
```

Classic Agent: put the script under its install directory, change the absolute path in the UserParameter file, copy the file into the directory matched by `Include=`, then restart `Zabbix Agent`.

The invocation deliberately uses `-NoLogo -NoProfile -NonInteractive` and does **not** use `-ExecutionPolicy Bypass`. Follow your organization’s execution policy; sign the script if `AllSigned` is required.

Rollback: remove `userparameter_hyperv.conf` and `Get-ZabbixHyperV.ps1`, then restart the agent.

## Manual tests

Run as the agent service identity when possible:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File 'C:\Program Files\Zabbix Agent 2\scripts\Get-ZabbixHyperV.ps1' -Pretty
& 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe' -t hyperv.collect
Get-VM | Select-Object Id,Name,State,Uptime,Heartbeat
Get-VM | Get-VMIntegrationService | Select-Object Id,VMId,Enabled,PrimaryOperationalStatus,SecondaryOperationalStatus
Get-VM | Get-VMSnapshot | Select-Object Id,VMId,Name,CreationTime,SnapshotType
Get-VMReplication | Format-List *
Measure-VMReplication | Format-List *
```

Successful JSON has `"collection":{"ok":1,...}` even when `vms` and `replicas` are empty. Controlled failure has `ok:0`, a non-empty `error`, and empty arrays; therefore failure never masquerades as a healthy zero-VM host.

Example (shortened):

```json
{"schemaVersion":1,"collection":{"ok":1,"error":"","moduleAvailable":1,"roleAvailable":1},"host":{"vmmsRunning":1,"vmTotal":1},"vms":[{"vmId":"...","vmName":"VM 01","state":"Running","heartbeatCode":1}],"replicas":[]}
```

Safe mocked tests (do not alter VMs):

```powershell
pwsh -NoProfile -File .\tests\Test-Collector.ps1
```

## Import and link

1. Zabbix: **Data collection -> Templates -> Import**.
2. Import `template/template_hyperv_standalone_replica_nomma.yaml`.
3. Link **Template Hyper-V Standalone Replica by NOMMA** to each Hyper-V host.
4. The host must have an active-agent interface/identity matching the agent `Hostname` and server/proxy `ServerActive` configuration.
5. Master collection starts at the configured 1-minute interval. Dependent VM and Replica discovery is processed from the same payload, normally within one to two collection cycles.

If your policy requires passive checks, change the master item type from `ZABBIX_ACTIVE` to the passive Zabbix agent type after import; the UserParameter itself supports either. Active is the shipped default because it scales cleanly and avoids inbound agent polling.

## Macro defaults

| Macro | Default | Unit/purpose |
|---|---:|---|
| `{$HYPERV.COLLECT.INTERVAL}` | `1m` | Master polling interval |
| `{$HYPERV.COLLECT.NODATA}` | `5m` | No-data alert duration |
| `{$HYPERV.HOST.PROBLEM.TIME}` | `3m` | Host condition persistence |
| `{$HYPERV.VM.STOPPED.WARN}` | `15m` | Off-state persistence before Warning |
| `{$HYPERV.VM.HEARTBEAT.TIME}` | `3m` | Heartbeat failure persistence while Running |
| `{$HYPERV.VM.UPTIME.MIN}` | `10m` | Restart event threshold after uptime decreases |
| `{$HYPERV.CHECKPOINT.COUNT.WARN}` | `2` | Maximum checkpoint count |
| `{$HYPERV.CHECKPOINT.AGE.WARN}` | `7d` | Maximum checkpoint age |
| `{$HYPERV.REPLICA.WARNING.TIME}` | `10m` | Warning health/state persistence |
| `{$HYPERV.REPLICA.CRITICAL.TIME}` | `5m` | Critical health/state persistence |
| `{$HYPERV.REPLICA.LAG.WARN}` | `10m` | Added warning tolerance after 2 x relationship frequency |
| `{$HYPERV.REPLICA.LAG.CRIT}` | `30m` | Added critical tolerance after 2 x relationship frequency |

Use host-level/context overrides when an intentionally stopped VM should not alert. A common pattern is to override `{$HYPERV.VM.STOPPED.WARN}` on hosts with different operational expectations.

## Trigger design

- **Information:** restart detected by uptime decrease; checkpoint exists only when neither count nor age threshold is exceeded.
- **Warning/Average:** VM off too long; too many/old checkpoints; replication warning/suspended; host abnormal count.
- **High:** collection unavailable/failed, VMMS stopped, running-VM heartbeat failure, replication critical/error, critical lag.
- Lag Warning and High are mutually exclusive. Checkpoint information/count/age expressions are mutually exclusive to limit duplicate events.
- Heartbeat is classified as non-alerting for non-running VMs.
- State/health persistence avoids immediate alerts for normal transitions.

## Collection details and limitations

- VM LLD key: stable `VM.Id`; names, spaces, quotes, backslashes, and Unicode are JSON-serialized by `ConvertTo-Json`.
- Heartbeat: the stable integration-component GUID identifies whether the heartbeat component is enabled; `Get-VM.Heartbeat` provides status. Non-running VMs map to a suppressed state.
- Uptime: `Get-VM.Uptime.TotalSeconds`. Restart trigger requires a sample-to-sample decrease, so it does not remain active for the full threshold and does not fire merely because a newly discovered VM has low uptime.
- Checkpoints: `Get-VMSnapshot`; replica/recovery/planned artifacts are excluded from user-checkpoint alerts. Hyper-V does not reliably expose whether a `Standard` snapshot object came from Production versus Standard checkpoint policy, so the template reports snapshot type without claiming checkpoint intent.
- Replica: `Get-VMReplication` plus `Measure-VMReplication`; relationship ID combines VM GUID, local replication mode, and relationship type. A mixed primary/replica host is supported.
- Last replication age is based on reported `LastReplicationTime`; `0` means unavailable and lag triggers require a nonzero timestamp.
- `ReplicationHealthDetails` may be localized text. Alert logic uses normalized state/health, not that text.
- Collector catches all errors and returns controlled JSON with process exit 0 because Zabbix must receive the failure document. The `collection.ok` trigger is the failure signal.
- Live execution was not tested on a Windows Hyper-V host in this build environment; use the one-host test before rollout.
