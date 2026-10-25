#!/usr/bin/env python3
"""Disposable loopback-only SFTP fixture. Never reads personal keys or directories."""
import argparse
import errno
import json
import os
from pathlib import Path
import socket
import threading
import time
import paramiko

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True)
parser.add_argument('--host-key', required=True)
parser.add_argument('--allowed-key', action='append', default=[])
parser.add_argument('--ready', required=True)
parser.add_argument('--events', required=True)
parser.add_argument('--weak', action='store_true')
args = parser.parse_args()
root = Path(args.root).resolve()
root.mkdir(parents=True, exist_ok=True)
events_lock = threading.Lock()
allowed = [Path(p).read_text().split()[1] for p in args.allowed_key]

def event(name):
    with events_lock:
        with open(args.events, 'a') as out:
            out.write(name + '\n')

class Auth(paramiko.ServerInterface):
    def get_allowed_auths(self, user):
        return 'publickey,password'
    def check_auth_password(self, user, password):
        event('password-auth')
        return paramiko.AUTH_SUCCESSFUL if user == 'fixture' and password == 'test-only-password' else paramiko.AUTH_FAILED
    def check_auth_publickey(self, user, key):
        event('key-auth')
        return paramiko.AUTH_SUCCESSFUL if user == 'fixture' and key.get_base64() in allowed else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, channel):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_forward_agent_request(self, channel):
        event('FORBIDDEN-AGENT-FORWARDING')
        return False

class Handle(paramiko.SFTPHandle):
    def __init__(self, fd, path, flags, transport):
        super().__init__(flags); self.fd = fd; self.path = path; self.transport = transport
    def stat(self):
        attributes = paramiko.SFTPAttributes.from_stat(os.fstat(self.fd))
        if self.path.name == 'misreported.bin': attributes.st_size = 1
        return attributes
    def read(self, offset, length):
        if self.path.name == 'stall.bin':
            time.sleep(3)
        if self.path.name == 'changing.bin' and offset >= 65536:
            os.utime(self.path, (time.time() + 10, time.time() + 10))
        if self.path.name == 'disconnect.bin' and offset >= 65536:
            self.transport.close(); return paramiko.SFTP_FAILURE
        try:
            return os.pread(self.fd, length, offset)
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    def write(self, offset, data):
        try:
            os.pwrite(self.fd, data, offset); return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    def close(self):
        os.close(self.fd); return paramiko.SFTP_OK

class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *a, **kw):
        super().__init__(server, *a, **kw)
    def path(self, remote):
        candidate = (root / remote.lstrip('/')).resolve()
        if candidate != root and root not in candidate.parents:
            raise OSError(errno.EACCES, 'Outside fixture')
        return candidate
    def list_folder(self, path):
        try:
            if path == '/denied':
                return paramiko.SFTP_PERMISSION_DENIED
            entries = []
            for child in self.path(path).iterdir():
                a = paramiko.SFTPAttributes.from_stat(child.lstat()); a.filename = child.name; entries.append(a)
            return entries
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    def stat(self, path):
        try: return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def lstat(self, path):
        try:
            # Preserve link metadata without following the final component.
            target = self.path(str(Path(path).parent)) / Path(path).name
            if target.name == 'race-download.txt': (root / 'local-race.txt').write_bytes(b'race-winner')
            attributes = paramiko.SFTPAttributes.from_stat(target.lstat())
            if target.name == 'misreported.bin': attributes.st_size = 1
            return attributes
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def open(self, path, flags, attr):
        event('open')
        try:
            target = self.path(path)
            if target.name == 'race-upload.txt': target.write_bytes(b'race-winner')
            fd = os.open(target, flags | os.O_NOFOLLOW, 0o600)
            return Handle(fd, target, flags, self.server_transport)
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def mkdir(self, path, attr):
        try: os.mkdir(self.path(path), 0o700); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def rename(self, old, new):
        import ctypes
        try:
            source = self.path(old); target = self.path(new)
            if source.name == 'unsupported-rename': return paramiko.SFTP_OP_UNSUPPORTED
            libc = ctypes.CDLL(None, use_errno=True)
            rename = libc.renamex_np; rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            if rename(os.fsencode(source), os.fsencode(target), 4):
                return paramiko.SFTPServer.convert_errno(ctypes.get_errno())
            return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)

host_key = paramiko.PKey.from_path(args.host_key)
listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 0)); listener.listen(8)
Path(args.ready).write_text(json.dumps({'port': listener.getsockname()[1], 'pid': os.getpid()}))

def serve(client):
    transport = paramiko.Transport(client)
    if args.weak: transport.get_security_options().ciphers = ('aes128-cbc',)
    transport.add_server_key(host_key)
    class BoundFiles(Files):
        server_transport = transport
    transport.set_subsystem_handler('sftp', paramiko.SFTPServer, BoundFiles)
    try:
        transport.start_server(server=Auth())
        while transport.is_active(): time.sleep(0.1)
    except Exception:
        # Do not log protocol payloads, credentials, or server-controlled messages.
        event('connection-ended')
    finally:
        transport.close()
while True:
    client, _ = listener.accept()
    threading.Thread(target=serve, args=(client,), daemon=True).start()
