#!/usr/bin/env python3
"""Exercise framing bounds, disconnects, deadlines and invalid protocols."""
import json
import socket
import struct
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / '_build/native/release/build/validation/cluster/cluster.exe'


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def connect(address):
    deadline = time.monotonic() + 3
    while True:
        try:
            return socket.create_connection(('127.0.0.1', address), timeout=2)
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(.01)


def send(s, payload):
    s.sendall(struct.pack('!I', len(payload)) + payload)


def receive(s):
    def exact(size):
        result = b''
        while len(result) < size:
            piece = s.recv(size - len(result))
            assert piece, 'unexpected EOF'
            result += piece
        return result
    return exact(struct.unpack('!I', exact(4))[0])


def failure(kind):
    address = port()
    process = subprocess.Popen([str(BIN), '0', str(address), '1', '2', 'timeout'],
                               cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        with connect(address) as client:
            if kind == 'oversized':
                client.sendall(struct.pack('!I', 0xffffffff))
            elif kind == 'invalid-utf8':
                send(client, b'\xff')
            elif kind == 'truncated-header':
                client.sendall(b'\x00\x00')
                client.shutdown(socket.SHUT_WR)
            elif kind == 'deadline':
                client.sendall(struct.pack('!I', 32) + b'[')
            elif kind == 'wrong-peer':
                send(client, json.dumps(['moon-differential-tcp/1', 0, 2]).encode())
            else:
                send(client, json.dumps(['moon-differential-tcp/1', 1, 2]).encode())
                assert receive(client) == b'ready'
                if kind == 'truncated-body':
                    client.sendall(struct.pack('!I', 32) + b'[')
                    client.shutdown(socket.SHUT_WR)
                elif kind == 'protocol':
                    send(client, b'[]')
                    receive(client)
                elif kind == 'graph':
                    # Copy the root envelope but mutate its scope manifest.
                    envelope = ['moon-differential/1', '0', 1, 2, [[], 0], [], [], False]
                    send(client, json.dumps(envelope).encode())
                    receive(client)
            stdout, stderr = process.communicate(timeout=3)
            assert process.returncode != 0, (kind, stdout, stderr)
            assert 'TransportError' in stdout + stderr or 'ClusterError' in stdout + stderr, (kind, stderr)
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate()


def main():
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'validation/cluster'], cwd=ROOT, check=True)
    cases = ['oversized', 'invalid-utf8', 'truncated-header', 'truncated-body',
             'deadline', 'wrong-peer', 'protocol', 'graph']
    for kind in cases:
        failure(kind)
    address = port()
    processes = [subprocess.Popen([str(BIN), str(peer), str(address), '200000', '2', 'wire'],
                 cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for peer in (1, 0)]
    try:
        for process in processes:
            stdout, stderr = process.communicate(timeout=30)
            assert process.returncode == 0 and stdout.strip() == 'wire-ok', (stdout, stderr)
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.communicate()
    print(json.dumps({'fault_cases': cases, 'large_unicode_round_trip': 'passed', 'status': 'passed'}))


if __name__ == '__main__':
    main()
