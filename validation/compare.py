#!/usr/bin/env python3
"""Compare runtime, collections, traces, and capture behavior against pinned Rust."""
import json
import pathlib
import subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, timeout=180, **kwargs)
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
join_cases = dict(zip(join_seeds, moon))
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
iteration_seeds = range(1,33)
inputs = ''.join(f'{s}\n' for s in iteration_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','iteration'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','iteration'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(iteration_seeds)
for seed,r,m in zip(iteration_seeds,rust,moon):
    state=seed
    edges=[[] for _ in range(6)]
    for _ in range(12):
        state=(state*1664525+1013904223)&0xffffffff
        idx=(state>>8)%36
        edges[idx//6].append(idx%6)
    roots=set()
    expected=[]
    for epoch in range(8):
        for _ in range(2):
            state=(state*1664525+1013904223)&0xffffffff
            roots.symmetric_difference_update({(state>>8)%6})
        reachable=set(roots)
        todo=list(roots)
        while todo:
            for target in edges[todo.pop()]:
                if target not in reachable:
                    reachable.add(target)
                    todo.append(target)
        expected.append(';'.join(f'{d},1' for d in sorted(reachable)))
    assert r==m=='/'.join(expected), f'nested iteration failure seed={seed}'
arrangement_seeds = range(1,65)
inputs = ''.join(f'{s}\n' for s in arrangement_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','arrangement'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','arrangement'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(arrangement_seeds)
for seed,r,m in zip(arrangement_seeds,rust,moon):
    state=seed
    snapshots=[]
    counts=[0]*12
    expected=[]
    for epoch in range(16):
        for _ in range(6):
            state=(state*1664525+1013904223)&0xffffffff
            counts[(state>>8)%12]+=state%5-2
        snapshots.append(';'.join(f'{idx//4},{idx%4},{count}' for idx,count in enumerate(counts) if count))
        expected.append(snapshots[epoch//4*4]+'|'+snapshots[epoch])
    assert r==m=='/'.join(expected), f'arrangement reader failure seed={seed}'
upsert_seeds = range(1,129)
inputs = ''.join(f'{s}\n' for s in upsert_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','upsert'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','upsert'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(upsert_seeds)
for seed,r,m in zip(upsert_seeds,rust,moon):
    state=seed
    latest={}
    for _ in range(64):
        state=(state*1664525+1013904223)&0xffffffff
        idx=(state>>8)%256
        key=(idx//64,idx//8%8)
        value=-1 if state%4==0 else idx%8
        latest[key]=max(latest.get(key,-1),value)
    previous={}
    changes={}
    for (k,t),v in sorted(latest.items(),key=lambda row:(row[0][1],row[0][0])):
        old=previous.get(k,-1)
        if old!=v:
            if old!=-1: changes[k,old,t]=changes.get((k,old,t),0)-1
            if v!=-1: changes[k,v,t]=changes.get((k,v,t),0)+1
            previous[k]=v
    expected=';'.join(f'{k},{v},{t},{r}' for (k,v,t),r in sorted(changes.items()) if r)
    assert r==m==expected, f'upsert failure seed={seed}'
replay_seeds = range(1,257)
inputs = ''.join(f'{s}\n' for s in replay_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','replay'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','replay'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(replay_seeds)
for seed,r,m in zip(replay_seeds,rust,moon):
    assert r==m, f'capture replay progress failure seed={seed}'
    state=seed
    expected=[]
    for epoch in range(8):
        state=(state*1664525+1013904223)&0xffffffff
        data=(state>>8)%11
        diff=state%3+1
        expected.extend([(data,epoch,diff),(data+20,epoch,-diff)])
    observed=[]
    frontier=0
    for batch in m.split('/'):
        updates,progress=batch.split('|')
        observed.extend(tuple(map(int,record.split(','))) for record in updates.split(';') if record)
        next_frontier=int(progress) if progress else float('inf')
        assert next_frontier>frontier
        frontier=next_frontier
    assert frontier==float('inf') and sorted(observed)==sorted(expected), f'capture replay records failure seed={seed}'
group_join_seeds = range(1,33)
inputs = ''.join(f'{s}\n' for s in group_join_seeds)
rust = run(['validation/rust/target/release/differential-reference-check','group_join'],input=inputs,capture_output=True).stdout.splitlines()
moon = run(['node','validation/run.cjs','group_join'],input=inputs,capture_output=True).stdout.splitlines()
assert len(rust) == len(moon) == len(group_join_seeds)
for seed,r,m in zip(group_join_seeds,rust,moon):
    assert r==m==join_cases[seed], f'two-worker join failure seed={seed}'
summary = {
    'references': pins,
    'frontier_seeds': len(seeds),
    'frontier_rounds_per_seed': 40,
    'frontier_checks': ['membership changes', 'minimal positive timestamps', 'lattice advance_by'],
    'join_seeds': len(join_seeds),
    'join_epochs_per_seed': 16,
    'oracles': ['independent positive-count partial-order model', 'full weighted join recomputation each epoch'],
    'runtimes': ['acyclic forwarding', 'counted pointstamp scopes', 'coordinated worker groups'],
    'reduce_seeds': len(reduce_seeds),
    'reduce_queries_per_seed': 25,
    'reduce_checks': ['distinct', 'count', 'group minimum', 'exact product-timestamp corrections', 'independent grid snapshots'],
    'feedback_seeds': len(feedback_seeds),
    'feedback_epochs_per_seed': 4,
    'iteration_seeds': len(iteration_seeds),
    'iteration_epochs_per_seed': 8,
    'iteration_checks': ['nested fixed points', 'root insertions and retractions', 'cyclic graph BFS oracle'],
    'arrangement_seeds': len(arrangement_seeds),
    'arrangement_epochs_per_seed': 16,
    'arrangement_checks': ['independent readers', 'logical and physical compaction', 'past and current snapshots'],
    'upsert_seeds': len(upsert_seeds),
    'upsert_records_per_seed': 64,
    'upsert_checks': ['out-of-order times', 'greatest-value tie breaking', 'deletion and repeated values'],
    'replay_seeds': len(replay_seeds),
    'replay_checks': ['reordered duplicated messages', 'exact progress transitions', 'complete unique updates'],
    'group_join_seeds': len(group_join_seeds),
    'group_join_epochs_per_seed': 16,
    'group_join_peers': 2,
    'status': 'passed',
}
(ROOT/'validation/results.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
