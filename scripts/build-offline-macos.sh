#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CONTINUITY_OFFLINE=1
command -v swift >/dev/null
xcrun --find clang >/dev/null
python3 -c 'from pathlib import Path; assert len(list(Path("vendor/calling-sources").glob("*.tar.gz"))) == 3, "Use the complete offline-source bundle, including vendor/calling-sources."'
bash scripts/build-macos.sh
codesign --verify --strict "dist/Galaxy Continuity Lab.app"
printf '\nBuilt Galaxy Continuity v1.0 Beta 3 (52). Tests passed; app is in dist/.\n'
