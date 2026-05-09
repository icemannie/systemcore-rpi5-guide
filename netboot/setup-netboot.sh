#!/bin/bash
set -e

NETBOOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TFTP_DIR="${NETBOOT_DIR}/tftpboot"
NFSROOT_DIR="${NETBOOT_DIR}/nfsroot"
ROOTFS_IMG="${NETBOOT_DIR}/rootfs.img"

# Find the active LAN interface (WSL2 mirrored mode uses eth1, not eth0)
get_lan_ip() {
    local iface ip
    for iface in eth1 eth0 eth2; do
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [[ "$ip" != 169.254.* ]]; then
            echo "$ip"
            return
        fi
    done
    echo "ERROR: No LAN IP found" >&2
    exit 1
}

HOST_IP=$(get_lan_ip)
echo "=== SystemCore Pi 5 Network Boot Setup ==="
echo "Host IP: ${HOST_IP}"
echo "TFTP dir: ${TFTP_DIR}"
echo "NFS root: ${NFSROOT_DIR}"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root. Run with: sudo $0"
    exit 1
fi

# 1. Install required packages
echo "[1/6] Installing TFTP and NFS servers..."
apt-get update -qq
apt-get install -y -qq tftpd-hpa nfs-kernel-server

# 2. Load NFS kernel module (WSL2 has nfsd=m, needs explicit load)
echo "[2/6] Loading NFS kernel module..."
modprobe nfsd 2>/dev/null || true
if ! grep -q nfsd /proc/filesystems 2>/dev/null; then
    echo "  WARNING: nfsd module failed to load. NFS may not work."
    echo "  If this fails, try: wsl --shutdown from PowerShell, then relaunch."
fi

# 3. Mount rootfs image
echo "[3/6] Mounting rootfs image..."
mkdir -p "${NFSROOT_DIR}"
if mountpoint -q "${NFSROOT_DIR}" 2>/dev/null; then
    echo "  Already mounted"
else
    mount -o loop "${ROOTFS_IMG}" "${NFSROOT_DIR}"
    echo "  Mounted ${ROOTFS_IMG} at ${NFSROOT_DIR}"
fi

# 4. Configure TFTP
echo "[4/6] Configuring TFTP server..."
cat > /etc/default/tftpd-hpa << EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="${TFTP_DIR}"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --verbose"
EOF

# Update cmdline.txt with actual server IP for NFS root
sed -e "s|\${NFS_SERVER}|${HOST_IP}|" -e "s|\${NFS_ROOT}|${NFSROOT_DIR}|" "${NETBOOT_DIR}/cmdline_nfs.txt" > "${TFTP_DIR}/cmdline.txt"
echo "  cmdline.txt updated with NFS root at ${HOST_IP}"

# 5. Configure NFS
echo "[5/6] Configuring NFS server..."
EXPORT_LINE="${NFSROOT_DIR} *(rw,sync,no_subtree_check,no_root_squash)"
if ! grep -qF "${NFSROOT_DIR}" /etc/exports 2>/dev/null; then
    echo "${EXPORT_LINE}" >> /etc/exports
fi
exportfs -ra

# 6. Start services
echo "[6/6] Starting services..."
systemctl restart tftpd-hpa
systemctl restart nfs-kernel-server
systemctl enable tftpd-hpa
systemctl enable nfs-kernel-server

echo ""
echo "=== Setup Complete ==="
echo ""
echo "TFTP server: ${HOST_IP}:69 -> ${TFTP_DIR}"
echo "NFS export:  ${HOST_IP}:${NFSROOT_DIR}"
echo ""
echo "To verify NFS is working:"
echo "  showmount -e localhost"
echo "  rpcinfo -p"
echo ""
echo "=== Pi 5 EEPROM Configuration ==="
echo "On your Pi 5, run:"
echo "  sudo raspi-config"
echo "  -> Advanced Options -> Boot Order -> Network Boot"
echo ""
echo "Or manually edit the EEPROM:"
echo "  sudo rpi-eeprom-config --edit"
echo "  Set: BOOT_ORDER=0xf21  (SD, then network, then restart)"
echo "  Set: TFTP_PREFIX=0"
echo "  Set: NET_BOOT_MAX_RETRIES=5"
echo ""
echo "The Pi 5 will:"
echo "  1. Send a DHCP request to get an IP"
echo "  2. Download boot files from TFTP at ${HOST_IP}"
echo "  3. Mount rootfs over NFS from ${HOST_IP}:${NFSROOT_DIR}"
echo ""
echo "=== Restart After WSL Reboot ==="
echo "WSL2 doesn't persist services. After 'wsl --shutdown', re-run:"
echo "  sudo $0"
echo ""
echo "cmdline.txt for NFS boot:"
cat "${TFTP_DIR}/cmdline.txt"
