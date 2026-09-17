#!/usr/bin/python3
"""ADB fixture: never opens a phone connection or starts a real ADB daemon."""
import fcntl
import json
import os
from pathlib import Path
import shlex
import sys
import time

root = Path(__file__).parent
args = sys.argv[1:]
port = int(os.environ.get("ANDROID_ADB_SERVER_PORT", "5037"))
serial = None
while args and args[0] in ("-P", "-s"):
    option, value = args[:2]
    args = args[2:]
    if option == "-P":
        port = int(value)
    else:
        serial = value
command = args[0] if args else ""

with (root / "state.json").open("r+") as file:
    fcntl.flock(file, fcntl.LOCK_EX)
    state = json.load(file)
    with (root / "commands.jsonl").open("a") as log:
        entry = {"command": command, "args": args, "serial": serial, "port": port}
        if command == "shell":
            entry["shellWords"] = shlex.split(" ".join(args[1:]))
        log.write(json.dumps(entry) + "\n")
    target = args[1] if len(args) > 1 else ""
    output = ""
    error = ""
    code = 0
    delay = 0
    complete_start = False
    devices = state.setdefault("devices", {}).setdefault(str(port), {})
    running = state.get("runningServers", {}).get(str(port), True)
    if not running and command not in ("start-server", "kill-server"):
        code = 1
        error = "protocol fault (couldn't read status message): startup raced"
    elif command == "devices":
        delay = state.get("deviceDelays", {}).get(str(port), 0)
        output = "List of devices attached\n" + "\n".join(
            f"{key}\t{value} model:Fixture_Phone transport_id:1" for key, value in devices.items()
        ) + "\n"
        if state.get("pairDaemonFault"):
            output = ""
            code = 1
            error = "protocol fault (couldn't read status message): daemon unavailable"
    elif command == "mdns":
        output = "List of discovered mdns services\n" + "\n".join(state.get("services", [])) + "\n"
    elif command == "pair":
        delay = state.get("pairDelay", 0)
        pair_error = state.get("pairErrorsByTarget", {}).get(target) or state.get("pairError")
        failure_reason = state.get("pairFailureReasonsByTarget", {}).get(target) or state.get("pairFailureReason")
        if state.get("pairSocketError"):
            with (root / f"adb.{os.getuid()}.log").open("a") as daemon_log:
                daemon_log.write("E adb : pairing_client.cpp:133 Failed to start pairing connection client "
                                 f"[failed to connect to '{target}': {state['pairSocketError']}]\n")
        if "--fixture-response-reader" in args and state.get("pairResponseSuccess"):
            output = "Successfully paired to " + target
        elif "--fixture-response-reader" in args and failure_reason:
            code = 1
            error = failure_reason
        elif pair_error or state.get("pairDaemonFault"):
            code = 1
            error = pair_error or "error: protocol fault (couldn't read status message): Undefined error: 0"
        elif state.get("pairingCodes", {}).get(target) == (args[2] if len(args) > 2 else None):
            output = "Successfully paired to " + target
        else:
            code = 1
            error = "Failed: Wrong password or connection was dropped."
    elif command == "connect":
        delay = state.get("delays", {}).get(target, 0)
        if target in state.get("servicesAfterConnect", {}):
            state["services"] = state["servicesAfterConnect"][target]
        if state.get("daemonFault"):
            error = "protocol fault (couldn't read status message)"
            code = 1
        elif state.get("transientFailures", {}).get(target, 0):
            state["transientFailures"][target] -= 1
            error = state.get("transientError", "failed to connect: connection refused")
            code = 1
        elif target in state.get("live", {}):
            devices[target] = "device"
            output = "connected to " + target
        elif target in state.get("stale", []):
            output = "already connected to " + target
        else:
            error = state.get("connectError", "failed to connect: connection refused")
            code = 1
    elif command == "disconnect":
        devices.pop(target, None)
        if target in state.get("stale", []):
            state["stale"].remove(target)
            state.setdefault("live", {})[target] = "PHONE-A"
        output = "disconnected " + target
    elif command == "shell":
        identity = state.get("live", {}).get(serial)
        text = " ".join(args[1:])
        if not identity:
            code = 1
            error = "device offline"
        elif any(text.startswith(prefix) for prefix in state.get("shellResponses", {})):
            response = next(value for prefix, value in state["shellResponses"].items() if text.startswith(prefix))
            code = response.get("code", 0)
            output = response.get("output", "")
            error = response.get("error", "")
        elif "afs-connected" in text:
            delays = state.get("verificationDelays", {}).get(serial, [])
            if delays:
                delay = delays.pop(0)
            output = "afs-connected\n" + identity + "\n" + identity + "\n"
        elif "getprop" in text:
            output = identity + "\n" + identity + "\n"
        elif "echo ok" in text:
            output = "ok\n"
    elif command == "wait-for-disconnect":
        delay = 0 if serial in state.get("disconnectedSerials", []) else 60
    elif command == "kill-server":
        devices.clear()
        state.setdefault("runningServers", {})[str(port)] = False
    elif command == "start-server":
        state["daemonFault"] = False
        state["pairDaemonFault"] = False
        if state.setdefault("startingServers", {}).get(str(port)):
            code = 1
            error = "adb server didn't ACK: another startup is in progress"
        else:
            state["startingServers"][str(port)] = True
            delay = state.get("startupDelay", 0)
            complete_start = True
        output = "daemon started successfully"
    file.seek(0)
    json.dump(state, file)
    file.truncate()

if command == "track-devices":
    def publish(snapshot):
        payload = "".join(f"{key}\t{value}\n" for key, value in snapshot.items())
        sys.stdout.write(f"{len(payload):04x}" + payload)
        sys.stdout.flush()

    publish(devices)
    for event in state.get("trackEvents", {}).get(str(port), []):
        time.sleep(event.get("after", 0))
        with (root / "state.json").open("r+") as file:
            fcntl.flock(file, fcntl.LOCK_EX)
            current = json.load(file)
            current.setdefault("devices", {})[str(port)] = event["devices"]
            file.seek(0)
            json.dump(current, file)
            file.truncate()
        publish(event["devices"])
    time.sleep(60)

if delay:
    time.sleep(delay)
if complete_start:
    with (root / "state.json").open("r+") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        state = json.load(file)
        state.setdefault("runningServers", {})[str(port)] = True
        state.setdefault("startingServers", {})[str(port)] = False
        file.seek(0)
        json.dump(state, file)
        file.truncate()
sys.stdout.write(output)
sys.stderr.write(error)
sys.exit(code)
