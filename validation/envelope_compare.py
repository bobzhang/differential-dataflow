#!/usr/bin/env python3
"""Check message capabilities independently of logical record timestamps."""
from collections import Counter
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent.parent


def expected(seed):
    state,seen,pending,results=seed,[],[],[]
    for epoch in range(12):
        batch=[]
        for _ in range(6):
            state=(state*1664525+1013904223)&0xffffffff
            d=(state>>8)%8
            batch.append((d,epoch+10+d%3,state%5-2))
        consolidated=Counter()
        for d,t,r in batch:consolidated[d,t]+=r
        seen.extend((0,epoch,d,t,r) for (d,t),r in consolidated.items() if r)
        for d,t,r in batch:
            seen.extend([(1,epoch,d,t-3,r),(4,epoch,d,t,r),(5,epoch,d,t,r),
                         (3,epoch,d+1,max(t,d%7*5),2*r),(3,epoch,d+1,max(t,d%5*7),-r)])
            pending.append((2,epoch+2,d,t+5,r))
        seen.extend(row for row in pending if row[1]<epoch+1)
        pending=[row for row in pending if row[1]>=epoch+1]
        results.append(';'.join(','.join(map(str,row)) for row in sorted(seen)))
    seen.extend(pending)
    results.append(';'.join(','.join(map(str,row)) for row in sorted(seen)))
    return '/'.join(results)


def compare(build=True):
    def run(args,**kwargs):
        return subprocess.run(args,cwd=ROOT,check=True,text=True,timeout=180,**kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    data=''.join(f'{seed}\n' for seed in range(1,33))
    rust=run(['validation/rust/target/release/differential-reference-check','envelopes'],input=data,capture_output=True).stdout.splitlines()
    moon=run(['node','validation/run.cjs','envelopes'],input=data,capture_output=True).stdout.splitlines()
    assert len(rust)==len(moon)==32
    for seed,(r,m) in enumerate(zip(rust,moon),1):
        model=expected(seed)
        if not r==m==model:
            for epoch,(rr,mm,ee) in enumerate(zip(r.split('/'),m.split('/'),model.split('/'))):
                if not rr==mm==ee:
                    raise AssertionError(f'capability seed={seed} phase={epoch}\nRust {rr}\nMoon {mm}\nModel {ee}')
            raise AssertionError(f'phase count differs seed={seed}')
    print('Message capabilities passed: 2496 operator snapshots against Rust and an independent model, including delayed delivery, future records, negative summaries, nested entry and batch forwarding')


if __name__=='__main__':
    compare()
