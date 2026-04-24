#!/bin/bash
set -euo pipefail

# Spin up two gecko-1b builder VMs from the OCI registry.
# Run this on the Tart worker host (e.g. macmini-m4-116).

REGISTRY_HOST="${REGISTRY_HOST:-10.49.56.83}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
IMAGE="${IMAGE:-sequoia-gecko1b-vms}"
TAG="${TAG:-gecko1b-pr-19-latest}"
VM_COUNT=2
CPUS="${CPUS:-6}"
MEMORY_MB="${MEMORY_MB:-12288}"

REGISTRY="${REGISTRY_HOST}:${REGISTRY_PORT}"
REMOTE_REF="${REGISTRY}/${IMAGE}:${TAG}"

echo "=== gecko-1b VM Launcher ==="
echo "  Registry: ${REGISTRY}"
echo "  Image:    ${IMAGE}:${TAG}"
echo "  VMs:      ${VM_COUNT} (${CPUS} CPUs, ${MEMORY_MB}MB each)"
echo ""

# Pull the base image from OCI registry (overwrites any cached copy)
echo "--- Pulling ${REMOTE_REF} ---"
tart pull --insecure "${REMOTE_REF}" "${IMAGE}"

# Stop and delete existing VMs
for i in $(seq 1 $VM_COUNT); do
    VM_NAME="${IMAGE}-${i}"
    if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -Fxq "${VM_NAME}"; then
        echo "Stopping and deleting existing VM: ${VM_NAME}"
        tart stop "${VM_NAME}" 2>/dev/null || true
        sleep 2
        tart delete "${VM_NAME}"
    fi
done

# Clone and configure each VM
for i in $(seq 1 $VM_COUNT); do
    VM_NAME="${IMAGE}-${i}"
    echo "--- Cloning ${VM_NAME} ---"
    tart clone "${IMAGE}" "${VM_NAME}"
    tart set "${VM_NAME}" --cpu "${CPUS}" --memory "${MEMORY_MB}" --random-mac --random-serial
done

# Run all VMs headlessly in the background
for i in $(seq 1 $VM_COUNT); do
    VM_NAME="${IMAGE}-${i}"
    echo "--- Starting ${VM_NAME} ---"
    tart run --no-graphics "${VM_NAME}" &
done

# Disable sleep on each VM once SSH is available
for i in $(seq 1 $VM_COUNT); do
    VM_NAME="${IMAGE}-${i}"
    IP=$(tart ip "${VM_NAME}" --wait 120)
    echo "--- Disabling sleep on ${VM_NAME} (${IP}) ---"
    sshpass -p admin ssh \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        admin@"${IP}" "sudo pmset -a sleep 0 displaysleep 0 disksleep 0 womp 0"
done

echo ""
echo "VMs started. Check status with:"
echo "  tart list"
echo "  tart ip ${IMAGE}-1"
echo "  tart ip ${IMAGE}-2"
