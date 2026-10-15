#!/usr/bin/env python3
"""Compare real TCP processes with Rust and independent recomputed join results."""
import json
import socket
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / '_build/native/release/build/validation/cluster/cluster.exe'


def run_peers(seed, peers, mode="join"):
    epochs = 8 if mode == "iteration" else 16
    with socket.socket() as reserved:
        reserved.bind(('127.0.0.1', 0))
        port = reserved.getsockname()[1]
    processes = []
    try:
        # Start clients first to exercise bounded startup retries.
        for peer in reversed(range(peers)):
            processes.append((peer, subprocess.Popen(
                [str(BIN), str(peer), str(port), str(seed), str(peers), mode],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)))
            time.sleep(0.01)
        outputs = {}
        for peer, process in processes:
            stdout, stderr = process.communicate(timeout=45)
            assert process.returncode == 0, (peer, process.returncode, stderr)
            outputs[peer] = stdout.strip().split('/')
            assert len(outputs[peer]) == epochs, (peer, stdout)
        result = []
        for epoch in range(epochs):
            rows = [tuple(map(int, row.split(','))) for peer in range(peers)
                    for row in outputs[peer][epoch].split(';') if row]
            assert len({row[:-1] for row in rows}) == len(rows), 'key routed to multiple peers'
            result.append(';'.join(','.join(map(str, row)) for row in sorted(rows)))
        return '/'.join(result)
    finally:
        for _, process in processes:
            if process.poll() is None:
                process.kill()
            process.communicate()


def independent(seed):
    random = seed & 0xffffffff
    states = [{}, {}]
    result = []
    for _ in range(16):
        for side in range(2):
            for _ in range(4):
                random = (random * 1664525 + 1013904223) & 0xffffffff
                index = (random >> 8) % 20
                key = index // 5, index % 5
                states[side][key] = states[side].get(key, 0) + random % 5 - 2
        rows = sorted((k, v, w, a * b) for (k, v), a in states[0].items()
                      for (j, w), b in states[1].items() if k == j and a * b)
        result.append(';'.join(','.join(map(str, row)) for row in rows))
    return '/'.join(result)


def reachable(seed):
    random = seed & 0xffffffff
    edges = [[] for _ in range(6)]
    for _ in range(12):
        random = (random * 1664525 + 1013904223) & 0xffffffff
        index = (random >> 8) % 36
        edges[index // 6].append(index % 6)
    roots = set()
    results = []
    for _ in range(8):
        for _ in range(2):
            random = (random * 1664525 + 1013904223) & 0xffffffff
            key = (random >> 8) % 6
            roots.symmetric_difference_update([key])
        reached = set(roots)
        pending = list(roots)
        while pending:
            for target in edges[pending.pop()]:
                if target not in reached:
                    reached.add(target)
                    pending.append(target)
        results.append(';'.join(f'{key},1' for key in sorted(reached)))
    return '/'.join(results)


def main():
    pins = json.loads((ROOT / 'validation/pins.json').read_text())
    for name, pin in pins.items():
        actual = subprocess.check_output(['git', '-C', f'.repos/{name}', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        dirty = subprocess.check_output(['git', '-C', f'.repos/{name}', 'status', '--porcelain'], cwd=ROOT, text=True).strip()
        assert actual == pin and not dirty, f'reference mismatch: {name}'
    subprocess.run(['cargo', 'build', '--release', '--locked', '--manifest-path', 'validation/rust/Cargo.toml'], cwd=ROOT, check=True)
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'validation/cluster'], cwd=ROOT, check=True)
    seeds = [1, 7, 42, 2147483647]
    rust = subprocess.run(['validation/rust/target/release/differential-reference-check', 'group_join'],
                          cwd=ROOT, input=''.join(f'{seed}\n' for seed in seeds), text=True,
                          capture_output=True, check=True, timeout=90).stdout.splitlines()
    assert len(rust) == len(seeds)
    for peer_count in (2, 3):
        for seed, expected in zip(seeds, rust):
            actual = run_peers(seed, peer_count)
            assert actual == expected == independent(seed), (seed, peer_count)
    iteration_rust = subprocess.run(['validation/rust/target/release/differential-reference-check', 'iteration'],
                                   cwd=ROOT, input=''.join(f'{seed}\n' for seed in seeds), text=True,
                                   capture_output=True, check=True, timeout=90).stdout.splitlines()
    assert len(iteration_rust) == len(seeds)
    for peer_count in (2, 3):
        for seed, expected in zip(seeds, iteration_rust):
            assert run_peers(seed, peer_count, 'iteration') == expected == reachable(seed), (seed, peer_count, 'iteration')
    result = {'process_counts': [2, 3], 'seeds': seeds, 'epochs_per_seed': 16,
              'oracles': ['pinned Rust two-worker join', 'independent full weighted join'],
              'checks': ['TCP startup retry', 'keyed exchange', 'shared arrangement joins',
                         'global progress each epoch', 'closure', 'nested product timestamps',
                         'cyclic fixed points', 'root retractions', 'independent BFS'],
              'iteration_epochs_per_seed': 8, 'status': 'passed'}
    (ROOT / 'validation/cluster_results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
