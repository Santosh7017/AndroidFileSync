#!/usr/bin/env python3
"""Check the bundled adb's live output against an isolated loopback fake daemon."""
import os
from pathlib import Path
import select
import socket
import subprocess
import threading
import time

adb = Path(__file__).resolve().parents[1] / 'AndroidFileSync/Resources/adb'
commands = []
errors = []
stop = threading.Event()


def read_exact(client, size):
    result = b''
    while len(result) < size:
        chunk = client.recv(size - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result


def serve(listener):
    try:
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            with client:
                client.settimeout(2)
                request = read_exact(client, int(read_exact(client, 4), 16)).decode()
                commands.append(request)
                if request == 'host:version':
                    client.sendall(b'OKAY00040029')
                elif request == 'host:track-devices-l':
                    client.sendall(b'OKAY0000')
                    time.sleep(0.1)
                    payload = b'FIXTURE-USB\tdevice model:Fixture transport_id:1\n'
                    client.sendall(f'{len(payload):04x}'.encode() + payload)
                    stop.wait(3)
                else:
                    raise AssertionError(f'Unexpected daemon command: {request}')
    except Exception as error:
        errors.append(error)


with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(0.2)
    port = listener.getsockname()[1]
    thread = threading.Thread(target=serve, args=(listener,), daemon=True)
    thread.start()
    env = dict(os.environ)
    for key in ['ADB_SERVER_SOCKET', 'ANDROID_ADB_SERVER_ADDRESS', 'ANDROID_SERIAL']:
        env.pop(key, None)
    env.update(ANDROID_ADB_SERVER_PORT=str(port), ADB_SERVER_PORT=str(port), ADB_MDNS_AUTO_CONNECT='0')
    process = subprocess.Popen([str(adb), '-P', str(port), 'track-devices', '-l'],
                               env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output = b''
    started = time.monotonic()
    try:
        while time.monotonic() - started < 1:
            if select.select([process.stdout], [], [], 0.05)[0]:
                output += os.read(process.stdout.fileno(), 4096)
                if b'FIXTURE-USB' in output:
                    break
        assert not errors, errors
        assert b'FIXTURE-USB' in output, (output, commands, process.poll())
        assert process.poll() is None, 'Must deliver changes before the watcher exits'
        print(f'PASS: bundled adb delivered a live transport change in {time.monotonic() - started:.3f}s')
    finally:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        stop.set()
        thread.join(timeout=1)
