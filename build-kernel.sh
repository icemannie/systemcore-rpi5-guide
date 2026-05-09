#!/bin/bash
set -e

KERNEL_BRANCH="rpi-6.6.y"
KERNEL_DIR="rpi-linux"
NPROC=$(nproc)
OUTPUT_DIR="output"

echo "=== SystemCore Pi 5 Kernel Builder ==="
echo "Branch: ${KERNEL_BRANCH}"
echo "Cores:  ${NPROC}"
echo ""

# Install dependencies
echo "[1/6] Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    flex bison libssl-dev libncurses-dev \
    bc kmod cpio git

# Clone kernel source
if [ -d "${KERNEL_DIR}" ]; then
    echo "[2/6] Kernel source already exists, skipping clone."
else
    echo "[2/6] Cloning Raspberry Pi kernel (${KERNEL_BRANCH})..."
    git clone --depth=1 --branch "${KERNEL_BRANCH}" \
        https://github.com/raspberrypi/linux.git "${KERNEL_DIR}"
fi

cd "${KERNEL_DIR}"

# Configure for Pi 5 (BCM2712)
echo "[3/6] Configuring kernel (bcm2712_defconfig)..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2712_defconfig

# Switch from 16K pages to 4K pages (required for SystemCore binaries)
echo "[4/6] Switching to 4K pages for SystemCore compatibility..."
scripts/config --disable ARM64_16K_PAGES --enable ARM64_4K_PAGES
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# Verify page size
PAGE_SHIFT=$(grep "^CONFIG_ARM64_PAGE_SHIFT=" .config | cut -d= -f2)
if [ "${PAGE_SHIFT}" != "12" ]; then
    echo "ERROR: Page shift is ${PAGE_SHIFT}, expected 12 (4K pages)"
    exit 1
fi
echo "    Page size: 4K (PAGE_SHIFT=12) - confirmed"

# Build kernel, modules, and device trees
echo "[5/6] Building kernel (this takes 15-30 minutes)..."
make -j${NPROC} ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules dtbs

# Package output
echo "[6/6] Packaging output..."
cd ..
mkdir -p "${OUTPUT_DIR}/overlays"

cp "${KERNEL_DIR}/arch/arm64/boot/Image" "${OUTPUT_DIR}/kernel_2712.img"
cp "${KERNEL_DIR}/arch/arm64/boot/dts/broadcom/bcm2712*.dtb" "${OUTPUT_DIR}/"
cp "${KERNEL_DIR}/arch/arm64/boot/dts/overlays/"*.dtb* "${OUTPUT_DIR}/overlays/" 2>/dev/null || true

# Install modules to a temp directory and package them
MODULES_TMP=$(mktemp -d)
make -C "${KERNEL_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${MODULES_TMP}" modules_install

KERNEL_VER=$(ls "${MODULES_TMP}/lib/modules/")
tar czf "${OUTPUT_DIR}/modules-${KERNEL_VER}.tar.gz" -C "${MODULES_TMP}" lib/
rm -rf "${MODULES_TMP}"

echo ""
echo "=== Build Complete ==="
echo "Output in: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/kernel_2712.img"
echo "Kernel version: ${KERNEL_VER}"
file "${OUTPUT_DIR}/kernel_2712.img"
echo ""
echo "Next: copy boot/ and output/ files to your SD card."
echo "See README.md for detailed instructions."
