"""A test-only mDNS publisher that changes its SRV answer without announcing it."""
import socket
import struct
import threading
import time


def dns_name(name):
    return b''.join(bytes([len(label.encode())]) + label.encode() for label in name.rstrip('.').split('.')) + b'\0'


def read_name(packet, offset, visited=None):
    labels = []
    visited = set() if visited is None else visited
    end = None
    while offset < len(packet):
        if offset in visited:
            raise ValueError('DNS pointer loop')
        visited.add(offset)
        length = packet[offset]
        offset += 1
        if length == 0:
            return '.'.join(labels), end or offset
        if length & 0xc0 == 0xc0:
            pointer = ((length & 0x3f) << 8) | packet[offset]
            suffix, _ = read_name(packet, pointer, visited)
            return '.'.join(labels + [suffix]), end or offset + 1
        if length > 63 or offset + length > len(packet):
            raise ValueError('Invalid DNS label')
        labels.append(packet[offset:offset + length].decode())
        offset += length
    raise ValueError('Truncated DNS name')


class StaleBonjourFixture:
    def __init__(self, name, marker):
        self.name = name
        self.marker = marker
        self.type = '_adb-tls-connect._tcp.local'
        self.fullname = name + '.' + self.type
        self.host = 'afs-stale-' + name.removeprefix('adb-') + '.local'
        self.stop_event = threading.Event()
        self.fresh_queries = 0
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        self.socket.bind(('', 5353))
        self.socket.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                               socket.inet_aton('224.0.0.251') + socket.inet_aton('0.0.0.0'))
        self.socket.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        self.socket.settimeout(0.05)
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def packet(self, port, ttl=120):
        def record(name, kind, value, shared=False):
            return dns_name(name) + struct.pack('!HHIH', kind, 1 if shared else 0x8001, ttl, len(value)) + value
        records = [record(self.type, 12, dns_name(self.fullname), shared=True),
                   record(self.fullname, 33, struct.pack('!HHH', 0, 0, port) + dns_name(self.host)),
                   record(self.fullname, 16, b'\0'),
                   record(self.host, 1, socket.inet_aton('127.0.0.1'))]
        return struct.pack('!HHHHHH', 0, 0x8400, 0, len(records), 0, 0) + b''.join(records)

    def send(self, port, ttl=120):
        self.socket.sendto(self.packet(port, ttl), ('224.0.0.251', 5353))

    def serve(self):
        announced = 0
        last_announcement = 0
        while not self.stop_event.is_set():
            changed = self.marker.exists()
            # Warm the system cache once. After the marker, deliberately send no
            # unsolicited updates: only an actual SRV question reveals the new port.
            if not changed and announced < 3 and time.monotonic() - last_announcement > 0.3:
                self.send(50553)
                announced += 1
                last_announcement = time.monotonic()
            try:
                packet, _ = self.socket.recvfrom(9000)
                if len(packet) < 12 or struct.unpack_from('!H', packet, 2)[0] & 0x8000:
                    continue
                questions = struct.unpack_from('!H', packet, 4)[0]
                offset = 12
                answer = False
                for _ in range(questions):
                    name, offset = read_name(packet, offset)
                    kind, _ = struct.unpack_from('!HH', packet, offset)
                    offset += 4
                    if changed:
                        if name.lower() == self.fullname.lower() and kind == 33:
                            self.fresh_queries += 1
                            answer = True
                    elif name.lower() in [self.fullname.lower(), self.host.lower(), self.type]:
                        answer = True
                if answer:
                    self.send(50554 if changed else 50553)
            except (socket.timeout, ValueError, IndexError, UnicodeError, struct.error):
                pass

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=1)
        self.send(50553, ttl=0)
        self.send(50554, ttl=0)
        self.socket.close()
