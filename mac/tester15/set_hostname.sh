#!/bin/bash
# This script sets a unique, stable hostname for CI macOS VMs
# using the last 3 octets of the primary MAC address.
# It only runs if the hostname isn't already set correctly.

set -e

# Get the primary network interface
PRIMARY_INTERFACE="en0"

# Fallback: try to detect the primary interface dynamically
if ! ifconfig "$PRIMARY_INTERFACE" &>/dev/null; then
    echo "⚠️ en0 not found, detecting primary interface..."
    PRIMARY_INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || echo "en0")
fi

# Extract the MAC address
MAC_ADDRESS=$(ifconfig "$PRIMARY_INTERFACE" 2>/dev/null | awk '/ether/{print $2}')
if [[ -z "$MAC_ADDRESS" ]]; then
    echo "❌ Could not determine MAC address for $PRIMARY_INTERFACE"
    exit 1
fi

# Generate short unique suffix from the MAC address
SHORT_MAC=$(echo "$MAC_ADDRESS" | awk -F: '{print $(NF-2)$(NF-1)$NF}')
HOSTNAME="mac-${SHORT_MAC}"

# Check current hostname
CURRENT_HOSTNAME=$(scutil --get HostName 2>/dev/null || echo "")

if [[ "$CURRENT_HOSTNAME" == "$HOSTNAME" ]]; then
    echo "✅ Hostname already set correctly: $CURRENT_HOSTNAME"
    # Still update config files in case they're stale
else
    echo "⚙️ Updating system hostname to $HOSTNAME..."
    
    # Apply hostname system-wide
    scutil --set ComputerName "$HOSTNAME"
    scutil --set LocalHostName "$HOSTNAME"
    scutil --set HostName "$HOSTNAME"
    
    # Flush caches and refresh Bonjour/mDNSResponder
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null || true
    
    echo "✅ New Hostname: $(scutil --get HostName)"
fi

# Update worker-runner-config.yaml
WORKER_CONFIG="/opt/worker/worker-runner-config.yaml"
if [[ -f "$WORKER_CONFIG" ]]; then
    echo "🛠️ Updating worker-runner-config.yaml..."
    
    # Use sed to replace the workerID in the YAML structure
    # Pattern matches: workerID: "old-hostname" and replaces with new hostname
    sudo sed -i.bak "s/workerID: \"[^\"]*\"/workerID: \"$HOSTNAME\"/g" "$WORKER_CONFIG"
    
    # Also update in the workerTypeMetadata section
    sudo sed -i '' "s/workerId: \"[^\"]*\"/workerId: \"$HOSTNAME\"/g" "$WORKER_CONFIG"
    
    echo "✅ Updated worker-runner-config.yaml"
else
    echo "⚠️ No worker-runner config found at $WORKER_CONFIG"
fi

# Update generic-worker.conf.yaml
GW_CONFIG="/opt/worker/generic-worker.conf.yaml"
if [[ -f "$GW_CONFIG" ]]; then
    echo "🛠️ Updating generic-worker.conf.yaml..."
    
    # Update JSON format config
    sudo sed -i.bak "s/\"workerId\": \"[^\"]*\"/\"workerId\": \"$HOSTNAME\"/g" "$GW_CONFIG"
    
    echo "✅ Updated generic-worker.conf.yaml"
else
    echo "⚠️ No generic-worker config found at $GW_CONFIG"
fi

echo "🏁 Hostname configuration complete."