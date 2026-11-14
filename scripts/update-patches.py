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


def patch_files(patch):
    content = patch.read_bytes()
    names = re.findall(rb'^\+\+\+ b/(.+)$', content, re.MULTILINE)
    files = [Path(os.fsdecode(name)) for name in names]
    if not files or len(files) != len(set(files)):
        raise ValueError(f'{patch.name}: invalid or duplicate paths')
    if any(name.is_absolute() or '..' in name.parts for name in files):
        raise ValueError(f'{patch.name}: unsafe path')
    return files


def patch_path(name):
    name = Path(name).name
    if not name.endswith('.patch'):
        name += '.patch'
    patch = ROOT / 'patches' / name
    if not patch.is_file():
        raise ValueError(f'Unknown patch: {name}')
    return patch


def edit_path(patch):
    return WORK / 'patch-edit' / patch.stem


def create(patch):
    files = patch_files(patch)
    path = edit_path(patch)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.mkdir()  # Never overwrite an existing editing workspace.
    try:
        populate_baseline(path, files)
        run(['git', 'init', '-q', str(path)])
        run(['git', '-C', str(path), 'add', '-A'])
        run(['git', '-C', str(path), '-c', 'user.name=Patch Workspace',
             '-c', 'user.email=patch-workspace@localhost', 'commit',
             '--allow-empty', '-qm', 'baseline'])
        run(['patch', '--batch', '--fuzz=0', '-p1', '-d', str(path)],
            input=patch.read_bytes(), stdout=subprocess.DEVNULL)
        own = Path('security/selinux/ss/app_zygote_filter.c')
        if own in files:
            shutil.copy2(ROOT / 'kernel/selinux/app_zygote_filter.c', path / own)
        run(['git', '-C', str(path), 'add', '-N', '--', *map(str, files)])
    except Exception:
        shutil.rmtree(path)
        raise
    print(f'Editable workspace: {path}')


def export(patch):
    files = patch_files(patch)
    path = edit_path(patch)
    if not (path / '.git').exists():
        raise ValueError(f'Workspace missing: {path}; create it first')
    run(['git', '-C', str(path), 'add', '-N', '--', *map(str, files)])
    result = subprocess.check_output(['git', '-C', str(path), 'diff', '--binary', '--', *map(str, files)])
    if not result:
        raise ValueError(f'{patch.name}: empty patch')
    # Rebuild the pinned baseline and verify the generated patch reproduces the workspace.
    with tempfile.TemporaryDirectory(prefix='kernel-patch-check-') as temp:
        base = Path(temp)
        populate_baseline(base, files)
        run(['patch', '--batch', '--fuzz=0', '-p1', '-d', str(base)], input=result,
            stdout=subprocess.DEVNULL)
        for name in files:
            if (base / name).read_bytes() != (path / name).read_bytes():
                raise ValueError(f'{patch.name}: verification failed for {name}')
    own = Path('security/selinux/ss/app_zygote_filter.c')
    if own in files:
        shutil.copy2(path / own, ROOT / 'kernel/selinux/app_zygote_filter.c')
    patch.write_bytes(result)
    print(f'Updated {patch.relative_to(ROOT)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('create', 'export'))
    parser.add_argument('patch', help='local patch filename or stem')
    args = parser.parse_args()
    patch = patch_path(args.patch)
    if args.command == 'create':
        create(patch)
    else:
        export(patch)


if __name__ == '__main__':
    main()
