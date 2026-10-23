#!/usr/bin/env python3
"""Install a locally built app, comparing credentials only after the old app quits.

Run on macOS with --app <built .app> --staging <owned build directory>.
Keep the staging directory until launch/acceptance is verified, then remove it.
No credential contents or hashes are printed or included in the report.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import stat
import plistlib
import shutil
import subprocess
import time
import uuid


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def ensure(condition, message):
    if not condition:
        raise RuntimeError(message)


def requirement(app):
    result = run('codesign', '-d', '-r-', str(app))
    return next(line for line in (result.stdout + result.stderr).splitlines() if line.startswith('designated =>'))


def install(source, stage):
    target = Path('/Applications/Galaxy Continuity Lab.app')
    ensure(not stage.is_symlink() and not source.is_symlink(), "Build inputs must not be symbolic links")
    stage = stage.resolve(strict=True)
    source = source.resolve(strict=True)
    stage_info = stage.lstat()
    ensure(stat.S_ISDIR(stage_info.st_mode) and stage_info.st_uid == os.getuid() and stage_info.st_mode & 0o077 == 0, 'Staging directory must be private and owned by the current user')
    ensure(stage.parent == Path('/private/tmp') and source.is_relative_to(stage), 'Use an owned temporary build directory')
    ensure(source.name == target.name and not target.is_symlink(), "Unexpected or symlinked app bundle")
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    ensure(info['CFBundleIdentifier'] == 'local.galaxy-continuity-lab', 'Unexpected bundle identifier')
    run('codesign', '--verify', '--strict', str(source))
    ensure(requirement(source) == requirement(target), 'The app signing requirement changed')
    credentials = Path.home() / 'Library/Application Support/Galaxy Continuity Lab/Credentials'

    def credential_snapshot():
        result = {}
        folder = credentials.lstat()
        ensure(stat.S_ISDIR(folder.st_mode) and folder.st_uid == os.getuid() and folder.st_mode & 0o077 == 0, 'Credential directory is not private and owned by the current user')
        for path in credentials.iterdir():
            if path.name.startswith('.'):
                continue
            entry = path.lstat()
            ensure(stat.S_ISREG(entry.st_mode) and entry.st_uid == os.getuid() and entry.st_nlink == 1 and entry.st_mode & 0o077 == 0, 'A credential file is not private and owned by the current user')
            result[path.name] = hashlib.sha256(path.read_bytes()).digest()
        return result

    def running():
        command = str(target / 'Contents/MacOS/GalaxyContinuityLab')
        return any(line.strip() == command or line.strip().startswith(command + ' ') for line in run('ps', '-ax', '-o', 'command=').stdout.splitlines())

    suffix = uuid.uuid4().hex
    candidate = stage / ('install-' + suffix + '.app')
    backup = stage / ('previous-' + suffix + '.app')
    shutil.copytree(source, candidate)
    swapped = False
    try:
        if running():
            run('osascript', '-e', 'tell application id "local.galaxy-continuity-lab" to quit')
        for _ in range(80):
            if not running():
                break
            time.sleep(0.25)
        else:
            raise RuntimeError('The existing app did not quit; it was not replaced')
        # Quit may finish a legitimate login refresh. Snapshot AFTER it has
        # stopped, so refresh is not mistaken for installer credential damage.
        before = credential_snapshot()
        time.sleep(0.25)
        ensure(credential_snapshot() == before, 'Credential files are still being updated; retry later')
        target.rename(backup)
        try:
            candidate.rename(target)
        except BaseException:
            backup.rename(target)
            raise
        swapped = True
        ensure(credential_snapshot() == before, 'Credential files changed during replacement')
        run('codesign', '--verify', '--strict', str(target))
        run('open', '-a', str(target))
        report = {
            'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'signatureVerified': True, 'designatedRequirementPreserved': True,
            'credentialsPreservedDuringReplacement': True, 'privateFileCount': len(before),
            'binarySHA256': hashlib.sha256((target / 'Contents/MacOS/GalaxyContinuityLab').read_bytes()).hexdigest(),
            'launchRequested': True, 'backupName': backup.name,
        }
        (stage / 'local-install.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print(json.dumps({key: value for key, value in report.items() if key != 'backupName'}))
    except BaseException:
        if swapped and backup.exists():
            if running():
                run('osascript', '-e', 'tell application id "local.galaxy-continuity-lab" to quit')
                for _ in range(80):
                    if not running():
                        break
                    time.sleep(0.25)
                if running():
                    raise RuntimeError('App still running; previous app retained in the build directory')
            if target.exists():
                shutil.rmtree(target)
            backup.rename(target)
        if target.exists() and not running():
            run('open', '-a', str(target))
        raise
    finally:
        if candidate.exists():
            shutil.rmtree(candidate)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--staging', type=Path, required=True)
    args = parser.parse_args()
    install(args.app, args.staging)
