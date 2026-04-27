#!/usr/bin/env python3
"""
Bidirectional TCP proxy: 127.0.0.1:PORT -> VM_NAME:22 via tart ip.

packer-plugin-tart cannot reach bridge100 VMs from the GitHub Actions runner
process hierarchy (EHOSTUNREACH immediately, even though nc from an interactive
SSH session can reach the same IP). This proxy runs from the runner's shell
subprocess and forwards packer's SSH connections through loopback, letting
packer use ssh_host=127.0.0.1 / ssh_port=2222 instead of the VM's direct IP.

Usage: python3 ssh_proxy.py <vm_name> [listen_port]
"""
import socket
import subprocess
import sys
import threading
import time


def get_vm_ip(vm_name, timeout=120):
    start = time.time()
    while time.time() - start < timeout:
        try:
            r = subprocess.run(
                ["/opt/homebrew/bin/tart", "ip", vm_name],
                capture_output=True, text=True, timeout=10,
            )
            ip = r.stdout.strip()
            if ip and "." in ip:
                return ip
        except Exception:
            pass
        time.sleep(2)
    return None


def pipe(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def handle(client, vm_name):
    vm_ip = get_vm_ip(vm_name)
    if not vm_ip:
        print(f"[proxy] FAIL: could not get IP for {vm_name}", flush=True)
        client.close()
        return
    print(f"[proxy] Connecting to {vm_ip}:22 ...", flush=True)
    try:
        server = socket.create_connection((vm_ip, 22), timeout=30)
        print(f"[proxy] PASS: connected to {vm_ip}:22", flush=True)
    except Exception as e:
        print(f"[proxy] FAIL: cannot connect to {vm_ip}:22: {e}", flush=True)
        client.close()
        return
    t1 = threading.Thread(target=pipe, args=(client, server), daemon=True)
    t2 = threading.Thread(target=pipe, args=(server, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    server.close()
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
