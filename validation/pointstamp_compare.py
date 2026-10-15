#!/usr/bin/env python3
"""Check dynamic timestamps and runtime-selected iteration depths."""
from itertools import zip_longest
import pathlib
import subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
MAX = (1 << 64) - 1


def normalize(v):
    while v and v[-1] == 0:
        v.pop()
    return v


def show(v):
    return '[' + ','.join(map(str,v)) + ']'


def expected(seed):
    state = seed
    def next_value():
        nonlocal state
        state = (state * 1664525 + 1013904223) & 0xffffffff
        return state
    def vector():
        return [(next_value() >> 8) % 7 for _ in range(next_value() % 5)]
    rows=[]
    for case in range(32):
        a,b=normalize(vector()),normalize(vector())
        retain=next_value()%6
        sa=vector()
        if case%8==0:sa.append(MAX)
        sr=None if retain==0 else retain-1
        retain=next_value()%6
        ta=vector()
        tr=None if retain==0 else retain-1
        pairs=list(zip_longest(a,b,fillvalue=0))
        le=all(x<=y for x,y in pairs)
        join=normalize([max(x,y) for x,y in pairs])
        meet=normalize([min(x,y) for x,y in pairs])
        advanced=[x+y for x,y in zip_longest(a[:sr] if sr is not None else a,sa,fillvalue=0)]
        output='N' if any(x>MAX for x in advanced) else show(normalize(advanced))
        composed=[x+y for x,y in zip_longest(sa[:tr] if tr is not None else sa,ta,fillvalue=0)]
        retained=min([r for r in (sr,tr) if r is not None],default=None)
        composed='N' if any(x>MAX for x in composed) else f'{"n" if retained is None else retained}:{show(composed)}'
        rows.append('|'.join([show(a),show(b),str(le).lower(),str((a>b)-(a<b)),show(join),show(meet),output,composed]))
    return '/'.join(rows)


def iteration_expected(seed):
    state,roots,rows=seed,set(),[]
    for _ in range(8):
        for _ in range(3):
            state=(state*1664525+1013904223)&0xffffffff
            roots.symmetric_difference_update([(state>>8)%12])
        rows.append(';'.join(f'{i},1' for i in range(min(roots,default=12),12)))
    return '/'.join(rows)


def compare(build=True):
    def run(args, **kwargs):
        return subprocess.run(args,cwd=ROOT,check=True,text=True,timeout=180,**kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    for mode,count,oracle in [('pointstamp',128,expected),('dynamic_iteration',64,iteration_expected)]:
        data=''.join(f'{seed}\n' for seed in range(1,count+1))
        rust=run(['validation/rust/target/release/differential-reference-check',mode],input=data,capture_output=True).stdout.splitlines()
        moon=run(['node','validation/run.cjs',mode],input=data,capture_output=True).stdout.splitlines()
        assert len(rust)==len(moon)==count
        for seed,r,m in zip(range(1,count+1),rust,moon):
            assert r==m==oracle(seed),f'{mode} seed={seed}\nRust {r}\nMoon {m}\nModel {oracle(seed)}'
    print('Dynamic scopes passed: 4096 pointstamp/summary cases and 512 fixed-point epochs with runtime-selected depths against Rust and independent models')


if __name__=='__main__':
    compare()
