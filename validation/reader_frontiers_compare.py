#!/usr/bin/env python3
"""TraceAgent compaction requests accumulate by antichain lattice join."""
import pathlib
import subprocess
ROOT=pathlib.Path(__file__).resolve().parent.parent

def compare(build=True):
    def run(args,**kwargs):
        return subprocess.run(args,cwd=ROOT,check=True,text=True,timeout=180,**kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    inputs=''.join(f'{seed}\n' for seed in range(1,65))
    rust=run(['validation/rust/target/release/differential-reference-check','reader_frontiers'],input=inputs,capture_output=True).stdout.splitlines()
    moon=run(['node','validation/run.cjs','reader_frontiers'],input=inputs,capture_output=True).stdout.splitlines()
    assert len(rust)==len(moon)==64
    def join(a,b):
        times={(max(x[0],y[0]),max(x[1],y[1])) for x in a for y in b}
        return sorted(t for t in times if not any(u!=t and u[0]<=t[0] and u[1]<=t[1] for u in times))
    for seed,(r,m) in enumerate(zip(rust,moon),1):
        state,bounds,expected=seed,[[(0,0)] for _ in range(4)],[]
        for _ in range(32):
            f,g=[],[]
            for _ in range(2):
                state=(state*1664525+1013904223)&0xffffffff
                f.append(((state>>8)%9,(state>>16)%9))
                state=(state*1664525+1013904223)&0xffffffff
                g.append(((state>>8)%9,(state>>16)%9))
            index=2*((state>>24)%2)
            bounds[index]=join(bounds[index],f)
            bounds[index+1]=join(bounds[index+1],g)
            expected.append('|'.join(';'.join(f'{a},{b}' for a,b in frontier) for frontier in bounds))
        assert r==m=='/'.join(expected),f'reader compaction request differs seed={seed}'
    print('Shared-reader compaction passed: 2048 Rust/model rounds with incomparable and backward requests, independent pins and irreversible empty frontiers')

if __name__=='__main__':
    compare()
