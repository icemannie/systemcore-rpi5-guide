#!/bin/bash
set -e

IMG="/home/tfox/systemcore-rpi5-guide/beta9/systemcore-beta9-pi5-patched.img"
BOOT_DIR="/home/tfox/systemcore-rpi5-guide/boot9"
BOOT_MNT=$(mktemp -d)
ROOT_A_MNT=$(mktemp -d)
ROOT_B_MNT=$(mktemp -d)

# Partition offsets (sector * 512)
BOOT_OFF=$((1 * 512))
ROOT_A_OFF=$((131073 * 512))
ROOT_B_OFF=$((10616833 * 512))

echo "=== Patching systemcore-beta9-pi5-patched.img ==="
echo ""

# 1. Mount boot partition and apply boot config fixes
echo "[1/4] Patching boot partition..."
mount -o loop,offset=${BOOT_OFF} "$IMG" "$BOOT_MNT"

cp "$BOOT_DIR/config.txt" "$BOOT_MNT/config.txt"
cp "$BOOT_DIR/cmdline.txt" "$BOOT_MNT/cmdline.txt"
cp "$BOOT_DIR/cmdline_b.txt" "$BOOT_MNT/cmdline_b.txt"
cp "$BOOT_DIR/autoboot.txt" "$BOOT_MNT/autoboot.txt"

# Fix HDMI output for debugging
sed -i 's/^hdmi_ignore_hotplug=1/#hdmi_ignore_hotplug=1/' "$BOOT_MNT/config.txt"
sed -i 's/^hdmi_ignore_edid=0xa5000080/#hdmi_ignore_edid=0xa5000080/' "$BOOT_MNT/config.txt"
sed -i 's/^hdmi_blanking=2/#hdmi_blanking=2/' "$BOOT_MNT/config.txt"
sed -i 's/^ignore_lcd=1/#ignore_lcd=1/' "$BOOT_MNT/config.txt"
sed -i 's/^display_auto_detect=0/display_auto_detect=1/' "$BOOT_MNT/config.txt"

echo "  Boot configs copied and HDMI enabled"
umount "$BOOT_MNT"

FLASH_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/netboot/flash-pico.sh"

patch_rootfs() {
    local MNT="$1"
    local LABEL="$2"

    # Install replacement flash script
    cp "$FLASH_SCRIPT" "$MNT/usr/local/bin/flash-pico.sh"
    chmod +x "$MNT/usr/local/bin/flash-pico.sh"
    echo "  Installed flash-pico.sh"

    # Create systemd override to use our script instead of picoflasherprocess
    mkdir -p "$MNT/etc/systemd/system/limelight_picoflasherprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_picoflasherprocess.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/flash-pico.sh
EOF
    echo "  Created picoflasherprocess override for $LABEL"

    # Udev rule: rename candleLight USB-CAN adapter to can_s0
    cat > "$MNT/etc/udev/rules.d/90-canbus-rename.rules" << 'EOF'
SUBSYSTEM=="net", ACTION=="add", ATTR{type}=="280", DRIVERS=="gs_usb", NAME="can_s0"
EOF
    echo "  Installed CAN adapter udev rule"

    # canbusprocess override: wait for can_s0, configure 1Mbps, auto-recover
    mkdir -p "$MNT/etc/systemd/system/limelight_canbusprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbusprocess.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/bin/bash -c 'echo "Waiting for can_s0..."; while ! ip link show can_s0 >/dev/null 2>&1; do sleep 1; done; echo "can_s0 found"; ip link set can_s0 down 2>/dev/null; ip link set can_s0 type can bitrate 1000000; ip link set can_s0 txqueuelen 1000; ip link set can_s0 up; echo "can_s0 is up at 1Mbps"; sleep infinity'
Restart=on-failure
RestartSec=3
EOF
    echo "  Created canbusprocess override for $LABEL"

    # canbuswatchdog override: watch can_s0 only
    mkdir -p "$MNT/etc/systemd/system/limelight_canbuswatchdog.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbuswatchdog.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/canbuswatchdog/canbuswatchdog can_s0
EOF
    echo "  Created canbuswatchdog override for $LABEL"

    # robot.service override: only wait for can_s0
    mkdir -p "$MNT/etc/systemd/system/robot.service.d"
    cat > "$MNT/etc/systemd/system/robot.service.d/override.conf" << 'EOF'
[Service]
ExecStartPre=
ExecStartPre=/bin/bash -c 'echo "Waiting for can_s0..."; for i in $(seq 1 30); do ip link show can_s0 >/dev/null 2>&1 && exit 0; sleep 1; done; echo "can_s0 not found after 30s, continuing anyway"; exit 0'
EOF
    echo "  Created robot.service override for $LABEL"
}

# 2. Patch rootfs A
echo "[2/4] Patching rootfs A (flash-pico.sh + HDMI)..."
mount -o loop,offset=${ROOT_A_OFF} "$IMG" "$ROOT_A_MNT"
patch_rootfs "$ROOT_A_MNT" "rootfs A"
umount "$ROOT_A_MNT"

# 3. Patch rootfs B
echo "[3/4] Patching rootfs B (flash-pico.sh)..."
mount -o loop,offset=${ROOT_B_OFF} "$IMG" "$ROOT_B_MNT"
patch_rootfs "$ROOT_B_MNT" "rootfs B"
umount "$ROOT_B_MNT"

# 4. Cleanup
echo "[4/4] Cleaning up..."
rmdir "$BOOT_MNT" "$ROOT_A_MNT" "$ROOT_B_MNT"

echo ""
echo "=== Done ==="
echo "Patched image: $IMG"
echo ""
echo "Changes applied:"
echo "  - Boot configs from boot9/ (cmdline.txt, config.txt, etc.)"
echo "  - HDMI output enabled (hdmi_ignore_hotplug, hdmi_blanking disabled)"
echo "  - flash-pico.sh installed on both rootfs A and B"
echo "    (replaces picoflasherprocess via systemd override)"
echo "    (flashes any RP2350/RP2040 Pico on any USB port)"
echo "  - CAN adapter support (udev rename, canbusprocess, canbuswatchdog, robot.service)"
echo "    (candleLight/gs_usb adapter auto-configured as can_s0 at 1Mbps)"
echo ""
echo "Flash with:"
echo "  dd if=$IMG of=/dev/sdX bs=4M status=progress"
