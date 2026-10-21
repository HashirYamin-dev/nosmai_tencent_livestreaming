#!/usr/bin/env python3
"""Create untracked QA config placeholders (never overwrites real secrets).

After cloning: python3 tools/bootstrap_local_qa.py
Then: bash configure.sh to set actual Tencent test tokens, and replace
lib/nosmai_license_local.dart with your own authorized Nosmai license.
"""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
for rel in ['config/host.json','config/viewer.json','lib/nosmai_license_local.dart']:
    src = root / (rel.replace('.json', '.example.json') if rel.endswith('.json') else rel.replace('.dart', '.example.dart'))
    dst = root / rel
    if dst.exists():
        print('KEPT existing local file:', rel)
        continue
    if not src.is_file():
        raise SystemExit('Missing example: ' + str(src))
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if rel.endswith('.json'):
        dst.chmod(0o600)
    print('CREATED local placeholder:', rel)
print('Set up actual test credentials locally; do not commit them.')
