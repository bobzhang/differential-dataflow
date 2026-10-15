#!/usr/bin/env python3
"""Validate explicit correction reducers and non-Abelian output differences."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent.parent


def presence_expected(seed):
    state,updates=seed,[]
    for _ in range(48):
        state=(state*1664525+1013904223)&0xffffffff
        i=(state>>8)%375
        updates.append((i//125,i%5,i//25%5,i//5%5))
    return '/'.join(';'.join(f'{k},{v}' for k,v in sorted({(k,v) for k,v,tx,ty in updates if tx<=x and ty<=y}))
                    for x in range(5) for y in range(5))


def compare(build=True):
    def run(args, **kwargs):
        return subprocess.run(args,cwd=ROOT,check=True,text=True,timeout=180,**kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    data=''.join(f'{seed}\n' for seed in range(1,33))
    rust=run(['validation/rust/target/release/differential-reference-check','core_reduce'],input=data,capture_output=True).stdout.splitlines()
    regular=run(['validation/rust/target/release/differential-reference-check','stream_reduce'],input=data,capture_output=True).stdout.splitlines()
    assert len(rust)==len(regular)==32 and rust==regular
    for mode in ('core_reduce','arranged_core_reduce','entered_core_reduce'):
        moon=run(['node','validation/run.cjs',mode],input=data,capture_output=True).stdout.splitlines()
        assert len(moon)==32
        for seed,(r,m) in enumerate(zip(rust,moon),1):
            assert r==m,f'{mode} seed={seed}\nRust {r}\nMoon {m}'
    data=''.join(f'{seed}\n' for seed in range(1,129))
    rust=run(['validation/rust/target/release/differential-reference-check','core_presence'],input=data,capture_output=True).stdout.splitlines()
    moon=run(['node','validation/run.cjs','core_presence'],input=data,capture_output=True).stdout.splitlines()
    assert len(rust)==len(moon)==128
    for seed,(r,m) in enumerate(zip(rust,moon),1):
        assert r==m==presence_expected(seed),f'presence seed={seed}\nRust {r}\nMoon {m}\nModel {presence_expected(seed)}'
    print('Core reduction passed: 2304 streamed partial-order epochs and 3200 presence-only snapshots against Rust, with independent presence recomputation')


if __name__=='__main__':
    compare()
