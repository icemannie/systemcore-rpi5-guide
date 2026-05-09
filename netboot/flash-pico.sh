#!/bin/bash
# flash-pico.sh - Flash any RP2350 Pico in BOOTSEL mode with SystemCore firmware
# Replaces picoflasherprocess which only flashes on the internal USB controller
# Uses dd to write UF2 blocks directly — the RP2350 bootloader processes them
# at the SCSI level, bypassing FAT filesystem buffering issues.

UF2_FILE="/usr/local/bin/picoflasherprocess/fw.uf2"
FLASHED=""

echo "=== Pico Flasher (external USB support) ==="
echo "Watching for Pico in bootloader mode..."

while true; do
    for dev in /dev/sd[a-z]; do
        [ -b "$dev" ] || continue

        vendor=$(udevadm info -q property -n "$dev" 2>/dev/null | grep "^ID_USB_VENDOR_ID=" | cut -d= -f2)
        [ "$vendor" = "2e8a" ] || continue

        serial=$(udevadm info -q property -n "$dev" 2>/dev/null | grep "^ID_SERIAL_SHORT=" | cut -d= -f2)
        echo "$FLASHED" | grep -q "$serial" 2>/dev/null && continue

        echo "Found Pico at $dev (serial: $serial)"
        dd if="$UF2_FILE" of="$dev" bs=512 2>/dev/null
        sync
        echo "Flashed $UF2_FILE to $dev"
        FLASHED="$FLASHED $serial"
        sleep 5
    done
    sleep 3
done
