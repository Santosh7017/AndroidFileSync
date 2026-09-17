#!/usr/bin/python3
"""Controlled DNS-SD output; never accesses Bonjour or the network."""
import json
from pathlib import Path
import sys
import time

state = json.loads((Path(__file__).parent / "state.json").read_text())
services = state.get("dnsServices", [])
args = sys.argv[1:]
with (Path(__file__).parent / "dns-commands.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
for service in services:
    if args[0] == "-B" and args[1] == service["type"]:
        print(f'00:00:00 Add 2 1 local. {service["type"]}. {service["name"]}', flush=True)
    elif args[0] == "-L" and args[1] == service["name"] and args[2] == service["type"]:
        print(f'{service["name"]} can be reached at {service["host"]}:{service["port"]}', flush=True)
    elif args[0] == "-G" and args[2] == service["host"]:
        print(f'00:00:00 Add 2 1 {service["host"]}', flush=True)
time.sleep(60)
