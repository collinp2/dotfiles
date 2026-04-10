#!/bin/bash
# iptables-rules.sh — Apply NAT/forwarding rules and save them
# Run once after initial setup. iptables-persistent will reload on boot.
# WAN = eth0, LAN = wlan0

set -e

echo "Flushing existing rules..."
iptables -F
iptables -t nat -F

echo "Applying forwarding rules..."
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

echo "Applying NAT masquerade..."
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

echo "Saving rules..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo "Done. Rules saved to /etc/iptables/rules.v4"
