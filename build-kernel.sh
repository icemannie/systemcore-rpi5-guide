#!/bin/bash
set -e

KERNEL_BRANCH="rpi-6.12.y"
KERNEL_DIR="rpi-linux"
NPROC=$(nproc)

echo "=== SystemCore Pi 5 Kernel Builder ==="
echo "Branch: ${KERNEL_BRANCH}"
echo "Cores:  ${NPROC}"
echo ""

# Install dependencies
echo "[1/5] Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    flex bison libssl-dev libncurses-dev \
    bc kmod cpio git

# Clone kernel source (re-clone if branch changed)
if [ -d "${KERNEL_DIR}" ]; then
    CURRENT_BRANCH=$(git -C "${KERNEL_DIR}" branch --show-current 2>/dev/null || echo "unknown")
    if [ "$CURRENT_BRANCH" != "$KERNEL_BRANCH" ]; then
        echo "[2/5] Kernel source is branch ${CURRENT_BRANCH}, need ${KERNEL_BRANCH}. Re-cloning..."
        rm -rf "${KERNEL_DIR}"
        git clone --depth=1 --branch "${KERNEL_BRANCH}" \
            https://github.com/raspberrypi/linux.git "${KERNEL_DIR}"
    else
        echo "[2/5] Kernel source already exists (${KERNEL_BRANCH}), skipping clone."
    fi
else
    echo "[2/5] Cloning Raspberry Pi kernel (${KERNEL_BRANCH})..."
    git clone --depth=1 --branch "${KERNEL_BRANCH}" \
        https://github.com/raspberrypi/linux.git "${KERNEL_DIR}"
fi

cd "${KERNEL_DIR}"

# Configure for Pi 5 (BCM2712) with 4K pages
echo "[3/5] Configuring kernel (bcm2712_defconfig + 4K pages)..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2712_defconfig
scripts/config --disable ARM64_16K_PAGES --enable ARM64_4K_PAGES
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

PAGE_SHIFT=$(grep -E "^CONFIG_(ARM64_)?PAGE_SHIFT=" .config | cut -d= -f2)
if [ "${PAGE_SHIFT}" != "12" ]; then
    echo "ERROR: Page shift is ${PAGE_SHIFT}, expected 12 (4K pages)"
    exit 1
fi
echo "  Page size: 4K (PAGE_SHIFT=12) - confirmed"

# Build kernel, modules, and device trees
echo "[4/5] Building kernel (this takes 15-30 minutes)..."
make -j${NPROC} ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules dtbs

echo "[5/5] Done."
echo ""
KVER=$(cat include/config/kernel.release)
echo "Kernel: $(file arch/arm64/boot/Image | sed 's/.*: //')"
echo "Version: ${KVER}"
