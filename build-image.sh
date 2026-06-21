#!/bin/bash
set -euo pipefail

PI5B_VERSION="v1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLASH_PICO="${SCRIPT_DIR}/netboot/flash-pico.sh"
REGDB_DEB="${SCRIPT_DIR}/beta9/wireless-regdb_2025.10.07-0ubuntu1~24.04.1_all.deb"

IMAGE_URL="https://github.com/LimelightVision/systemcore-os-public/releases/download/limelightosr-release-10/limelightsystemcorebetacm5-limelightosr-beta-10.zip"
IMAGE_ZIP="${SCRIPT_DIR}/cache/limelightsystemcorebetacm5-limelightosr-beta-10.zip"
BUILD_IMG="${SCRIPT_DIR}/systemcore-pi5b-beta10.img"
OUTPUT_IMG="${SCRIPT_DIR}/systemcore-pi5b-beta10-${PI5B_VERSION}.img"

# Beta 10 partition layout:
#   p1: boot selector (FAT32, 16M)  — autoboot.txt, config.txt (empty)
#   p2: boot A (FAT32, 64M)         — config.txt, cmdline.txt -> rootfs p5
#   p3: boot B (FAT32, 64M)         — config.txt, cmdline.txt -> rootfs p6
#   p4: extended
#   p5: rootfs A (ext4, 7G)
#   p6: rootfs B (ext4, 7G)
BOOT_A_OFF=$((34816 * 512))
BOOT_B_OFF=$((165888 * 512))
ROOT_A_OFF=$((299008 * 512))
ROOT_B_OFF=$((14981120 * 512))

# --- Step 1: Preflight ---

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as the root (sudo $0)"
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
# NOTE: Upstream Beta 10+ ships a 16K-page kernel with matching userspace.
# We no longer replace the kernel — the stock one works on Pi 5B as-is.

mkdir -p "${SCRIPT_DIR}/cache"

if [ ! -f "$IMAGE_ZIP" ]; then
    echo "[1/5] Downloading upstream SystemCore Beta 10 image..."
    wget -c -O "$IMAGE_ZIP" "$IMAGE_URL"
else
    echo "[1/5] Upstream image already cached."
fi

# --- Step 3: Extract image ---

rm -f "$BUILD_IMG" "$OUTPUT_IMG"

echo "[2/5] Extracting image from zip..."
INNER_IMG=$(unzip -l "$IMAGE_ZIP" | grep -oP '\S+\.img$' | head -1)
if [ -z "$INNER_IMG" ]; then
    echo "ERROR: No .img file found inside zip"
    exit 1
fi
echo "  Found: $INNER_IMG"
unzip -p "$IMAGE_ZIP" "$INNER_IMG" > "$BUILD_IMG"
echo "  Extracted to: $BUILD_IMG ($(du -h "$BUILD_IMG" | cut -f1))"

# --- Step 3: Patch boot partitions (A and B) ---

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

    # Add panic=0 and wifi regdom to cmdline if not already present
    if ! grep -q "panic=" "$MNT/cmdline.txt"; then
        sed -i 's/$/ panic=0/' "$MNT/cmdline.txt"
    fi
    if ! grep -q "cfg80211" "$MNT/cmdline.txt"; then
        sed -i 's/$/ cfg80211.ieee80211_regdom=US/' "$MNT/cmdline.txt"
    fi

    echo "  [$LABEL] HDMI enabled, SPI CAN disabled, cmdline updated"
}

echo "[3/5] Patching boot partitions..."

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

# --- Step 4: Patch rootfs A and B ---

