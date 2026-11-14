#!/usr/bin/env python3
"""Generate local patches with git diff against pinned upstream baselines."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
WORK = Path(os.environ.get('WORK', ROOT / 'work')).resolve()
KERNEL = WORK / 'kernel'
SUSFS = WORK / 'susfs'
LZ4 = WORK / 'lz4'
SOURCES = dict(line.split('=', 1) for line in (ROOT / 'configs/sources.env').read_text().splitlines()
               if line and not line.startswith('#'))


def check_revision(repo, key):
    actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != SOURCES[key]:
        raise ValueError(f'{repo}: expected {key}={SOURCES[key]}, got {actual}')


def populate_baseline(base, files):
    check_revision(KERNEL, 'KERNEL_SHA')
    check_revision(SUSFS, 'SUSFS_SHA')
    for name in files:
        dest = base / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        if name == Path('security/selinux/ss/app_zygote_filter.c'):
            continue
        if name.parts[:2] == ('KernelSU', 'kernel'):
            check_revision(KERNEL / 'KernelSU', 'KSU_SHA')
            data = subprocess.check_output(['git', '-C', str(KERNEL / 'KernelSU'), 'show',
                                            f"{SOURCES['KSU_SHA']}:{Path(*name.parts[1:])}"])
        elif name == Path('fs/susfs.c'):
            data = (SUSFS / 'kernel_patches/fs/susfs.c').read_bytes()
        elif name == Path('lib/lz4/lz4hc.c'):
            check_revision(LZ4, 'LZ4_SHA')
            data = (LZ4 / 'zram/lz4/lz4hc.c').read_bytes()
        else:
            data = subprocess.check_output(['git', '-C', str(KERNEL), 'show',
                                            f"{SOURCES['KERNEL_SHA']}:{name}"])
        dest.write_bytes(data)
    # These files were modified by the upstream SUSFS patch before our patch.
    selinux = {str(f) for f in files if str(f) in {
        'security/selinux/hooks.c', 'security/selinux/selinuxfs.c',
        'security/selinux/ss/services.c'}}
    if selinux:
        upstream = (SUSFS / 'kernel_patches/50_add_susfs_in_gki-android13-5.15.patch').read_text()
        chunks = upstream.split('diff --git ')[1:]
        selected = ['diff --git ' + chunk for chunk in chunks
                    if any(chunk.splitlines()[0] == f'a/{f} b/{f}' for f in selinux)]
        if len(selected) != len(selinux):
            raise ValueError('SUSFS patch is missing an expected SELinux file')
        run(['patch', '--batch', '--fuzz=0', '-p1', '-d', str(base)],
            input=''.join(selected).encode(), stdout=subprocess.DEVNULL)


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def generate(patch):
    content = patch.read_bytes()
    names = re.findall(rb'^\+\+\+ b/(.+)$', content, re.MULTILINE)
    files = [Path(os.fsdecode(name)) for name in names]
    if not files or len(files) != len(set(files)):
        raise ValueError(f'{patch.name}: invalid or duplicate paths')
    for name in files:
        if name.is_absolute() or '..' in name.parts:
            raise ValueError(f'{patch.name}: unsafe path {name}')
    source = ROOT / 'kernel' / 'patches' / patch.stem
    with tempfile.TemporaryDirectory(prefix='kernel-patch-') as temp:
        base = Path(temp)
        populate_baseline(base, files)
        run(['git', 'init', '-q', str(base)])
        run(['git', '-C', str(base), 'add', '-A'])
        run(['git', '-C', str(base), '-c', 'user.name=Patch Generator',
             '-c', 'user.email=patch-generator@localhost', 'commit',
             '--allow-empty', '-qm', 'baseline'])
        for name in files:
            dest = base / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, dest)
        run(['git', '-C', str(base), 'add', '-N', '--', *map(str, files)])
        result = subprocess.check_output(['git', '-C', str(base), 'diff', '--binary', '--', *map(str, files)])
        if not result:
            raise ValueError(f'{patch.name}: empty patch')
        # Verify the generated diff applies cleanly and reproduces the edited files.
        run(['git', '-C', str(base), 'reset', '--hard', '-q', 'HEAD'])
        for name in files:
            if (base / name).exists() and not subprocess.run(
                    ['git', '-C', str(base), 'ls-files', '--error-unmatch', '--', str(name)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                (base / name).unlink()
        run(['patch', '--batch', '--fuzz=0', '-p1', '-d', str(base)], input=result,
            stdout=subprocess.DEVNULL)
        for name in files:
            if (base / name).read_bytes() != (source / name).read_bytes():
                raise ValueError(f'{patch.name}: verification failed for {name}')
        patch.write_bytes(result)
        print(f'Updated {patch.relative_to(ROOT)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('patch', nargs='*', help='patch filenames or stems; default: all local patches')
    args = parser.parse_args()
    patches = sorted((ROOT / 'patches').glob('*.patch'))
    if args.patch:
        requested = {Path(p).stem for p in args.patch}
        patches = [p for p in patches if p.stem in requested]
        missing = requested - {p.stem for p in patches}
        if missing:
            parser.error('unknown patches: ' + ', '.join(sorted(missing)))
    for patch in patches:
        generate(patch)


if __name__ == '__main__':
    main()
