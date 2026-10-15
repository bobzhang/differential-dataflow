#!/usr/bin/env python3
"""Compare adapted upstream examples with Rust and independent full recomputation."""
from collections import Counter
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent

def expected(seed):
    state, edges, snapshots = seed, set(), []
    for epoch in range(12):
        if epoch == 11:
            edges.clear()
        elif epoch:
            for _ in range(10):
                state = (state * 1664525 + 1013904223) & 0xffffffff
                i = (state >> 8) % 64
                edge = (i // 8, i % 8)
                edges.symmetric_difference_update([edge])
        degrees = Counter(a for a, _ in edges)
        histogram = Counter(degrees.values())
        nodes = set().union(*(set(e) for e in edges))
        ranks = dict.fromkeys(nodes, 6_000_000)
        for _ in range(seed % 5 + 1):
            following = dict.fromkeys(nodes, 1_000_000)
            for a, b in edges:
                following[b] += (5 * ranks[a]) // (6 * degrees[a])
            ranks = following
        remaining = [(a,b) for a,b in edges if degrees[a] < 4]
        by_item = {}
        for user, item in remaining:
            by_item.setdefault(item, set()).add(user)
        scores = []
        for a in sorted(by_item):
            for b in sorted(by_item):
                if a <= b:
                    continue
                intersection = len(by_item[a] & by_item[b])
                union = len(by_item[a] | by_item[b])
                if intersection * 20 > union:
                    scores.append(f'{a},{b},{intersection},{union},1')
        snapshots.append('|'.join([
            ';'.join(f'{node},{rank}' for node,rank in sorted(ranks.items())),
            ';'.join(f'{degree},{count},1' for degree,count in sorted(histogram.items())),
            ';'.join(scores),
        ]))
    return '/'.join(snapshots)

def compare(build=True):
    def run(args, **kwargs):
        return subprocess.run(args, cwd=ROOT, check=True, text=True, timeout=180, **kwargs)
    if build:
        pins = json.loads((ROOT/'validation/pins.json').read_text())
        for name, pin in pins.items():
            assert run(['git','-C',f'.repos/{name}','rev-parse','HEAD'],capture_output=True).stdout.strip() == pin
            assert not run(['git','-C',f'.repos/{name}','status','--porcelain'],capture_output=True).stdout.strip()
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    seeds = range(1,33)
    data = ''.join(f'{seed}\n' for seed in seeds)
    rust = run(['validation/rust/target/release/differential-reference-check','examples'],input=data,capture_output=True).stdout.splitlines()
    moon = run(['node','validation/run.cjs','examples'],input=data,capture_output=True).stdout.splitlines()
    assert len(rust) == len(moon) == len(seeds)
    for seed,r,m in zip(seeds,rust,moon):
        e = expected(seed)
        for epoch, (re,me,ee) in enumerate(zip(r.split('/'),m.split('/'),e.split('/'))):
            assert re == me == ee, f'example seed={seed} epoch={epoch}\nRust {re}\nMoon {me}\nModel {ee}'
        assert r == m == e
    print('Examples passed: 384 incremental epochs for PageRank, degree histograms, and recommendations against Rust and full recomputation')

if __name__ == '__main__':
    compare()
