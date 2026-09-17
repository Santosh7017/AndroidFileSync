#!/usr/bin/env python3
"""Test production direct-reply mDNS on loopback without contacting any phone."""
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

project = Path(__file__).resolve().parents[1]


def name(value):
    return b"".join(bytes([len(label)]) + label.encode() for label in value.split(".")) + b"\0"


packet = bytearray(struct.pack("!6H", 0x1234, 0x8400, 1, 1, 0, 3))
packet += name("_adb-tls-pairing._tcp.local") + struct.pack("!HH", 12, 1)


def record(owner, kind, value):
    packet.extend(owner + struct.pack("!HHIH", kind, 1, 10, len(value)))
    offset = len(packet)
    packet.extend(value)
    return offset


instance = record(b"\xc0\x0c", 12, b"\x0bafs-fixture\xc0\x0c")
srv = record(struct.pack("!H", 0xC000 | instance), 33,
             struct.pack("!3H", 0, 0, 40645) + name("Android.local"))
record(struct.pack("!H", 0xC000 | (srv + 6)), 1, bytes([192, 168, 1, 210]))
record(struct.pack("!H", 0xC000 | instance), 16, b"\0")


def response(records, request_id=0):
    return struct.pack("!6H", request_id, 0x8400, 0, len(records), 0, 0) + b"".join(records)


def standalone_record(owner, kind, value, ttl=10):
    return name(owner) + struct.pack("!HHIH", kind, 1, ttl, len(value)) + value


qr_owner = "afs-fixture._adb-tls-pairing._tcp.local"
srv_reply = response([standalone_record(qr_owner, 33, struct.pack("!3H", 0, 0, 40645) + name("Android.local"))])
address_reply = response([standalone_record("Android.local", 1, bytes([192, 168, 1, 210]))])
goodbye = response([standalone_record(qr_owner, 33, struct.pack("!3H", 0, 0, 40645) + name("Android.local"), ttl=0)])
rotated = response([standalone_record(qr_owner, 33, struct.pack("!3H", 0, 0, 40646) + name("Android.local"))])

with tempfile.TemporaryDirectory(prefix="afs-pairing-probe-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    (root / "response.bin").write_bytes(packet)
    (root / "srv.bin").write_bytes(srv_reply)
    (root / "address.bin").write_bytes(address_reply)
    (root / "goodbye.bin").write_bytes(goodbye)
    (root / "rotated.bin").write_bytes(rotated)
    build = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(root / "module-cache"),
        str(project / "AndroidFileSync/Managers/PairingMDNSProbe.swift"),
        str(project / "AndroidFileSync/Managers/PairingNetworkAccess.swift"),
        str(project / "AndroidFileSync/Managers/WirelessDiscovery.swift"),
        str(project / "ConnectionTests/PairingProbeHarness.swift"), "-o", str(root / "probe-tests"),
    ], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr)
        raise SystemExit(build.returncode)
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 0))
    server.settimeout(10)
    access_server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    access_server.bind(("127.0.0.1", 0))
    access_server.settimeout(1)
    # The permission check must never open a TCP connection, which would
    # consume Android's one-time pairing listener before ADB sends its TLS data.
    tcp_guard = socket.socket()
    tcp_guard.bind(access_server.getsockname())
    tcp_guard.listen()
    tcp_guard.settimeout(0.05)
    received = []

    def reply():
        try:
            # Android's Java responder uses QU, not source port, to decide
            # whether it should send its answer back to this socket.
            query, peer = server.recvfrom(512)
            received.append((query, peer))
            assert query[-2:] == b'\x80\x01', "Pairing SRV must explicitly request unicast"
            server.sendto(query[:2] + packet[2:], peer)
            # Second lookup: the phone has no browse PTR, returns only its
            # exact SRV, and supplies A only after a separate host question.
            query, peer = server.recvfrom(512)
            received.append((query, peer))
            server.sendto(srv_reply, peer)
            query, peer = server.recvfrom(512)
            received.append((query, peer))
            server.sendto(address_reply, peer)
        except socket.timeout:
            pass

    thread = threading.Thread(target=reply)
    thread.start()
    try:
        subprocess.run([str(root / "probe-tests"), str(root / "response.bin"),
                        str(server.getsockname()[1]), str(access_server.getsockname()[1])], check=True, timeout=15)
        access_query, _ = access_server.recvfrom(512)
        assert struct.unpack("!6H", access_query[:12]) == (0, 0, 1, 0, 0, 0)
        assert access_query[12:] == name("_adb-tls-pairing._tcp.local") + struct.pack("!HH", 12, 0x8001)
        try:
            unexpected, _ = tcp_guard.accept()
        except socket.timeout:
            pass
        else:
            unexpected.close()
            raise AssertionError("Native permission check opened a TCP connection")
        thread.join(timeout=1)
        assert len(received) == 3 and all(peer[1] != 5353 for _, peer in received)
        for query, _ in received[:2]:
            assert struct.unpack("!5H", query[2:12]) == (0, 2, 0, 0, 0)
            assert query[12:] == (name("_adb-tls-pairing._tcp.local") + struct.pack("!HH", 12, 0x8001)
                                  + name(qr_owner) + struct.pack("!HH", 33, 0x8001))
        assert received[2][0][12:] == name("Android.local") + struct.pack("!HH", 1, 0x8001)
    finally:
        tcp_guard.close()
        access_server.close()
        server.close()
        thread.join(timeout=10)
