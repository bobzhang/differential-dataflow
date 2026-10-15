#!/usr/bin/env python3
"""Check upstream min-plus feedback against independent Dijkstra recomputation."""
from pathlib import Path
import heapq
import subprocess
ROOT=Path(__file__).resolve().parent.parent


def expected(seed):
    state,edges,roots,rows=seed,{},set(),[]
    for epoch in range(16):
        if epoch in (0,8):
            state=(state*1664525+1013904223)&0xffffffff
            roots.add((state>>8)%12)
        for _ in range(4):
            state=(state*1664525+1013904223)&0xffffffff
            i=(state>>8)%144
            edge=i//12,i%12
            edges[edge]=min(edges.get(edge,10),state%10)
        distances={root:0 for root in roots}
        queue=[(0,root) for root in roots]
        heapq.heapify(queue)
        while queue:
            distance,node=heapq.heappop(queue)
            if distance!=distances[node]:continue
            for (a,b),weight in edges.items():
                if a==node and distance+weight<distances.get(b,1<<32):
                    distances[b]=distance+weight
                    heapq.heappush(queue,(distance+weight,b))
        rows.append(';'.join(f'{k},{v}' for k,v in sorted(distances.items())))
    return '/'.join(rows)


def compare(build=True):
    def run(args,**kwargs):
        return subprocess.run(args,cwd=ROOT,check=True,text=True,timeout=180,**kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    data=''.join(f'{seed}\n' for seed in range(1,65))
    rust=run(['validation/rust/target/release/differential-reference-check','monoid_bfs'],input=data,capture_output=True).stdout.splitlines()
    moon=run(['node','validation/run.cjs','monoid_bfs'],input=data,capture_output=True).stdout.splitlines()
    assert len(rust)==len(moon)==64
    for seed,(r,m) in enumerate(zip(rust,moon),1):
        assert r==m==expected(seed),f'min-plus seed={seed}\nRust {r}\nMoon {m}\nDijkstra {expected(seed)}'
    print('Min-plus feedback passed: 1024 graph epochs with decreasing weights, zero-weight cycles, and new roots against Rust and independent Dijkstra')


if __name__=='__main__':
    compare()
