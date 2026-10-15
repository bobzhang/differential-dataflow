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
join_seeds = range(1,65)
inputs = ''.join(f'{s}\n' for s in join_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','join'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','join'],input=inputs,capture_output=True).stdout.splitlines()
scope_join = run(['node','validation/run.cjs','scope_join'],input=inputs,capture_output=True).stdout.splitlines()
assert scope_join == moon, 'counted scope join runtime differs'
assert len(rust) == len(moon) == len(join_seeds)
for seed,r,m in zip(join_seeds,rust,moon):
    state=seed
    sides=[[0]*20,[0]*20]
    expected=[]
    for epoch in range(16):
        for side in range(2):
            for _ in range(4):
                state=(state*1664525+1013904223)&0xffffffff
                sides[side][(state>>8)%20] += state%5-2
        values=[]
        for k in range(4):
            for v in range(5):
                for w in range(5):
                    count=sides[0][k*5+v]*sides[1][k*5+w]
                    if count: values.append(f'{k},{v},{w},{count}')
        expected.append(';'.join(values))
    assert r==m=='/'.join(expected), f'weighted join differential failure at seed {seed}'
reduce_seeds = range(1,129)
inputs = ''.join(f'{s}\n' for s in reduce_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','reduce'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','reduce'],input=inputs,capture_output=True).stdout.splitlines()
scope_reduce = run(['node','validation/run.cjs','scope_reduce'],input=inputs,capture_output=True).stdout.splitlines()
assert scope_reduce == moon, 'counted scope reduction runtime differs'
assert len(rust) == len(moon) == len(reduce_seeds)
for seed,r,m in zip(reduce_seeds,rust,moon):
    assert r == m, f'partial-order reduction differential failure at seed {seed}\nRust: {r}\nMoon: {m}'
    state=seed
    updates=[]
    for _ in range(32):
        state=(state*1664525+1013904223)&0xffffffff
        idx=(state>>8)%375
        updates.append((idx//125,idx%5,idx//25%5,idx//5%5,state%5-2))
    actual=[tuple(map(int,row.split(','))) for row in m.split(';') if row]
    for x in range(5):
        for y in range(5):
            expected={}
            for k in range(3):
                values={v:sum(d for key,val,a,b,d in updates if key==k and val==v and a<=x and b<=y) for v in range(5)}
                total=sum(values.values())
                if total:
                    expected[0,k,0]=1
                    expected[1,k,total]=1
                nonzero=[v for v,count in values.items() if count]
                if nonzero: expected[2,k,min(nonzero)]=1
            snapshot={}
            for op,k,v,a,b,d in actual:
                if a<=x and b<=y: snapshot[op,k,v]=snapshot.get((op,k,v),0)+d
            snapshot={key:d for key,d in snapshot.items() if d}
            assert snapshot==expected, f'reduction snapshot failure seed={seed} time={(x,y)}'
feedback_seeds = range(1,65)
inputs = ''.join(f'{s}\n' for s in feedback_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','feedback'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','feedback'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(feedback_seeds)
for seed,r,m in zip(feedback_seeds,rust,moon):
    state=seed
    observed={}
    expected=[]
    for epoch in range(4):
        for _ in range(8):
            state=(state*1664525+1013904223)&0xffffffff
            start=(state>>8)%8
            for d in range(start,12):
                key=(d,epoch*64+(d-start)*(seed%3+1))
                observed[key]=observed.get(key,0)+state%5-2
        expected.append(';'.join(f'{d},{t},{r}' for (d,t),r in sorted(observed.items()) if r))
    assert r==m=='/'.join(expected), f'feedback failure seed={seed}'
summary={'references':pins,'frontier_seeds':len(seeds),'frontier_rounds_per_seed':40,'frontier_checks':['membership changes','minimal positive timestamps','lattice advance_by'],'join_seeds':len(join_seeds),'join_epochs_per_seed':16,'oracles':['independent positive-count partial-order model','full weighted join recomputation each epoch'],'runtimes':['acyclic forwarding','counted pointstamp scopes'],'reduce_seeds':len(reduce_seeds),'reduce_queries_per_seed':25,'reduce_checks':['distinct','count','group minimum','exact product-timestamp corrections','independent grid snapshots'],'feedback_seeds':len(feedback_seeds),'feedback_epochs_per_seed':4,'status':'passed'}
(ROOT/'validation/results.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
