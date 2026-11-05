#!/bin/zsh
# Starts the disposable loopback SFTP server used by the tests, for manual checks of Connections.
# Everything lives in a new temporary folder that is deleted when you press Ctrl-C.
# Sign in with: host 127.0.0.1, the printed port, user "fixture", password "test-only-password".
set -euo pipefail
cd "${0:A:h:h}"
fixture_python="$PWD/.build/ssh-tools/bin/python"
if [[ ! -x "$fixture_python" ]]; then python3 -m venv .build/ssh-tools; fi
if ! "$fixture_python" -c 'import paramiko; assert paramiko.__version__ == "4.0.0"' 2>/dev/null; then
    "$fixture_python" -m pip install -r Tests/SFTPFixtures/requirements.txt
fi
root=$(mktemp -d "${TMPDIR:-/tmp}/MacEx-SFTP-manual.XXXXXX")
server_pid=""
cleanup() { [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$root" }
trap cleanup EXIT INT TERM
mkdir -p "$root/files/Folder"
print "Remote fixture file" > "$root/files/Remote note.txt"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$root/host"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$root/user"
"$fixture_python" Tests/SFTPFixtures/server.py --root "$root/files" --host-key "$root/host" \
    --ready "$root/ready.json" --events "$root/events" --allowed-key "$root/user.pub" &
server_pid=$!
for _ in {1..250}; do [[ -f "$root/ready.json" ]] && break; sleep 0.02; done
port=$("$fixture_python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$root/ready.json")
print "SFTP fixture running: host 127.0.0.1  port $port  user fixture  password test-only-password"
print "Remote files: $root/files   (Ctrl-C stops the server and deletes everything)"
wait "$server_pid"
