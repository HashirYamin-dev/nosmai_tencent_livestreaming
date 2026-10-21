#!/usr/bin/env python3
"""Validate a credential profile without displaying its token."""
import json
from pathlib import Path
import sys
from configure import make_config

try:
    path = Path(sys.argv[1])
    data = json.loads(path.read_text())
    checked = make_config(int(data['SDK_APP_ID']), data['USER_ID'], data['USER_SIG'])
    if int(data.get('TOKEN_EXPIRES_AT', 0)) != checked['TOKEN_EXPIRES_AT']:
        raise ValueError('TOKEN_EXPIRES_AT does not match the token. Run configure.sh again.')
    print(f"Using SDKAppID {checked['SDK_APP_ID']} | User ID {checked['USER_ID']}")
except (ValueError, KeyError, OSError, IndexError) as exc:
    print(f'ERROR: {exc}\nRun bash configure.sh before building.', file=sys.stderr)
    sys.exit(1)
