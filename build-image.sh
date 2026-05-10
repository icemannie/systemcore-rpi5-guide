#!/bin/bash
set -euo pipefail

PI5B_VERSION="v1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${SCRIPT_DIR}/rpi-linux"
FLASH_PICO="${SCRIPT_DIR}/netboot/flash-pico.sh"
REGDB_DEB="${SCRIPT_DIR}/beta9/wireless-regdb_2025.10.07-0ubuntu1~24.04.1_all.deb"

IMAGE_URL="https://github.com/LimelightVision/systemcore-os-public/releases/download/limelightosr-beta-10-139/limelightsystemcorebetacm5-limelightosr-beta-10.zip"
IMAGE_ZIP="${SCRIPT_DIR}/cache/limelightsystemcorebetacm5-limelightosr-beta-10.zip"
BUILD_IMG="${SCRIPT_DIR}/systemcore-pi5b-beta10.img"
OUTPUT_IMG="${SCRIPT_DIR}/systemcore-pi5b-beta10-${PI5B_VERSION}.img"

# Beta 10 partition layout:
#   p1: boot selector (FAT32, 16M)  — autoboot.txt, config.txt (empty)
#   p2: boot A (FAT32, 64M)         — kernel, DTBs, overlays, config.txt, cmdline.txt -> rootfs p5
#   p3: boot B (FAT32, 64M)         — kernel, DTBs, overlays, config.txt, cmdline.txt -> rootfs p6
#   p4: extended
#   p5: rootfs A (ext4, 7G)
#   p6: rootfs B (ext4, 7G)
BOOT_A_OFF=$((34816 * 512))
BOOT_B_OFF=$((165888 * 512))
ROOT_A_OFF=$((299008 * 512))
ROOT_B_OFF=$((14981120 * 512))

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

if [ ! -f "$FLASH_PICO" ]; then
    echo "ERROR: netboot/flash-pico.sh not found"
    exit 1
fi

echo "=== SystemCore Pi 5B Image Builder (Beta 10) ==="
echo ""

# --- Step 2: Download upstream image ---

mkdir -p "${SCRIPT_DIR}/cache"

if [ ! -f "$IMAGE_ZIP" ]; then
    echo "[1/6] Downloading upstream SystemCore Beta 10 image..."
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
    rm -rf "${MODULES_STAGING}"
    make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
        INSTALL_MOD_PATH="$MODULES_STAGING" modules_install
fi
rm -f "${MODULES_STAGING}/lib/modules/${KVER}/build"
rm -f "${MODULES_STAGING}/lib/modules/${KVER}/source"
echo "  Modules staged: ${KVER} ($(du -sh "${MODULES_STAGING}/lib/modules/${KVER}" | cut -f1))"

# --- Step 4: Patch boot partitions (A and B) ---

