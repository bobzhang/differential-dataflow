#!/usr/bin/env python3
"""Exercise nonblocking transport progress, partial frames, and failures."""
import json
import time
import socket
import struct
import subprocess
from transport_failures import ROOT, port, connect, send, receive

BIN = ROOT / '_build/native/release/build/validation/cluster/cluster.exe'
PAYLOAD = '🪐☄️漢字\0'


def finish(process, success):
    out, err = process.communicate(timeout=30)
    assert 'AddressSanitizer' not in out+err and 'LeakSanitizer' not in out+err, (out,err)
    if success:
        assert process.returncode == 0 and out.strip() == 'wire-ok', (out,err)
    else:
        assert process.returncode != 0 and 'TransportError' in out+err, (out,err)


def cleanup(process):
    if process.poll() is None:
        process.kill()
    process.communicate()


def pending_progress():
    for mode in ('async_wait','async_wire'):
        address = port()
        process = subprocess.Popen([str(BIN),'0',str(address),'1','2',mode], cwd=ROOT,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with connect(address) as client:
                send(client,json.dumps(['moon-differential-tcp/1',1,2]).encode())
                assert receive(client) == b'ready'
                if mode == 'async_wait':
                    # The process must regain host control and exit after one
                    # pending poll, while this peer sends no exchange payload.
                    out,err=process.communicate(timeout=2)
                    assert process.returncode == 0 and out.strip() == 'wire-ok', (out,err)
                else:
                    for _ in range(3):
                        raw = PAYLOAD.encode()
                        header = struct.pack('!I',len(raw))
                        for fragment in (header[:1],header[1:3],header[3:]+raw[:2],raw[2:]):
                            client.sendall(fragment)
                            time.sleep(.002)
                        assert json.loads(receive(client)) == [PAYLOAD,PAYLOAD]
                    finish(process,True)
        finally:
            cleanup(process)


def failure(kind, client_side=False):
    address = port()
    listener = None
    if client_side:
        listener=socket.socket()
        listener.bind(('127.0.0.1',address))
        listener.listen()
        listener.settimeout(3)
    process=subprocess.Popen([str(BIN),'1' if client_side else '0',str(address),'1','2','async_timeout'],cwd=ROOT,
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        with (listener.accept()[0] if listener else connect(address)) as peer:
            peer.settimeout(3)
            if client_side:
                assert json.loads(receive(peer)) == ['moon-differential-tcp/1',1,2]
                send(peer,b'ready')
                receive(peer)
            else:
                send(peer,json.dumps(['moon-differential-tcp/1',1,2]).encode())
                assert receive(peer) == b'ready'
            if kind == 'oversized':
                peer.sendall(struct.pack('!I',0xffffffff))
            elif kind == 'invalid-utf8':
                send(peer,b'\xff')
            elif kind == 'truncated-header':
                peer.sendall(b'\0\0')
                peer.shutdown(socket.SHUT_WR)
            elif kind == 'truncated-body':
                peer.sendall(struct.pack('!I',32)+b'[')
                peer.shutdown(socket.SHUT_WR)
            elif kind == 'invalid-response':
                send(peer,b'[]')
            elif kind == 'deadline':
                peer.sendall(struct.pack('!I',32)+b'[')
            finish(process,False)
    finally:
        cleanup(process)
        if listener: listener.close()


def main(build=True):
    if build:
        subprocess.run(['moon','build','--target','native','--release','validation/cluster'],cwd=ROOT,check=True)
    pending_progress()
    cases=['oversized','invalid-utf8','truncated-header','truncated-body','deadline']
    for side in (False,True):
        for kind in cases:
            failure(kind,side)
    failure('invalid-response',True)
    for peers in (2,3):
        address=port()
        processes=[subprocess.Popen([str(BIN),str(peer),str(address),'200000',str(peers),'async_wire'],cwd=ROOT,
                                    stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for peer in reversed(range(peers))]
        try:
            for process in processes: finish(process,True)
        finally:
            for process in processes: cleanup(process)
    print('Nonblocking transport passed: host yields, fragmented frames, 11 failure cases, repeated large Unicode rounds on 2/3 peers')


if __name__ == '__main__':
    main()
