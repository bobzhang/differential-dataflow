#!/usr/bin/env python3
"""Independent framing, truncation and corruption checks for native capture logs."""
import json
import pathlib
import struct
import subprocess
import tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / '_build/native/release/build/validation/journal/journal.exe'

def run(mode, path, ok=True):
    result = subprocess.run([str(BIN), mode, str(path)], text=True, capture_output=True, timeout=30)
    assert 'AddressSanitizer' not in result.stderr and 'LeakSanitizer' not in result.stderr, result.stderr
    assert (result.returncode == 0) == ok, (mode, result.returncode, result.stdout, result.stderr)
    return result.stdout.strip()

def checksum(data):
    h = 2166136261
    for byte in data:
        h = ((h ^ byte) * 16777619) & 0xffffffff
    return h

def frame(data):
    return b'DDC1' + struct.pack('<II', len(data), checksum(data)) + data

def check():
    with tempfile.TemporaryDirectory(prefix='dd-journal-') as directory:
        root = pathlib.Path(directory)
        path = root / 'capture'
        assert run('write', path) == 'written'
        expected = [True, True, [['数据\0',str(i),'9007199254740993'] for i in range(24)]]
        assert json.loads(run('read', path)) == expected
        original = path.read_bytes()
        run('write', path, ok=False)
        assert path.read_bytes() == original, 'exclusive create overwrote the log'
        run('closed', path, ok=False)
        run('readonly', path, ok=False)
        assert run('follow', root / 'live') == 'followed'
        assert json.loads(run('read', root / 'live')) == expected
        ends, offset, messages = [], 0, []
        while offset < len(original):
            assert original[offset:offset+4] == b'DDC1'
            size, digest = struct.unpack_from('<II',original,offset+4)
            payload = original[offset+12:offset+12+size]
            assert checksum(payload) == digest
            messages.append(json.loads(payload))
            offset += size+12
            ends.append(offset)
        assert len(messages) == 49 and messages[-1][3] == []
        # Every cut in the first data/progress pair, plus both sides of all later boundaries.
        cuts = sorted(set(range(ends[1]+1)) | {e-1 for e in ends} | set(ends))
        broken = root / 'broken'
        for cut in cuts:
            broken.write_bytes(original[:cut])
            completed, done, rows = json.loads(run('read', broken))
            sealed = sum(end <= cut for end in ends[1:48:2])
            assert rows == expected[2][:sealed], (cut,sealed,rows)
            assert completed == done == (cut == len(original)), cut
        for corrupt in [b'bad!'+original[4:], original[:8]+b'\0\0\0\0'+original[12:],
                        b'DDC1'+struct.pack('<II',0xffffffff,0), frame(b'\xff'), frame(b'not json'),
                        frame(b'[]'), frame(b'["moon-differential-capture/1","progress",["2"],["1"],[]]')]:
            broken.write_bytes(corrupt)
            run('read', broken, ok=False)
            assert run('poison', broken) == 'poisoned'
        print(f'Capture journals passed: 24 persisted epochs, live tailing, {len(cuts)} truncation cuts, 7 corruption cases, exclusive creation and closed/read-only errors')

if __name__ == '__main__':
    subprocess.run(['moon','build','--release','--target','native','validation/journal'],cwd=ROOT,check=True)
    check()
