#!/usr/bin/env python3
"""Persistent root-shell server for the NIKEM beacon (port 4444).
Accepts connections forever; logs everything to tvroot-app/out/tvshell-server.log.
To drive the live shell: write commands to /tmp/tvshell-cmd.txt (plain text)."""
import os, socket, threading, time

LOG = os.environ.get("TVSHELL_LOG", "tvshell-server.log")
CMD = "/tmp/tvshell-cmd.txt"

def log(b):
    with lock:
        open(LOG, "ab").write(b)

lock = threading.Lock()

def handle(c, addr):
    log(f"\n[CONNECTED {addr[0]} {time.strftime('%H:%M:%S')}]\n".encode())
    c.settimeout(0.5)
    last_traffic = time.time()
    try:
        while True:
            try:
                d = c.recv(65536)
                if not d:
                    break
                log(d)
                last_traffic = time.time()
            except socket.timeout:
                pass
            except OSError:
                break
            # keepalive: idle Wi-Fi/power-save kills the beacon socket in
            # minutes; a silent shell no-op (":") every 15 s keeps it warm
            if time.time() - last_traffic > 15:
                try:
                    c.sendall(b":\n")
                    log(b":")
                    last_traffic = time.time()
                except OSError:
                    break
            if os.path.exists(CMD):
                cmd = open(CMD, "rb").read()
                os.remove(CMD)
                try:
                    c.sendall(cmd.rstrip(b"\n") + b"\n")
                    log(b"\n[SENT] " + cmd + b"\n")
                    last_traffic = time.time()
                except OSError:
                    break
    finally:
        log(b"\n[DISCONNECTED]\n")
        try: c.close()
        except OSError: pass

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 4444))
s.listen(4)
log(f"[SERVER UP {time.strftime('%H:%M:%S')}]\n".encode())
while True:
    c, a = s.accept()
    threading.Thread(target=handle, args=(c, a), daemon=True).start()
