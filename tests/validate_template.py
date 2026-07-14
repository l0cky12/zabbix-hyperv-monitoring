#!/usr/bin/env python3
import json,re,sys,uuid,yaml
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'template/template_hyperv_standalone_replica_nomma.yaml'
data=yaml.safe_load(p.read_text(encoding='utf-8'))
assert data['zabbix_export']['version']=='7.4'
t=data['zabbix_export']['templates'][0]
assert t['template']=='Template Hyper-V Standalone Replica by NOMMA'
objs=[]
def walk(x):
 if isinstance(x,dict):
  if 'uuid' in x: objs.append(x)
  for v in x.values(): walk(v)
 elif isinstance(x,list):
  for v in x: walk(v)
walk(data)
uids=[o['uuid'] for o in objs]
assert len(uids)==len(set(uids)), 'duplicate UUIDs'
assert all(re.fullmatch(r'[0-9a-f]{32}',x) for x in uids), 'bad UUID'
keys=[]
for i in t.get('items',[]): keys.append(i['key'])
for d in t.get('discovery_rules',[]):
 keys.append(d['key'])
 for i in d.get('item_prototypes',[]): keys.append(i['key'])
assert len(keys)==len(set(keys)), 'duplicate item/rule key'
masters=set(i['key'] for i in t['items'])
for d in t['discovery_rules']:
 assert d['type']=='DEPENDENT' and d['master_item']['key'] in masters
 assert any(m['lld_macro']=='{#VMID}' for m in d['lld_macro_paths'])
 for i in d['item_prototypes']:
  assert i['type']=='DEPENDENT' and i['master_item']['key']=='hyperv.collect'
  assert '{#' in i['key'], i['key']
  for step in i.get('preprocessing',[]):
   assert step['type'] in {'JSONPATH','DISCARD_UNCHANGED_HEARTBEAT'}
   if step['type']=='JSONPATH': assert step['parameters'][0].startswith('$')
expr=[]
def exwalk(x):
 if isinstance(x,dict):
  if 'expression'in x: expr.append(x['expression'])
  for v in x.values(): exwalk(v)
 elif isinstance(x,list):
  for v in x: exwalk(v)
exwalk(t)
for e in expr:
 assert '/Template Hyper-V Standalone Replica by NOMMA/' in e
assert all(m['macro'].startswith('{$HYPERV.') for m in t['macros'])
valuemaps={v['name'] for v in t['valuemaps']}
def check_vm(x):
 if isinstance(x,dict):
  if 'valuemap' in x: assert x['valuemap']['name'] in valuemaps
  for v in x.values(): check_vm(v)
 elif isinstance(x,list):
  for v in x: check_vm(v)
check_vm(t)
print(f'Static template validation: PASS ({len(uids)} UUIDs, {len(keys)} unique keys, {len(expr)} trigger expressions)')
