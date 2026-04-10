#!/bin/bash
# install.sh — Deploy pi-router config files to /etc/ and enable services
# Run as root on the Raspberry Pi: sudo bash install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root (sudo bash install.sh)" >&2
  exit 1
fi

echo "==> Installing packages..."
apt-get update -qq
apt-get install -y hostapd dnsmasq iptables-persistent

echo "==> Copying config files..."
cp "$SCRIPT_DIR/etc/sysctl.conf"            /etc/sysctl.conf
cp "$SCRIPT_DIR/etc/dhcpcd.conf"            /etc/dhcpcd.conf
cp "$SCRIPT_DIR/etc/dnsmasq.conf"           /etc/dnsmasq.conf
mkdir -p /etc/hostapd
cp "$SCRIPT_DIR/etc/hostapd/hostapd.conf"   /etc/hostapd/hostapd.conf
mkdir -p /etc/iptables
cp "$SCRIPT_DIR/etc/iptables/rules.v4"      /etc/iptables/rules.v4

echo "==> Pointing hostapd at its config..."
sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "==> Enabling IP forwarding..."
sysctl -p /etc/sysctl.conf

echo "==> Enabling and starting services..."
systemctl unmask hostapd
systemctl enable hostapd dnsmasq
systemctl restart hostapd dnsmasq

echo "==> Loading iptables rules..."
iptables-restore < /etc/iptables/rules.v4

echo ""
echo "Done! Reboot to confirm everything comes up cleanly:"
echo "  sudo reboot"
