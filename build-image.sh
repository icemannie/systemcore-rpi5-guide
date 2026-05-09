#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${SCRIPT_DIR}/rpi-linux"
BOOT_DIR="${SCRIPT_DIR}/boot9"
FLASH_PICO="${SCRIPT_DIR}/netboot/flash-pico.sh"
REGDB_DEB="${SCRIPT_DIR}/beta9/wireless-regdb_2025.10.07-0ubuntu1~24.04.1_all.deb"

PI5B_VERSION="v2"

IMAGE_URL="https://github.com/LimelightVision/systemcore-os-public/releases/download/limelightosr-beta-9-12/limelightsystemcorebetacm5-limelightosr-beta-9.zip"
IMAGE_ZIP="${SCRIPT_DIR}/cache/limelightsystemcorebetacm5-limelightosr-beta-9.zip"
BUILD_IMG="${SCRIPT_DIR}/systemcore-pi5b-beta9.img"
OUTPUT_IMG="${SCRIPT_DIR}/systemcore-pi5b-beta9-${PI5B_VERSION}.img"

BOOT_OFF=$((1 * 512))
ROOT_A_OFF=$((131073 * 512))
ROOT_B_OFF=$((10616833 * 512))

# --- Step 1: Preflight ---

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo $0)"
    exit 1
fi

for cmd in wget unzip mount umount sed; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required tool not found: $cmd"
        exit 1
    fi
done

if [ ! -d "$BOOT_DIR" ]; then
    echo "ERROR: boot9/ directory not found"
    exit 1
fi
if [ ! -f "$FLASH_PICO" ]; then
    echo "ERROR: netboot/flash-pico.sh not found"
    exit 1
fi

echo "=== SystemCore Pi 5B Image Builder ==="
echo ""

# --- Step 2: Download upstream image ---

mkdir -p "${SCRIPT_DIR}/cache"

if [ ! -f "$IMAGE_ZIP" ]; then
    echo "[1/6] Downloading upstream SystemCore Beta 9 image (~1.6GB)..."
    wget -c -O "$IMAGE_ZIP" "$IMAGE_URL"
else
    echo "[1/6] Upstream image already cached."
fi

# --- Step 3: Extract image ---

rm -f "$BUILD_IMG" "$OUTPUT_IMG"

echo "[2/6] Extracting image from zip..."
INNER_IMG=$(unzip -l "$IMAGE_ZIP" | grep -oP '\S+\.img$' | head -1)
if [ -z "$INNER_IMG" ]; then
    echo "ERROR: No .img file found inside zip"
    exit 1
fi
echo "  Found: $INNER_IMG"
unzip -p "$IMAGE_ZIP" "$INNER_IMG" > "$BUILD_IMG"
echo "  Extracted to: $BUILD_IMG ($(du -h "$BUILD_IMG" | cut -f1))"

# --- Step 3: Build/validate 4K-page kernel ---

KERNEL_IMAGE="${KERNEL_DIR}/arch/arm64/boot/Image"

if [ ! -f "$KERNEL_IMAGE" ] || ! file "$KERNEL_IMAGE" | grep -q "4K pages"; then
    echo "[3/6] Building 4K-page kernel (15-30 minutes)..."
    "${SCRIPT_DIR}/build-kernel.sh"
else
    echo "[3/6] 4K-page kernel already built."
fi
echo "  Kernel: $(file "$KERNEL_IMAGE" | sed 's/.*: //')"

MODULES_STAGING="${SCRIPT_DIR}/cache/modules"
KVER=$(cat "${KERNEL_DIR}/include/config/kernel.release")
if [ ! -d "${MODULES_STAGING}/lib/modules/${KVER}/kernel" ]; then
    echo "  Installing kernel modules to staging..."
    make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
        INSTALL_MOD_PATH="$MODULES_STAGING" modules_install
fi
rm -f "${MODULES_STAGING}/lib/modules/${KVER}/build"
rm -f "${MODULES_STAGING}/lib/modules/${KVER}/source"
echo "  Modules staged: ${KVER} ($(du -sh "${MODULES_STAGING}/lib/modules/${KVER}" | cut -f1))"

# --- Step 4: Patch boot partition ---

