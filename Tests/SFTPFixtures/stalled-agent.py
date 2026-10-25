#!/usr/bin/env python3
"""A disposable local agent that accepts a connection but never replies."""
import socket
import sys
import time
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(sys.argv[1]); listener.listen(1)
client, _ = listener.accept()
time.sleep(30)
client.close(); listener.close()
