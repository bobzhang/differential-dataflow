#!/usr/bin/env python3
"""Check logging against Rust and a separate batch/reader accounting model."""
import pathlib
import subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent

def compare(build=True):
    def run(args, **kwargs):
        return subprocess.run(args, cwd=ROOT, check=True, text=True, timeout=180, **kwargs)
    if build:
        run(['cargo', 'build', '--release', '--locked', '--manifest-path', 'validation/rust/Cargo.toml'])
        run(['moon', 'build', '--release', '--target', 'js'])
    inputs = ''.join(f'{seed}\n' for seed in range(1,65))
    rust = run(['validation/rust/target/release/differential-reference-check', 'diagnostics'], input=inputs, capture_output=True).stdout.splitlines()
    moon = run(['node', 'validation/run.cjs', 'diagnostics'], input=inputs, capture_output=True).stdout.splitlines()
    assert len(rust) == len(moon) == 64
    for seed, (r, m) in enumerate(zip(rust, moon), 1):
        state, created, pins, expected = seed, 0, 0, []
        for _ in range(24):
            counts = {}
            for _ in range(12):
                state = (state * 1664525 + 1013904223) & 0xffffffff
                key = (state >> 8) % 36
                counts[key] = counts.get(key, 0) + state % 5 - 2
            if (state >> 16) % 3 == 0:
                pins += 1
            if state % 5 == 0 and pins:
                pins -= 1
            created += sum(diff != 0 for diff in counts.values())
            expected.append(f'{created},{pins+1}')
        expected.append('0,0')
        assert r == m == '/'.join(expected), f'diagnostic accounting differs seed={seed}\nRust {r}\nMoon {m}'
    print('Diagnostics passed: 1600 batch/reader snapshots against Rust and independent accounting; both implementations release all logged storage')

if __name__ == '__main__':
    compare()
