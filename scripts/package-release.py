#!/usr/bin/env python3
"""Package the built app and authored offline sources; never export local research or account data."""
from pathlib import Path
import hashlib
import platform
import plistlib
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
app = root / 'dist/Galaxy Continuity Lab.app'
version = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
assert version and all(c.isalnum() or c in '.-' for c in version)
output = root / 'dist'
binary = output / f'GalaxyContinuity-{version}-macOS-{platform.machine()}.zip'
subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(binary)], check=True)
source = output / f'GalaxyContinuity-{version}-offline-source.zip'
if (root / '.git').exists():
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
else:
    files = [p.relative_to(root).as_posix() for p in root.iterdir() if p.is_file() and p.name in {
        'Package.swift', 'LICENSE', 'README.md', 'SECURITY.md', 'CONTRIBUTING.md', 'ROADMAP.md', '.gitignore', '.gitattributes'
    }]
    for folder in ['Sources', 'Tests', 'scripts', 'docs', '.github']:
        files.extend(p.relative_to(root).as_posix() for p in (root / folder).rglob('*') if p.is_file())
forbidden = {'.git', '.private', '.build', 'dist', 'work', '__pycache__', 'Credentials'}
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(set(files)):
        path = root / name
        if not name or not path.is_file():
            continue
        assert not forbidden.intersection(Path(name).parts), 'Private/generated path was selected'
        assert path.suffix not in {'.token', '.dpapi', '.log', '.sqlite', '.db'}, 'Private artifact was selected'
        data = path.read_bytes()
        if path.suffix == '.sh':
            data = data.replace(b'\r\n', b'\n')
        info = zipfile.ZipInfo('GalaxyContinuity/' + Path(name).as_posix())
        info.create_system = 3
        info.external_attr = (0o100755 if path.suffix == '.sh' else 0o100644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
    archives = list((root / '.build/calling-sources').glob('*.tar.gz'))
    assert len(archives) == 3, 'Build the verified calling libraries first'
    for path in archives:
        archive.write(path, 'GalaxyContinuity/vendor/calling-sources/' + path.name)
manifest = output / f'SHA256SUMS-{version}.txt'
manifest.write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in [binary, source]), encoding='ascii')
print(binary.name, source.name, manifest.name, sep='\n')