echo "[4/6] Patching boot partition..."
BOOT_MNT=$(mktemp -d)
mount -o loop,offset=${BOOT_OFF} "$BUILD_IMG" "$BOOT_MNT"

cp "$BOOT_DIR/config.txt" "$BOOT_MNT/config.txt"
cp "$BOOT_DIR/cmdline.txt" "$BOOT_MNT/cmdline.txt"
cp "$BOOT_DIR/cmdline_b.txt" "$BOOT_MNT/cmdline_b.txt"
cp "$BOOT_DIR/autoboot.txt" "$BOOT_MNT/autoboot.txt"

# Enable HDMI output
sed -i 's/^hdmi_ignore_hotplug=1/#hdmi_ignore_hotplug=1/' "$BOOT_MNT/config.txt"
sed -i 's/^hdmi_ignore_edid=0xa5000080/#hdmi_ignore_edid=0xa5000080/' "$BOOT_MNT/config.txt"
sed -i 's/^hdmi_blanking=2/#hdmi_blanking=2/' "$BOOT_MNT/config.txt"
sed -i 's/^ignore_lcd=1/#ignore_lcd=1/' "$BOOT_MNT/config.txt"
sed -i 's/^display_auto_detect=0/display_auto_detect=1/' "$BOOT_MNT/config.txt"

# Comment out SPI CAN overlays (no SPI CAN hardware on Pi 5B)
sed -i '/^dtoverlay=spi[0-9]/s/^/#/' "$BOOT_MNT/config.txt"
sed -i '/^dtoverlay=sc-mcp2518/s/^/#/' "$BOOT_MNT/config.txt"

# Replace 16K-page kernel with our 4K-page build
cp "$KERNEL_IMAGE" "$BOOT_MNT/Image"
echo "  Installed 4K-page kernel"

