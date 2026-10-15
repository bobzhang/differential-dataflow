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
    logical_mode = mode.removeprefix("async_")
    epochs = 13 if logical_mode == "envelopes" else 24 if logical_mode == "dynamic_iteration" else 8 if logical_mode in ("iteration", "deep_iteration", "pointstamp") else 16
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
            assert process.returncode == 0, (peer, process.returncode, stdout, stderr)
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


def replay_expected(seed):
    random, state, result = seed & 0xffffffff, {}, []
    for epoch in range(16):
        for slot in range(8):
            random = (random * 1664525 + 1013904223) & 0xffffffff
            key = (seed % 16 + slot) % 16
            diff = (random % 3 + 1) * (1 if random % 2 == 0 else -1)
            state[key] = state.get(key, 0) + diff
        result.append(';'.join(f'{d},{r}' for d,r in sorted(state.items()) if r))
    return '/'.join(result)


def cancellation_expected(seed, peers):
    base = seed % 1000
    return '/'.join(';'.join(f'{base+i},{peers}' for i in range(epoch+1)) for epoch in range(16))


def envelope_snapshot(reference):
    from collections import Counter
    expected = []
    for phase in reference.split('/'):
        rows = Counter()
        for record in phase.split(';'):
            if record:
                tag, cap, data, time, diff = map(int,record.split(','))
                if tag == 2: rows[cap,data,time] += diff
        expected.append(';'.join(f'{cap},{data},{time},{diff}' for (cap,data,time),diff in sorted(rows.items()) if diff))
    return '/'.join(expected)


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
            for mode in ('join', 'async_join'):
                actual = run_peers(seed, peer_count, mode)
                assert actual == expected == independent(seed), (seed, peer_count, mode)
    iteration_rust = subprocess.run(['validation/rust/target/release/differential-reference-check', 'iteration'],
                                   cwd=ROOT, input=''.join(f'{seed}\n' for seed in seeds), text=True,
                                   capture_output=True, check=True, timeout=90).stdout.splitlines()
    assert len(iteration_rust) == len(seeds)
    for peer_count in (2, 3):
        for seed, expected in zip(seeds, iteration_rust):
            for mode in ('iteration', 'deep_iteration', 'async_iteration', 'async_deep_iteration'):
                assert run_peers(seed, peer_count, mode) == expected == reachable(seed), (seed, peer_count, mode)
    for peer_count in (2, 3):
        for seed in (1, 7, 42):
            expected = '/'.join(reachable(seed + offset) for offset in range(3))
            for mode in ('dynamic_iteration', 'async_dynamic_iteration'):
                assert run_peers(seed, peer_count, mode) == expected
    replay_rust = subprocess.run(['validation/rust/target/release/differential-reference-check', 'group_replay'],
                                cwd=ROOT, input=''.join(f'{seed}\n' for seed in seeds), text=True,
                                capture_output=True, check=True, timeout=90).stdout.splitlines()
    assert len(replay_rust) == len(seeds)
    for peer_count in (2, 3):
        for seed, expected in zip(seeds, replay_rust):
            for mode in ('replay', 'async_replay'):
                assert run_peers(seed, peer_count, mode) == expected == replay_expected(seed)
    for peer_count in (2, 3):
        for seed in seeds:
            for mode in ('cancellation', 'async_cancellation'):
                assert run_peers(seed, peer_count, mode) == cancellation_expected(seed, peer_count)
    from pointstamp_compare import iteration_expected
    dynamic_rust = subprocess.run(['validation/rust/target/release/differential-reference-check', 'dynamic_iteration'],
                                 cwd=ROOT, input=''.join(f'{seed}\n' for seed in seeds), text=True,
                                 capture_output=True, check=True, timeout=90).stdout.splitlines()
    assert len(dynamic_rust) == len(seeds)
    for peer_count in (2, 3):
        for seed, expected in zip(seeds, dynamic_rust):
            for mode in ('pointstamp', 'async_pointstamp'):
                assert run_peers(seed, peer_count, mode) == expected == iteration_expected(seed), (seed, peer_count, mode)
    from envelope_compare import expected as envelope_expected
    envelope_rust = subprocess.run(['validation/rust/target/release/differential-reference-check', 'envelopes'],
                                  cwd=ROOT, input=''.join(f'{seed}\n' for seed in seeds), text=True,
                                  capture_output=True, check=True, timeout=90).stdout.splitlines()
    assert len(envelope_rust) == len(seeds)
    for seed, reference in zip(seeds, envelope_rust):
        assert reference == envelope_expected(seed)
        expected = envelope_snapshot(reference)
        for peer_count in (2,3):
            for mode in ('envelopes','async_envelopes'):
                assert run_peers(seed,peer_count,mode) == expected, (seed,peer_count,mode)
    result = {'process_counts': [2, 3], 'seeds': seeds, 'epochs_per_seed': 16,
              'oracles': ['pinned Rust two-worker join', 'independent full weighted join', 'pinned Rust three-worker replay', 'independent replay totals'],
              'checks': ['TCP startup retry', 'keyed exchange', 'shared arrangement joins',
                         'global progress each epoch', 'closure', 'nested product timestamps',
                         'cyclic fixed points', 'two nested feedback loops', 'root retractions', 'independent BFS',
                         'capture duplicates across peers', 'progress before replay data',
                         'unanimous completed-scope reclamation', 'any-peer nested dataflow cancellation with live siblings', 'nonblocking host polling for every distributed workload'],
              'message_capability_snapshots': 208, 'runtime_depth_iteration_epochs': 128, 'async_host_polling_epochs': 952, 'collective_cancellation_epochs': 128, 'distributed_replay_epochs': 128, 'dynamic_dataflow_epochs': 144, 'iteration_epochs_per_seed': 8, 'status': 'passed'}
    (ROOT / 'validation/cluster_results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
