# Raspberry Pi 3 Model B — Home Router Setup

Turns a Raspberry Pi 3B into a home network router using the built-in
WiFi as a LAN access point and the Ethernet port as the WAN uplink.

## Network Topology

```
ISP Modem ──[eth0]── RPi 3B ──[wlan0 AP]── Wireless Devices
                    192.168.1.1
```

| Interface | Role | Address |
|-----------|------|---------|
| eth0 | WAN — connects to modem | DHCP from ISP |
| wlan0 | LAN — WiFi access point | 192.168.1.1/24 |

DHCP hands out `192.168.1.50–192.168.1.200` to connected devices.

## Hardware Required

| Item | Notes |
|------|-------|
| Raspberry Pi 3 Model B | Already have |
| MicroSD card (16GB+ Class 10) | OS storage |
| 5V 2.5A USB power supply | Official RPi PSU recommended |
| Ethernet cable | Modem → RPi eth0 |

## Software

- **OS:** Raspberry Pi OS Lite 64-bit (Bookworm)
- **hostapd** — WiFi access point daemon
- **dnsmasq** — DHCP and DNS server
- **iptables-persistent** — persists NAT rules across reboots

## Setup

### 1. Flash the OS

Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/), flash
**Raspberry Pi OS Lite (64-bit)**, and enable SSH in the advanced options.

### 2. First boot

SSH into the Pi (`ssh pi@<ip>`) and update:

```bash
sudo apt update && sudo apt upgrade -y
```

### 3. Configure WiFi credentials

Edit `etc/hostapd/hostapd.conf` and set your SSID and password:

```
ssid=MyHomeNetwork
wpa_passphrase=ChangeThisPassword
```

### 4. Run the installer

```bash
sudo bash install.sh
```

### 5. Reboot

```bash
sudo reboot
```

## Verification

After reboot, from a device connected to your WiFi AP:

| Test | Command | Expected |
|------|---------|----------|
| Got DHCP address | `ip addr` | Address in 192.168.1.50–200 |
| Reach gateway | `ping 192.168.1.1` | Replies |
| Internet routing | `ping 8.8.8.8` | Replies |
| DNS works | `nslookup google.com` | Resolves |

On the Pi itself:
```bash
sudo iptables -t nat -L -n -v   # Should show MASQUERADE rule on eth0
systemctl status hostapd dnsmasq
```

## Files

```
pi-router/
  etc/
    sysctl.conf          — enables IP forwarding
    dhcpcd.conf          — static IP on wlan0
    dnsmasq.conf         — DHCP + DNS for LAN
    hostapd/
      hostapd.conf       — WiFi AP settings (edit SSID/password here)
    iptables/
      rules.v4           — NAT + forwarding rules
  iptables-rules.sh      — one-shot script to apply and save iptables rules
  install.sh             — copies files to /etc/ and enables services
```

## Adding Wired LAN Ports (Optional)

Plug a USB-to-Ethernet adapter into the Pi. It will appear as `eth1`.
Update `dnsmasq.conf` and `rules.v4` to also include `eth1` as a LAN interface,
then plug a switch into the adapter for wired device support.