# Install matching device trees and overlays
cp "$KERNEL_DIR"/arch/arm64/boot/dts/broadcom/bcm2712*.dtb "$BOOT_MNT/"
cp "$KERNEL_DIR"/arch/arm64/boot/dts/overlays/*.dtb* "$BOOT_MNT/overlays/" 2>/dev/null || true
echo "  Installed device trees and overlays"

echo "  Boot configs installed, HDMI enabled, SPI CAN disabled"

umount "$BOOT_MNT"
rmdir "$BOOT_MNT"

# --- Step 5: Patch rootfs A and B ---

patch_rootfs() {
    local MNT="$1"
    local LABEL="$2"

    # a) Pico flasher
    cp "$FLASH_PICO" "$MNT/usr/local/bin/flash-pico.sh"
    chmod +x "$MNT/usr/local/bin/flash-pico.sh"

    mkdir -p "$MNT/etc/systemd/system/limelight_picoflasherprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_picoflasherprocess.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/flash-pico.sh
EOF
    echo "  [$LABEL] Installed flash-pico.sh + override"

    # b) Kernel modules (matching our 4K-page kernel)
    if [ -d "${MODULES_STAGING}/lib/modules/${KVER}" ]; then
        mkdir -p "$MNT/usr/lib/modules"
        cp -a "${MODULES_STAGING}/lib/modules/${KVER}" "$MNT/usr/lib/modules/"
        echo "  [$LABEL] Installed kernel modules (${KVER})"
    fi

    # c) CAN adapter support (optional — graceful timeout)

    # Udev rule: rename ANY USB-CAN adapter to can_s0
    cat > "$MNT/etc/udev/rules.d/90-usb-can-rename.rules" << 'EOF'
SUBSYSTEM=="net", ACTION=="add", ATTR{type}=="280", NAME="can_s0"
EOF

    # canbusprocess: load gs_usb module, 30s timeout, clean exit if no adapter
    mkdir -p "$MNT/etc/systemd/system/limelight_canbusprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbusprocess.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/bin/bash -c '\
  modprobe gs_usb 2>/dev/null; \
  echo "Waiting for can_s0 (30s timeout)..."; \
  for i in $(seq 1 30); do \
    ip link show can_s0 >/dev/null 2>&1 && break; \
    sleep 1; \
  done; \
  if ! ip link show can_s0 >/dev/null 2>&1; then \
    echo "can_s0 not found after 30s, no CAN adapter present"; \
    exit 0; \
  fi; \
  echo "can_s0 found, configuring..."; \
  ip link set can_s0 down 2>/dev/null; \
  ip link set can_s0 type can bitrate 1000000; \
  ip link set can_s0 txqueuelen 1000; \
  ip link set can_s0 up; \
  echo "can_s0 up at 1Mbps"; \
  sleep infinity'
Restart=on-failure
RestartSec=10
EOF

    # canbuswatchdog: only watch can_s0, skip if not present
    mkdir -p "$MNT/etc/systemd/system/limelight_canbuswatchdog.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbuswatchdog.service.d/override.conf" << 'EOF'
[Service]
ExecStartPre=
ExecStartPre=/bin/bash -c 'for i in $(seq 1 10); do ip link show can_s0 >/dev/null 2>&1 && exit 0; sleep 1; done; echo "can_s0 not found, skipping watchdog"; exit 1'
ExecStart=
ExecStart=/usr/local/bin/canbuswatchdog/canbuswatchdog can_s0
Restart=on-failure
RestartSec=10
EOF

    # robot.service: wait for CAN but start regardless
    mkdir -p "$MNT/etc/systemd/system/robot.service.d"
    cat > "$MNT/etc/systemd/system/robot.service.d/override.conf" << 'EOF'
[Service]
ExecStartPre=
ExecStartPre=/bin/bash -c 'echo "Waiting for can_s0 (30s)..."; for i in $(seq 1 30); do ip link show can_s0 >/dev/null 2>&1 && exit 0; sleep 1; done; echo "can_s0 not found, starting robot anyway"; exit 0'
EOF
    echo "  [$LABEL] Installed CAN adapter support (optional, 30s timeout)"

    # e) Wireless regulatory database (extract to /usr/lib/firmware directly
    #    to avoid dpkg-deb -x destroying the /lib -> usr/lib symlink)
    if [ -f "$REGDB_DEB" ]; then
        REGDB_TMP=$(mktemp -d)
        dpkg-deb -x "$REGDB_DEB" "$REGDB_TMP"
        mkdir -p "$MNT/usr/lib/firmware"
        cp "$REGDB_TMP/lib/firmware/"* "$MNT/usr/lib/firmware/"
        rm -rf "$REGDB_TMP"
        echo "  [$LABEL] Installed wireless-regdb (regulatory.db)"
    fi
}

echo "[5/6] Patching rootfs A..."
ROOT_A_MNT=$(mktemp -d)
mount -o loop,offset=${ROOT_A_OFF} "$BUILD_IMG" "$ROOT_A_MNT"
patch_rootfs "$ROOT_A_MNT" "rootfs_a"
umount "$ROOT_A_MNT"
rmdir "$ROOT_A_MNT"

echo "[5/6] Patching rootfs B..."
ROOT_B_MNT=$(mktemp -d)
mount -o loop,offset=${ROOT_B_OFF} "$BUILD_IMG" "$ROOT_B_MNT"
patch_rootfs "$ROOT_B_MNT" "rootfs_b"
umount "$ROOT_B_MNT"
rmdir "$ROOT_B_MNT"

# --- Step 6: Done ---

mv "$BUILD_IMG" "$OUTPUT_IMG"

echo "[6/6] Done!"
echo ""
echo "============================================"
echo "  SystemCore Pi 5B image ready! (${PI5B_VERSION})"
echo "============================================"
echo ""
echo "  Image:   $OUTPUT_IMG"
echo "  Size:    $(du -h "$OUTPUT_IMG" | cut -f1)"
echo ""
echo "  Patches applied:"
echo "    - 4K-page kernel + modules (stock kernel is 16K, breaks Buildroot binaries)"
echo "    - HDMI output enabled"
echo "    - SPI CAN overlays disabled (no hardware on Pi 5B)"
echo "    - flash-pico.sh (auto-flashes RP2350 Pico on any USB port)"
echo "    - USB-CAN adapter support (any adapter, auto-configured at 1Mbps)"
echo "    - CAN is optional (30s timeout, robot starts regardless)"
echo "    - Wireless regulatory database (US WiFi channels)"
echo ""
echo "  Flash to SD card:"
echo "    sudo dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress"
echo ""
echo "  After flashing, just insert SD and power on the Pi 5."
echo "  No further configuration needed."
echo ""
