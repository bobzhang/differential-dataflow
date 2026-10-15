#!/usr/bin/env python3
"""Compare progress frontier changes and lattice compaction against pinned Rust."""
import json
import pathlib
import subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, **kwargs)
pins = json.loads((ROOT/'validation/pins.json').read_text())
for name, pin in pins.items():
    assert run(['git','-C',f'.repos/{name}','rev-parse','HEAD'],capture_output=True).stdout.strip() == pin
    assert not run(['git','-C',f'.repos/{name}','status','--porcelain'],capture_output=True).stdout.strip()
run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
run(['moon','build','--release','--target','js'])
seeds = range(1,257)
inputs = ''.join(f'{s}\n' for s in seeds)
rust = run(['validation/rust/target/release/differential-reference-check'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(seeds)
for seed, r, m in zip(seeds,rust,moon):
    state=seed
    counts={}
    old=set()
    expected=[]
    for _ in range(40):
        for _ in range(3):
            state=(state*1664525+1013904223)&0xffffffff
            idx=(state>>8)%25
            t=(idx//5,idx%5)
            counts[t]=counts.get(t,0)+(-1 if state%3==0 else 1)
        positive={t for t,c in counts.items() if c>0}
        minimal={t for t in positive if not any(u!=t and u[0]<=t[0] and u[1]<=t[1] for u in positive)}
        changes=sorted([(t,-1) for t in old-minimal]+[(t,1) for t in minimal-old])
        base=(seed%5,(seed//5)%5)
        advanced=tuple(min(max(base[k],t[k]) for t in minimal) for k in (0,1)) if minimal else base
        expected.append(';'.join(f'{t[0]},{t[1]},{d}' for t,d in changes)+'|'+';'.join(f'{a},{b}' for a,b in sorted(minimal))+f'|{advanced[0]},{advanced[1]}')
        old=minimal
    assert r==m=='/'.join(expected), f'frontier differential failure at seed {seed}'
summary={'references':pins,'seeds':len(seeds),'rounds_per_seed':40,'checks_per_round':['frontier membership changes','minimal positive timestamps','lattice advance_by'],'oracle':'independent Python positive-count partial-order model','status':'passed'}
(ROOT/'validation/results.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
