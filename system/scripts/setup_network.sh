#!/bin/bash
# Limelight 3 - Quick Network Driver Setup
# Run this on the device if ethernet is not working after first boot.
# Requires a working network connection (e.g., USB tethering or WiFi).
#
# Usage: sudo bash setup_network.sh

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash setup_network.sh"
  exit 1
fi

echo "=== Limelight 3 Network Driver Setup ==="

# Load the r8152 kernel module (Realtek RTL8152/RTL8153 USB ethernet)
echo "Loading r8152 kernel module..."
modprobe r8152 2>/dev/null && echo "  r8152 module loaded" || echo "  r8152 module not available in kernel"

# Persist module loading across reboots
echo "Persisting module loading..."
mkdir -p /etc/modules-load.d
echo "r8152" > /etc/modules-load.d/usb-ethernet.conf

# Install firmware if we have internet access
if ping -c1 -W2 8.8.8.8 &>/dev/null; then
  echo "Internet detected - installing Realtek firmware package..."
  apt-get update -qq
  apt-get install -y --no-install-recommends firmware-realtek 2>&1 | tail -3
  echo "  firmware-realtek installed"
else
  echo "  No internet - skipping firmware-realtek installation"
  echo "  Connect to internet and re-run this script to install firmware"
fi

# Install udev rule for consistent interface naming
RULES_SRC="$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)/../config/70-limelight-ethernet.rules"
if [ -f "$RULES_SRC" ]; then
  cp "$RULES_SRC" /etc/udev/rules.d/
  echo "  udev rule installed"
elif [ ! -f /etc/udev/rules.d/70-limelight-ethernet.rules ]; then
  cat > /etc/udev/rules.d/70-limelight-ethernet.rules << 'UDEV'
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="r8152", NAME="eth0"
UDEV
  echo "  udev rule created"
fi
udevadm control --reload-rules 2>/dev/null || true

# Ensure DHCP is configured for eth0
mkdir -p /etc/network/interfaces.d
if [ ! -f /etc/network/interfaces.d/eth0 ]; then
  cat > /etc/network/interfaces.d/eth0 << 'NET'
auto eth0
iface eth0 inet dhcp
NET
  echo "  eth0 DHCP config created"
fi

# Bring up the interface
echo "Bringing up eth0..."
ip link set eth0 up 2>/dev/null || true
dhcpcd eth0 2>/dev/null || dhclient eth0 2>/dev/null || true

# Check status
echo ""
echo "=== Network Status ==="
ip addr show eth0 2>/dev/null || echo "eth0 not found - try rebooting"
echo ""
echo "If eth0 is not showing an IP address, try: sudo reboot"
echo "=== Done ==="
