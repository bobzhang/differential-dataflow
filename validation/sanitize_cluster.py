#!/usr/bin/env python3
"""Build an isolated ASan/LSan cluster binary without changing the toolchain."""
import os
import platform
import shutil
import subprocess
from pathlib import Path
import cluster_compare
import transport_failures
import journal_check

ROOT = Path(__file__).resolve().parent.parent


def main():
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'validation/cluster'], cwd=ROOT, check=True)
    moon_home = Path(os.environ.get('MOON_HOME', Path(shutil.which('moon')).resolve().parent.parent))
    compiler = os.environ.get('ASAN_CC') or shutil.which('/opt/homebrew/opt/llvm/bin/clang') or shutil.which('clang')
    if not compiler:
        raise RuntimeError('AddressSanitizer requires clang; set ASAN_CC to its path')
    output = ROOT / '_build/sanitizer/cluster.exe'
    output.parent.mkdir(parents=True, exist_ok=True)
    runtime = moon_home / 'lib/runtime'
    sources = [ROOT / '_build/native/release/build/validation/cluster/cluster.c', ROOT / 'transport/tcp.c']
    sources += [runtime / f'{name}.c' for name in ('runtime', 'backtrace', 'env', 'sync_io', 'utf')]
    libraries = [moon_home / 'lib' / name for name in ('moonbit_simdutf.o', 'simdutf.o', 'libbacktrace.a')]
    command = [compiler, '-O1', '-g', '-fsanitize=address', '-fno-omit-frame-pointer',
               '-DMOONBIT_ALLOCATOR=1', '-I', str(moon_home / 'include')]
    command += list(map(str, sources + libraries))
    command += ['-lc++' if platform.system() == 'Darwin' else '-lstdc++', '-lm', '-o', str(output)]
    subprocess.run(command, cwd=ROOT, check=True)
    os.environ.setdefault('ASAN_OPTIONS', 'detect_leaks=1:fast_unwind_on_malloc=0')
    cluster_compare.BIN = output
    transport_failures.BIN = output
    # Exercise row and columnar shared graph indexes and live imported views,
    # with normal closure and disposal while input capabilities are still alive.
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'validation/lifetimes'], cwd=ROOT, check=True)
    lifetime_output = output.with_name('lifetimes.exe')
    lifetime_source = ROOT / '_build/native/release/build/validation/lifetimes/lifetimes.c'
    lifetime_command = [str(lifetime_source) if arg == str(sources[0]) else str(lifetime_output) if arg == str(output) else arg for arg in command]
    subprocess.run(lifetime_command, cwd=ROOT, check=True)
    subprocess.run([str(lifetime_output)], cwd=ROOT, check=True)
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'validation/spill'], cwd=ROOT, check=True)
    spill_output = output.with_name('spill.exe')
    spill_source = ROOT / '_build/native/release/build/validation/spill/spill.c'
    spill_command = [str(spill_source) if arg == str(sources[0]) else str(ROOT / 'spill_file/file.c') if arg == str(sources[1]) else str(spill_output) if arg == str(output) else arg for arg in command]
    subprocess.run(spill_command, cwd=ROOT, check=True)
    subprocess.run([str(spill_output)], cwd=ROOT, check=True)
    subprocess.run(['moon', 'build', '--target', 'native', '--release', 'validation/journal'], cwd=ROOT, check=True)
    journal_output = output.with_name('journal.exe')
    journal_source = ROOT / '_build/native/release/build/validation/journal/journal.c'
    journal_command = [str(journal_source) if arg == str(sources[0]) else str(ROOT / 'capture_journal/journal.c') if arg == str(sources[1]) else str(journal_output) if arg == str(output) else arg for arg in command]
    subprocess.run(journal_command, cwd=ROOT, check=True)
    journal_check.BIN = journal_output
    journal_check.check()
    for peers in (2, 3):
        assert cluster_compare.run_peers(42, peers) == cluster_compare.independent(42)
        assert cluster_compare.run_peers(42, peers, 'replay') == cluster_compare.replay_expected(42)
        assert cluster_compare.run_peers(42, peers, 'dynamic_iteration') == '/'.join(cluster_compare.reachable(42 + i) for i in range(3))
        for mode in ('iteration', 'deep_iteration'):
            assert cluster_compare.run_peers(42, peers, mode) == cluster_compare.reachable(42)
    transport_failures.main()
    print('AddressSanitizer and LeakSanitizer checks passed')


if __name__ == '__main__':
    main()