patch_boot() {
    local MNT="$1"
    local LABEL="$2"

    # Enable HDMI output
    sed -i 's/^hdmi_ignore_hotplug=1/#hdmi_ignore_hotplug=1/' "$MNT/config.txt"
    sed -i 's/^hdmi_ignore_edid=0xa5000080/#hdmi_ignore_edid=0xa5000080/' "$MNT/config.txt"
    sed -i 's/^hdmi_blanking=2/#hdmi_blanking=2/' "$MNT/config.txt"
    sed -i 's/^ignore_lcd=1/#ignore_lcd=1/' "$MNT/config.txt"
    sed -i 's/^display_auto_detect=0/display_auto_detect=1/' "$MNT/config.txt"

    # Comment out SPI CAN overlays (no SPI CAN hardware on Pi 5B)
    sed -i '/^dtoverlay=spi[0-9]/s/^/#/' "$MNT/config.txt"
    sed -i '/^dtoverlay=sc-mcp2518/s/^/#/' "$MNT/config.txt"

    # Replace 16K-page kernel with our 4K-page build
    cp "$KERNEL_IMAGE" "$MNT/Image"

    # Install matching device trees and overlays
    cp "$KERNEL_DIR"/arch/arm64/boot/dts/broadcom/bcm2712*.dtb "$MNT/"
    cp "$KERNEL_DIR"/arch/arm64/boot/dts/overlays/*.dtb* "$MNT/overlays/" 2>/dev/null || true

    # Add panic=0 and wifi regdom to cmdline if not already present
    if ! grep -q "panic=" "$MNT/cmdline.txt"; then
        sed -i 's/$/ panic=0/' "$MNT/cmdline.txt"
    fi
    if ! grep -q "cfg80211" "$MNT/cmdline.txt"; then
        sed -i 's/$/ cfg80211.ieee80211_regdom=US/' "$MNT/cmdline.txt"
    fi

    echo "  [$LABEL] Kernel, DTBs, HDMI enabled, SPI CAN disabled"
}

echo "[4/6] Patching boot partitions..."

BOOT_A_MNT=$(mktemp -d)
mount -o loop,offset=${BOOT_A_OFF} "$BUILD_IMG" "$BOOT_A_MNT"
patch_boot "$BOOT_A_MNT" "boot_a"
umount "$BOOT_A_MNT"
rmdir "$BOOT_A_MNT"

BOOT_B_MNT=$(mktemp -d)
mount -o loop,offset=${BOOT_B_OFF} "$BUILD_IMG" "$BOOT_B_MNT"
patch_boot "$BOOT_B_MNT" "boot_b"
umount "$BOOT_B_MNT"
rmdir "$BOOT_B_MNT"

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

    # c) CAN adapter support (multi-adapter, optional — graceful timeout)

    # Udev rule: trigger CAN service restart when USB-CAN adapter is plugged in
    cat > "$MNT/etc/udev/rules.d/90-usb-can-rename.rules" << 'EOF'
SUBSYSTEM=="net", ACTION=="add", ATTR{type}=="280", RUN+="/bin/systemctl restart limelight_canbusprocess.service"
EOF

    # canbusprocess: find, rename, and configure ALL CAN interfaces
    mkdir -p "$MNT/etc/systemd/system/limelight_canbusprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbusprocess.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/bin/bash -c '\
  modprobe gs_usb 2>/dev/null; \
  for dev in /sys/class/net/can_s*/type; do \
    IFACE=$(basename $(dirname $dev)); \
    [ -e "/sys/class/net/$IFACE/device/driver" ] || ip link delete $IFACE 2>/dev/null; \
  done; \
  echo "Waiting for CAN adapters (30s timeout)..."; \
  for i in $(seq 1 30); do \
    for dev in /sys/class/net/*/type; do \
      [ "$(cat $dev 2>/dev/null)" = "280" ] && break 2; \
    done; \
    sleep 1; \
  done; \
  NEXT=0; \
  for dev in /sys/class/net/*/type; do \
    [ "$(cat $dev 2>/dev/null)" = "280" ] || continue; \
    IFACE=$(basename $(dirname $dev)); \
    case $IFACE in can_s[0-9]*) continue ;; esac; \
    while [ -d "/sys/class/net/can_s$NEXT" ]; do NEXT=$((NEXT+1)); done; \
    ip link set $IFACE down 2>/dev/null; \
    ip link set $IFACE name "can_s$NEXT" && echo "Renamed $IFACE -> can_s$NEXT"; \
    NEXT=$((NEXT+1)); \
  done; \
  IFACES=$(ls -d /sys/class/net/can_s* 2>/dev/null | xargs -n1 basename); \
  if [ -z "$IFACES" ]; then \
    echo "No CAN adapters found after 30s"; \
    exit 0; \
  fi; \
  for iface in $IFACES; do \
    echo "Configuring $iface..."; \
    ip link set $iface down 2>/dev/null; \
    if ip link set $iface type can bitrate 1000000 dbitrate 5000000 fd on 2>/dev/null; then \
      echo "$iface: CAN FD (1Mbps/5Mbps)"; \
    else \
      ip link set $iface type can bitrate 1000000 2>/dev/null; \
      echo "$iface: standard CAN (1Mbps)"; \
    fi; \
    ip link set $iface txqueuelen 1000; \
    ip link set $iface up; \
  done; \
  sleep 1; \
  for iface in $IFACES; do \
    cansend $iface 000#00 && echo "CAN discovery frame sent on $iface" || echo "cansend failed on $iface"; \
  done; \
  COUNT=$(echo "$IFACES" | wc -w); \
  echo "$COUNT CAN adapter(s) configured, monitoring..."; \
  while [ "$(ls -d /sys/class/net/can_s* 2>/dev/null | wc -l)" -ge "$COUNT" ]; do sleep 2; done; \
  echo "CAN adapter change detected, restarting..."'
