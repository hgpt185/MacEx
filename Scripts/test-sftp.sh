#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
fixture_python="$PWD/.build/ssh-tools/bin/python"
if [[ ! -x "$fixture_python" ]]; then
    python3 -m venv .build/ssh-tools
fi
if ! "$fixture_python" -c 'import paramiko; assert paramiko.__version__ == "4.0.0"' 2>/dev/null; then
    "$fixture_python" -m pip install -r Tests/SFTPFixtures/requirements.txt
fi
export MACEX_SFTP_TEST_PYTHON="$fixture_python"
zsh Scripts/test.sh "$@"
