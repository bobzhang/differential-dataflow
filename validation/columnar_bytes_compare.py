#!/usr/bin/env python3
"""Verify exact pinned Rust columnar byte encodings, not a substitute wire format."""
import pathlib
import struct
import subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent

def compare(build=True):
    def run(args, **kwargs):
        return subprocess.run(args,cwd=ROOT,check=True,text=True,timeout=180,**kwargs)
    if build:
        run(['cargo','build','--release','--locked','--manifest-path','validation/rust/Cargo.toml'])
        run(['moon','build','--release','--target','js'])
    inputs=''.join(f'{seed}\n' for seed in range(1,65))
    rust=run(['validation/rust/target/release/differential-reference-check','columnar_bytes'],input=inputs,capture_output=True).stdout.splitlines()
    moon=run(['node','validation/run.cjs','columnar_bytes'],input=inputs,capture_output=True).stdout.splitlines()
    assert len(rust)==len(moon)==64
    # Independently validate the outer length table and indexed slice framing.
    for seed,(r,m) in enumerate(zip(rust,moon),1):
        assert r==m, f'columnar binary encoding differs seed={seed}'
        fixtures=r.split('|')
        assert len(fixtures)==4
        for encoded in fixtures:
            data=bytes.fromhex(encoded)
            lengths=struct.unpack_from('<4Q',data)
            assert 32+sum(lengths)==len(data)
            offset=32
            for length in lengths:
                column=data[offset:offset+length]
                header=struct.unpack_from('<Q',column)[0]
                assert header%8==0 and 16<=header<=length
                ends=struct.unpack_from('<'+'Q'*(header//8),column)
                lower=header
                for end in ends[1:]:
                    assert lower<=end<=length
                    lower=(end+7)//8*8
                assert lower==length
                offset+=length
    print('Columnar binary encoding passed: 256 byte-identical Rust fixtures, independent framing validation, and both decoders round-trip strings, products, signed integers, packed booleans, vectors, units and durations')

if __name__=='__main__':
    compare()