Restart=always
RestartSec=3
EOF

    # canbuswatchdog: watch first available can_s* interface
    mkdir -p "$MNT/etc/systemd/system/limelight_canbuswatchdog.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbuswatchdog.service.d/override.conf" << 'EOF'
[Service]
ExecStartPre=
ExecStartPre=/bin/bash -c 'for i in $(seq 1 10); do ls /sys/class/net/can_s* >/dev/null 2>&1 && exit 0; sleep 1; done; echo "No CAN adapters found, skipping watchdog"; exit 1'
ExecStart=
ExecStart=/bin/bash -c 'IFACE=$(ls -d /sys/class/net/can_s* 2>/dev/null | head -1 | xargs basename); exec /usr/local/bin/canbuswatchdog/canbuswatchdog $IFACE'
Restart=on-failure
RestartSec=10
EOF

    # robot.service: wait for any CAN adapter but start regardless
    mkdir -p "$MNT/etc/systemd/system/robot.service.d"
    cat > "$MNT/etc/systemd/system/robot.service.d/override.conf" << 'EOF'
[Service]
ExecStartPre=
ExecStartPre=/bin/bash -c 'echo "Waiting for CAN adapters (30s)..."; for i in $(seq 1 30); do ls /sys/class/net/can_s* >/dev/null 2>&1 && exit 0; sleep 1; done; echo "No CAN adapters found, starting robot anyway"; exit 0'
EOF
    echo "  [$LABEL] Installed multi-adapter CAN FD support (optional, 30s timeout)"

    # d) Wireless regulatory database
    if [ -f "$REGDB_DEB" ]; then
        REGDB_TMP=$(mktemp -d)
        dpkg-deb -x "$REGDB_DEB" "$REGDB_TMP"
        mkdir -p "$MNT/usr/lib/firmware"
        cp "$REGDB_TMP/lib/firmware/"* "$MNT/usr/lib/firmware/"
        rm -rf "$REGDB_TMP"
        echo "  [$LABEL] Installed wireless-regdb (regulatory.db)"
    fi

    # e) Unlock WLAN0 Access Point settings in dashboard
    local DASHBOARD_JS=$(find "$MNT/var/www/html/static/js" -name 'main.*.js' 2>/dev/null | head -1)
    if [ -n "$DASHBOARD_JS" ]; then
        # Unlock wlan0 fields (disabled:o||a -> disabled:o where a="wlan0"===e)
        sed -i 's/disabled:o||a/disabled:o/g' "$DASHBOARD_JS"
        # Remove forced wlan0 overrides on save (let user-entered values persist)
        sed -i 's/,{static_ip:"172\.30\.0\.1",gateway:"172\.30\.0\.1",use_dhcp:!1}/,{}/g' "$DASHBOARD_JS"
        echo "  [$LABEL] Unlocked WLAN0 AP settings in dashboard"

        # Add fault count reset button to header fault tooltip
        sed -i 's/faultCounts:t\.fc||\[0,0,0,0,0,0\]/faultCounts:(window.__rawFC=t.fc||[0,0,0,0,0,0]).map(function(v,j){return Math.max(0,v-((window.__faultBL||[])[j]||0))})/g' "$DASHBOARD_JS"
        sed -i 's/"historical-"\.concat(t))}))\]/"historical-".concat(t))})),\(0,xo.jsx\)("div",{style:{marginTop:"8px",textAlign:"center"},children:\(0,xo.jsx\)("button",{onClick:function(){window.__faultBL=window.__rawFC?window.__rawFC.slice():[]},style:{fontSize:"11px",padding:"2px 8px",cursor:"pointer",background:"#333",color:"#fff",border:"1px solid #666",borderRadius:"3px"},children:"Reset Fault Counts"}\)}\)]/g' "$DASHBOARD_JS"
        echo "  [$LABEL] Added fault count reset button"
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
echo "  SystemCore Pi 5B image ready! (Beta 10 ${PI5B_VERSION})"
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
echo "    - USB-CAN multi-adapter support (can_s0-s4, CAN FD 1Mbps/5Mbps)"
echo "    - CAN is optional (30s timeout, robot starts regardless)"
echo "    - Hot-plug: new adapters auto-named and configured"
echo "    - Wireless regulatory database (US WiFi channels)"
echo ""
echo "  Flash to SD card:"
echo "    sudo dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress"
echo ""
echo "  After flashing, just insert SD and power on the Pi 5."
echo "  No further configuration needed."
echo ""
