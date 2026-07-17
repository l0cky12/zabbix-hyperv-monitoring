# NOMMA Hyper-V Fleet Dashboard

Import `dashboard_hyperv_fleet_nomma.yaml` from **Monitoring -> Dashboards -> Import** in Zabbix 7.4.

The dashboard is a fleet-level problem view. It uses the `component` trigger tags emitted by `Template Hyper-V Standalone Replica by NOMMA`:

- `component: hyper-v` for host collection, VMMS, VM state, heartbeat, and checkpoint problems.
- `component: replication` for Hyper-V Replica health, state, and lag problems.

It does not bind widgets to specific hosts, so it automatically includes every host that produces those tagged problems. Import the Hyper-V template and link it to each Hyper-V host before relying on this dashboard.
