#!/usr/bin/env python3
"""
Bidirectional TCP proxy: 127.0.0.1:PORT -> VM_NAME:22 via /usr/bin/nc.

packer-plugin-tart cannot reach bridge100 VMs from the GitHub Actions runner
process hierarchy (EHOSTUNREACH immediately, even though nc from an interactive
SSH session or bash subprocess can reach the same IP). /usr/bin/nc is a macOS
platform binary with implicit bridge100 routing access; Homebrew Python does not
have this access. This proxy accepts packer's SSH connection on loopback and
forwards it to the VM via an /usr/bin/nc subprocess.

Usage: python3 ssh_proxy.py <vm_name> [listen_port]
"""
import socket
import subprocess
import sys
import threading
import time

REAL_TART = "/opt/homebrew/bin/tart"
NC = "/usr/bin/nc"


def get_vm_ip(vm_name, timeout=120):
    start = time.time()
    while time.time() - start < timeout:
        try:
            r = subprocess.run(
                [REAL_TART, "ip", vm_name],
                capture_output=True, text=True, timeout=10,
            )
            ip = r.stdout.strip()
            if ip and "." in ip:
                return ip
        except Exception:
            pass
        time.sleep(2)
    return None


def handle(client, vm_name):
    vm_ip = get_vm_ip(vm_name)
    if not vm_ip:
        print(f"[proxy] FAIL: could not get IP for {vm_name}", flush=True)
        client.close()
        return

    print(f"[proxy] Connecting to {vm_ip}:22 via {NC}...", flush=True)
    try:
        proc = subprocess.Popen(
            [NC, vm_ip, "22"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"[proxy] FAIL: nc start failed for {vm_ip}:22: {e}", flush=True)
        client.close()
        return

    print(f"[proxy] PASS: nc connected to {vm_ip}:22", flush=True)

    def client_to_nc():
        try:
            while True:
                data = client.recv(4096)
                if not data:
                    break
                proc.stdin.write(data)
                proc.stdin.flush()
        except Exception:
            pass
        finally:
            try:
                proc.stdin.close()
            except Exception:
                pass

    def nc_to_client():
        try:
            while True:
                data = proc.stdout.read(4096)
                if not data:
                    break
                client.sendall(data)
        except Exception:
            pass
        finally:
            try:
                client.shutdown(socket.SHUT_WR)
            except Exception:
                pass

    t1 = threading.Thread(target=client_to_nc, daemon=True)
    t2 = threading.Thread(target=nc_to_client, daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    print(f"[proxy] Connection to {vm_ip}:22 closed", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <vm_name> [listen_port]")
        sys.exit(1)
    vm_name = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 2222
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(10)
    print(f"[proxy] Listening on 127.0.0.1:{port} -> {vm_name}:22", flush=True)
    while True:
        client, addr = srv.accept()
        threading.Thread(target=handle, args=(client, vm_name), daemon=True).start()