patch_rootfs() {
    local MNT="$1"
    local LABEL="$2"

    # Pico flasher
    cp "$FLASH_PICO" "$MNT/usr/local/bin/flash-pico.sh"
    chmod +x "$MNT/usr/local/bin/flash-pico.sh"

    mkdir -p "$MNT/etc/systemd/system/limelight_picoflasherprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_picoflasherprocess.service.d/override.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/flash-pico.sh
EOF
    echo "  [$LABEL] Installed flash-pico.sh + override"

    # CAN adapter support (multi-adapter, optional — graceful timeout)

    # Udev rule: trigger CAN service restart when USB-CAN adapter is plugged in.
    # SUBSYSTEMS=="usb" prevents the rule from matching vcan placeholders we
    # create from within the service itself — otherwise canbusprocess restarts
    # itself in an infinite loop the moment it adds a vcan.
    cat > "$MNT/etc/udev/rules.d/90-usb-can-rename.rules" << 'EOF'
SUBSYSTEM=="net", ACTION=="add", ATTR{type}=="280", SUBSYSTEMS=="usb", RUN+="/bin/systemctl restart limelight_canbusprocess.service"
EOF

    # canbusprocess: find, rename, and configure ALL CAN interfaces.
    # Keep in sync with patcher/resources/canbusprocess-override.conf
    mkdir -p "$MNT/etc/systemd/system/limelight_canbusprocess.service.d"
    cat > "$MNT/etc/systemd/system/limelight_canbusprocess.service.d/override.conf" << 'EOF'
# CAN bus mode is configurable per bus via /etc/can_bus_mode.
# Default: classic CAN at 1Mbps — works with every CAN device.
#
# Why not CAN FD by default: CTRE supports CAN FD on all current Phoenix 6
# devices (TalonFX, Kraken, CANcoder, Pigeon 2, CANdle, CANdi, CANrange,
# TalonFXS), but their FD implementation is built around the CANivore
# (their own USB-CAN adapter with an integrated CTRE-authored SocketCAN
# kernel driver). The generic candleLight-style gs_usb adapter we use here
# is exactly the "hobbyist-style SocketCAN-USB product" CTRE built the
# CANivore to replace — CTRE explicitly does not guarantee FD compatibility
# with it. On this rig (gs_usb + CANdle + Phoenix 6 alpha-2), FD at 1M/5M
# OR 1M/2M lets the kernel TX frames but the CANdle never acts on them.
# Likely causes (not yet bisected): ISO vs non-ISO CAN FD CRC mismatch,
# missing TDC at 2Mbps, or sample-point/SJW mismatch.
# Classic CAN works because CTRE classic-CAN compatibility predates and
# does not depend on the CANivore driver.
#
# Format: can_sN=<classic|fd> [bitrate] [dbitrate]
# If you opt into FD on a gs_usb adapter, verify per device after enabling
# — Phoenix Tuner discovering the device is NOT sufficient (kernel TX may
# climb while the device silently ignores everything).
# Use CTRE-standard FD timing (1Mbps nominal / 2Mbps data) — do NOT use
# 5Mbps data bitrate (bits too short for real transceivers to decode, bus
# immediately goes ERROR-PASSIVE).
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
  MAP=/etc/can_port_map; touch $MAP; \
  for dev in /sys/class/net/*/type; do \
    [ "$(cat $dev 2>/dev/null)" = "280" ] || continue; \
    IFACE=$(basename $(dirname $dev)); \
    [ -e "/sys/class/net/$IFACE/device/driver" ] || continue; \
    PORT=$(basename $(readlink -f /sys/class/net/$IFACE/device/.. 2>/dev/null)); \
    CAN_IDX=$(grep "^$PORT " $MAP 2>/dev/null | cut -d" " -f2); \
    if [ -z "$CAN_IDX" ]; then \
      MAX=$(cut -d" " -f2 $MAP 2>/dev/null | sort -n | tail -1); \
      [ -z "$MAX" ] && MAX=-1; \
      CAN_IDX=$((MAX + 1)); \
      echo "$PORT $CAN_IDX" >> $MAP; \
      echo "New port $PORT mapped to can_s$CAN_IDX"; \
    fi; \
    [ "$IFACE" = "can_s$CAN_IDX" ] && continue; \
    ip link set $IFACE down 2>/dev/null; \
    ip link set "can_s$CAN_IDX" down 2>/dev/null; \
    ip link set "can_s$CAN_IDX" name "_can_swap" 2>/dev/null; \
    ip link set $IFACE name "can_s$CAN_IDX" && echo "Renamed $IFACE -> can_s$CAN_IDX (USB port $PORT)"; \
    ip link set "_can_swap" name "$IFACE" 2>/dev/null; \
  done; \
  IFACES=$(ls -d /sys/class/net/can_s* 2>/dev/null | xargs -n1 basename); \
  FD_CFG=/etc/can_bus_mode; \
  if [ -n "$IFACES" ]; then \
    for iface in $IFACES; do \
      echo "Configuring $iface..."; \
      ip link set $iface down 2>/dev/null; \
      MODE_LINE=$(grep "^$iface=" $FD_CFG 2>/dev/null | head -1 | cut -d= -f2-); \
      MODE=$(echo $MODE_LINE | cut -d" " -f1); \
      BR=$(echo $MODE_LINE | cut -d" " -f2); \
      DBR=$(echo $MODE_LINE | cut -d" " -f3); \
      [ -z "$MODE" ] && MODE=fd; \
      [ -z "$BR" ] && BR=1000000; \
      [ -z "$DBR" ] && DBR=2000000; \
      if [ "$MODE" = "fd" ] && ip link set $iface type can bitrate $BR sample-point 0.875 dbitrate $DBR dsample-point 0.750 fd on 2>/dev/null; then \
        echo "$iface: CAN FD ($BR / $DBR)"; \
      elif [ "$MODE" = "fd" ] && ip link set $iface type can bitrate $BR fd off 2>/dev/null; then \
        echo "$iface: classic CAN ($BR) — FD requested but driver rejected"; \
      else \
        ip link set $iface type can bitrate $BR fd off 2>/dev/null; \
        echo "$iface: classic CAN ($BR)"; \
      fi; \
      ip link set $iface txqueuelen 1000; \
      ip link set $iface up; \
    done; \
    sleep 1; \
    for iface in $IFACES; do \
      cansend $iface 000#00 && echo "CAN discovery frame sent on $iface" || echo "cansend failed on $iface"; \
    done; \
  else \
    echo "No USB CAN adapters found after 30s"; \
  fi; \
  modprobe vcan 2>/dev/null; \
  for n in 0 1 2 3 4; do \
    [ -e "/sys/class/net/can_s$n" ] && continue; \
    ip link add dev can_s$n type vcan 2>/dev/null && ip link set can_s$n up 2>/dev/null && echo "Added vcan placeholder can_s$n (no physical adapter)"; \
  done; \
  COUNT=$(ls -d /sys/class/net/can_s* 2>/dev/null | wc -l); \
  echo "$COUNT total can_s* interfaces present (USB + vcan placeholders), monitoring..."; \
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

    # MrcCommDaemon directory.
    # On real SystemCore hardware, /dev/mrccan/ is created by a kernel module
    # specific to the carrier board. On Pi 5B that module doesn't exist, so
    # MrcCommDaemon crash-loops trying to create /dev/mrccan/controldata and
    # /dev/mrccan/matchinfo. Without MrcCommDaemon running, the HAL waits on
    # the NT key /Netcomm/Control/ServerReady, times out, and SIGABRTs ~10s
    # after the Java program starts ("Waiting for server ready failed").
    # systemd-tmpfiles creates the directory at boot, before mrccomm.service.
    mkdir -p "$MNT/etc/tmpfiles.d"
    cat > "$MNT/etc/tmpfiles.d/mrccan.conf" << 'EOF'
# /dev/mrccan is normally created by a SystemCore-only kernel module.
# On Pi 5B it must be created manually so MrcCommDaemon can open
# /dev/mrccan/controldata and /dev/mrccan/matchinfo.
d /dev/mrccan 0755 root root -
EOF
    echo "  [$LABEL] Created /dev/mrccan tmpfile (unblocks MrcCommDaemon)"

    # Wireless regulatory database
    if [ -f "$REGDB_DEB" ]; then
        REGDB_TMP=$(mktemp -d)
        dpkg-deb -x "$REGDB_DEB" "$REGDB_TMP"
        mkdir -p "$MNT/usr/lib/firmware"
        cp "$REGDB_TMP/lib/firmware/"* "$MNT/usr/lib/firmware/"
        rm -rf "$REGDB_TMP"
        echo "  [$LABEL] Installed wireless-regdb (regulatory.db)"
    fi

    # Unlock WLAN0 Access Point settings in dashboard
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

echo "[4/5] Patching rootfs A..."
ROOT_A_MNT=$(mktemp -d)
mount -o loop,offset=${ROOT_A_OFF} "$BUILD_IMG" "$ROOT_A_MNT"
patch_rootfs "$ROOT_A_MNT" "rootfs_a"
umount "$ROOT_A_MNT"
rmdir "$ROOT_A_MNT"

echo "[4/5] Patching rootfs B..."
ROOT_B_MNT=$(mktemp -d)
mount -o loop,offset=${ROOT_B_OFF} "$BUILD_IMG" "$ROOT_B_MNT"
patch_rootfs "$ROOT_B_MNT" "rootfs_b"
umount "$ROOT_B_MNT"
rmdir "$ROOT_B_MNT"

# --- Step 5: Done ---

mv "$BUILD_IMG" "$OUTPUT_IMG"

echo "[5/5] Done!"
echo ""
echo "============================================"
echo "  SystemCore Pi 5B image ready! (Beta 10 ${PI5B_VERSION})"
echo "============================================"
echo ""
echo "  Image:   $OUTPUT_IMG"
echo "  Size:    $(du -h "$OUTPUT_IMG" | cut -f1)"
echo ""
echo "  Patches applied:"
echo "    - HDMI output enabled"
echo "    - SPI CAN overlays disabled (no hardware on Pi 5B)"
echo "    - flash-pico.sh (auto-flashes RP2350 Pico on any USB port)"
echo "    - USB-CAN multi-adapter support (can_s0-s4, classic CAN 1Mbps by default; opt into CAN FD per-bus via /etc/can_bus_mode after verifying device support)"
echo "    - vcan placeholders auto-fill missing can_s0-s4 (HAL requires all 5)"
echo "    - CAN is optional (30s timeout, robot starts regardless)"
echo "    - Hot-plug: new adapters auto-named and configured"
echo "    - /dev/mrccan tmpfile (unblocks MrcCommDaemon -> robot.service)"
echo "    - Wireless regulatory database (US WiFi channels)"
echo ""
echo "  
echo ""