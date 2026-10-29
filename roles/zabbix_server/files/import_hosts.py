#!/usr/bin/env python3
"""Create the server-network hosts in Zabbix. Existing names are left as they are."""
import json
import os
import urllib.request

token = os.environ["ZABBIX_TOKEN"]
hosts = json.loads(os.environ["ZABBIX_HOSTS"])
url = "http://127.0.0.1/api_jsonrpc.php"


def call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    with urllib.request.urlopen(request) as response:
        data = json.load(response)
    if "error" in data:
        raise SystemExit(f"{method}: {data['error']}")
    return data["result"]


groups = call("hostgroup.get", {"filter": {"name": ["Rusagricom"]}, "output": ["groupid"]})
if groups:
    groupid = groups[0]["groupid"]
else:
    groupid = call("hostgroup.create", {"name": "Rusagricom"})["groupids"][0]

templates = call("template.get", {"filter": {"host": ["ICMP Ping"]}, "output": ["templateid"]})
icmp_id = templates[0]["templateid"] if templates else None

for item in hosts:
    existing = call("host.get", {"filter": {"host": [item["name"]]}, "output": ["hostid"]})
    if existing:
        continue
    params = {
        "host": item["name"],
        "interfaces": [
            {
                "type": 1,
                "main": 1,
                "useip": 1,
                "ip": item["address"],
                "dns": "",
                "port": "10050",
            }
        ],
        "groups": [{"groupid": groupid}],
    }
    if icmp_id:
        params["templates"] = [{"templateid": icmp_id}]
    call("host.create", params)
