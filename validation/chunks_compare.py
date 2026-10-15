#!/usr/bin/env python3
"""Compare trie chunks with pinned Rust and an independent sorted-multiset model."""
import pathlib
import subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent

def compare(build=True):
    def run(args, **kwargs):
        return subprocess.run(args, cwd=ROOT, check=True, text=True, timeout=180, **kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    inputs = ''.join(f'{seed}\n' for seed in range(1,65))
    rust = run(['validation/rust/target/release/differential-reference-check','chunks'],input=inputs,capture_output=True).stdout.splitlines()
    moon = run(['node','validation/run.cjs','chunks'],input=inputs,capture_output=True).stdout.splitlines()
    assert len(rust) == len(moon) == 64
    def text(rows):
        return ';'.join(','.join(map(str,row)) for row in rows)
    def consolidate(rows):
        sums = {}
        for *key, diff in rows:
            key = tuple(key)
            sums[key] = sums.get(key,0) + diff
        return [(*key,diff) for key,diff in sorted(sums.items()) if diff]
    for seed,(r,m) in enumerate(zip(rust,moon),1):
        state, expected = seed, []
        for case in range(16):
            sides = []
            for side in range(2):
                raw = []
                for _ in range(24):
                    state = (state*1664525+1013904223) & 0xffffffff
                    x = (state>>8)%256
                    if (case+side+seed)%11:
                        raw.append((x//64,x//16%4,x//4%4,x%4,state%5-2))
                sides.append(consolidate(raw))
            a,b = sides
            full = consolidate(a+b)
            if not a or not b:
                head,sa,sb = full,[],[]
            else:
                i=j=0
                consumed=[]
                while i<len(a) and j<len(b):
                    if a[i][:-1] < b[j][:-1]:
                        consumed.append(a[i]); i+=1
                    elif a[i][:-1] > b[j][:-1]:
                        consumed.append(b[j]); j+=1
                    else:
                        consumed.extend([a[i],b[j]]); i+=1; j+=1
                head,sa,sb=consolidate(consumed),a[i:],b[j:]
            count=state%(len(full)+3)
            def kept(row):
                return (row[2]>=1 and row[3]>=3) or (row[2]>=3 and row[3]>=1)
            ready=[row for row in full if not kept(row)]
            future=[row for row in full if kept(row)]
            times={row[2:4] for row in future}
            frontier=sorted(t for t in times if not any(u!=t and u[0]<=t[0] and u[1]<=t[1] for u in times))
            expected.append('|'.join(map(text,[a,b,head,sa,sb,full,full[:count],full[count:],ready,future,frontier])))
        assert r == m == '/'.join(expected), f'columnar chunk mismatch seed={seed}'
    print('Columnar chunks passed: 1024 cases, 11264 snapshots against Rust and independent multisets, including partial merges, cancellation, split/meld and incomparable-frontier extraction')

if __name__ == '__main__':
    compare()
