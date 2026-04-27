#!/usr/bin/env python3
"""
Bidirectional TCP proxy: 127.0.0.1:PORT -> VM_NAME:22 via /usr/bin/nc.

packer-plugin-tart cannot reach bridge100 VMs from the GitHub Actions runner
process hierarchy (EHOSTUNREACH). /usr/bin/nc is a macOS platform binary with
implicit bridge100 routing access; Homebrew Python does not have it.

For each packer SSH connection, this proxy accepts on loopback, then spawns
/usr/bin/nc with the packer socket fd wired directly to nc's stdin/stdout.
nc handles all bidirectional I/O — no Python threading or pipe buffering.

Usage: python3 ssh_proxy.py <vm_name> [listen_port]
"""
import socket
import subprocess
import sys
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
        # Pass the packer socket fd directly to nc's stdin and stdout.
        # nc handles all bidirectional I/O between packer and the VM's sshd
        # without going through Python pipes — avoids buffering/threading issues.
        sock_fd = client.fileno()
        proc = subprocess.Popen(
            [NC, vm_ip, "22"],
            stdin=sock_fd,
            stdout=sock_fd,
            stderr=subprocess.DEVNULL,
        )
        print(f"[proxy] PASS: nc started for {vm_ip}:22 (pid={proc.pid})", flush=True)
        proc.wait()
        print(f"[proxy] Connection to {vm_ip}:22 closed (rc={proc.returncode})", flush=True)
    except Exception as e:
        print(f"[proxy] FAIL: {vm_ip}:22: {e}", flush=True)
    finally:
        client.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <vm_name> [listen_port]")
        sys.exit(1)
    vm_name = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 2222

    import threading

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(10)
    print(f"[proxy] Listening on 127.0.0.1:{port} -> {vm_name}:22", flush=True)
    while True:
        client, addr = srv.accept()
        threading.Thread(target=handle, args=(client, vm_name), daemon=True).start()
