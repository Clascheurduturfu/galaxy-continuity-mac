#!/usr/bin/env python3
"""Build pinned, isolated static call codecs/SRTP with the Xcode command line tools."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PREFIX = ROOT / '.build/calling-native'
SOURCES = ROOT / '.build/calling-sources'
LIBRARIES = [
    ('libsrtp-2.6.0', 'https://github.com/cisco/libsrtp/archive/refs/tags/v2.6.0.tar.gz',
     'bf641aa654861be10570bfc137d1441283822418e9757dc71ebb69a6cf84ea6b', 'libsrtp2.a'),
    ('opencore-amr-0.1.6', 'https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz',
     '483eb4061088e2b34b358e47540b5d495a96cd468e361050fae615b1809dc4a1', 'libopencore-amrwb.a'),
    ('vo-amrwbenc-0.1.3', 'https://downloads.sourceforge.net/project/opencore-amr/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz',
     '5652b391e0f0e296417b841b02987d3fd33e6c0af342c69542cbb016a71d9d4e', 'libvo-amrwbenc.a'),
]


def main():
    if all((PREFIX / 'lib' / lib).is_file() for _, _, _, lib in LIBRARIES):
        print('Native calling libraries already available.')
        return
    SOURCES.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CFLAGS='-O2 -mmacosx-version-min=13.0',
               CXXFLAGS='-O2 -mmacosx-version-min=13.0', MACOSX_DEPLOYMENT_TARGET='13.0')
    with (SOURCES / 'build.log').open('wb') as log:
        for name, url, digest, library in LIBRARIES:
            archive = SOURCES / (name + '.tar.gz')
            if not archive.exists():
                bundled = ROOT / 'vendor/calling-sources' / archive.name
                if bundled.is_file():
                    shutil.copyfile(bundled, archive)
                else:
                    if os.environ.get('CONTINUITY_OFFLINE') == '1':
                        raise RuntimeError('Offline calling source is missing: ' + archive.name)
                    print('Downloading', name, flush=True)
                    with urllib.request.urlopen(url, timeout=60) as response:
                        payload = response.read(16 * 1024 * 1024 + 1)
                    if len(payload) > 16 * 1024 * 1024:
                        raise RuntimeError('Dependency archive exceeds size limit')
                    archive.write_bytes(payload)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
                raise RuntimeError('Dependency checksum failed: ' + name)
            with tarfile.open(archive, 'r:gz') as tar:
                members = tar.getmembers()
                for member in members:
                    target = SOURCES / member.name
                    if not target.resolve().is_relative_to(SOURCES.resolve()):
                        raise RuntimeError('Archive path escapes build directory')
                    if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                        raise RuntimeError('Unsupported archive member')
                directory = SOURCES / members[0].name.split('/')[0]
                if not directory.exists():
                    tar.extractall(SOURCES)
            options = ['./configure', '--prefix=' + str(PREFIX), '--disable-shared', '--enable-static']
            if name.startswith('opencore'):
                options += ['--disable-amrnb', '--enable-amrwb']
            if name.startswith('libsrtp'):
                options += ['--disable-openssl']
            print('Building', name, flush=True)
            for command in [options, ['make', '-j4'], ['make', 'install']]:
                subprocess.run(command, cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=300)
            if not (PREFIX / 'lib' / library).is_file():
                raise RuntimeError('Missing static library: ' + library)
    print('Native calling libraries ready.')


if __name__ == '__main__':
    main()
