#!/bin/bash
# SacrOS Boot Script - ./../../scripts/start.sh
# Blue/white old-school theme, step-by-step progress, auto cleanup on error

# --- Color Definitions ---
RESET="\e[0m"
BOLD="\e[1m"
WHITE="\e[97m"
BLUE_BG="\e[44m"
BLUE="\e[34m"
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"

# --- Function to print steps ---
step() {
    echo -e "${BLUE_BG}${WHITE}[Step] $1${RESET}"
}

success() {
    echo -e "${GREEN}[Success] $1${RESET}"
}

error() {
    echo -e "${RED}[Error] $1${RESET}"
}

# --- Cleanup function ---
cleanup_environment() {
    step "Cleaning up the environment..."

    # Unmount disk image if mounted
    if mountpoint -q /mnt/disk; then
        sudo umount /mnt/disk && success "Unmounted /mnt/disk."
    fi

    # Remove temporary directories
    if [ -d /mnt/disk ]; then
        sudo rm -rf /mnt/disk && success "Removed /mnt/disk directory."
    fi

    # Remove generated files
    [ -f disk.img ] && rm -f disk.img && success "Removed disk.img."
    [ -f initrd.img ] && rm -f initrd.img && success "Removed initrd.img."
    [ -f qemu.log ] && rm -f qemu.log && success "Removed qemu.log."

    echo -e "${BLUE_BG}${WHITE}[Cleanup] Environment cleaned successfully.${RESET}"
}

# Exit script on any error, call cleanup
trap 'error "An error occurred. Running cleanup..."; cleanup_environment; exit 1' ERR

# --- Kernel Compilation ---
# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[Error] Script not run as root. Re-running with sudo..."
    exec sudo -k bash "$0" "$@"
fi

# Disable cleanup if not run as root
trap '' EXIT

# Enhanced error handling for kernel compilation
compile_kernel() {
    step "Compiling the Linux kernel..."

    KERNEL_DIR="$(dirname "$0")/../kernel"
    if [ ! -d "$KERNEL_DIR" ]; then
        error "Kernel source directory not found at $KERNEL_DIR."
        exit 1
    fi

    cd "$KERNEL_DIR" || exit 1

    if [ ! -f Makefile ]; then
        error "Makefile not found in $KERNEL_DIR."
        exit 1
    fi

    if ! make help | grep -q defconfig; then
        error "The 'defconfig' target is not available."
        exit 1
    fi

    CPU_CORES=$(nproc)
    make defconfig && success "Default kernel configuration applied." || {
        error "Failed to apply default kernel configuration."
        exit 1
    }

    make -j$CPU_CORES bzImage && success "Kernel compiled successfully." || {
        error "Kernel compilation failed. Check the logs for details."
        exit 1
    }

    if [ ! -f arch/x86/boot/bzImage ]; then
        error "Kernel file 'bzImage' not found."
        exit 1
    fi

    cd - || exit 1
}

# --- Initramfs Generation ---
generate_initramfs() {
    step "Generating initramfs..."
    mkinitramfs -o initrd.img && success "Initramfs generated successfully."
}

# --- Create Root Filesystem ---
create_root_filesystem() {
    step "Creating root filesystem for SacrOS..."

    # Ensure the script is run as root
    if [ "$EUID" -ne 0 ]; then
        echo "[Error] Please run as root. Exiting."
        exit 1
    fi

    # Set relative paths
    BUILD_DIR="build"
    ROOTFS_DIR="$BUILD_DIR/sacros-rootfs"

    # Create build directory if it doesn't exist
    mkdir -p "$BUILD_DIR"

    # Ensure mount points exist before mounting pseudo-filesystems
    mkdir -p "$ROOTFS_DIR/dev"
    mkdir -p "$ROOTFS_DIR/proc"
    mkdir -p "$ROOTFS_DIR/sys"

    # Unmount pseudo-filesystems in the correct order
    if mountpoint -q "$ROOTFS_DIR/sys"; then
        umount "$ROOTFS_DIR/sys"
    fi
    if mountpoint -q "$ROOTFS_DIR/proc"; then
        umount "$ROOTFS_DIR/proc"
    fi
    if mountpoint -q "$ROOTFS_DIR/dev"; then
        umount "$ROOTFS_DIR/dev"
    fi

    # Ensure the root filesystem directory is properly cleaned before proceeding
    if [ -d "$ROOTFS_DIR" ]; then
        step "Cleaning up existing root filesystem directory..."
        sudo umount -lf "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" 2>/dev/null || true
        sudo rm -rf "$ROOTFS_DIR" && success "Root filesystem directory cleaned."
    fi

    # Recreate the root filesystem directory
    mkdir -p "$ROOTFS_DIR"

    # Proceed with creating the root filesystem
    step "Creating root filesystem for SacrOS..."
    # Run debootstrap to set up the root filesystem
    echo "[Info] Running debootstrap to create the root filesystem..."
    debootstrap --arch=amd64 stable "$ROOTFS_DIR" http://ftp.us.debian.org/debian
    if [ $? -ne 0 ]; then
        error "Failed to run debootstrap. Exiting."
        exit 1
    fi

    # Bind mount pseudo-filesystems for chroot
    echo "[Info] Mounting pseudo-filesystems..."
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"

    # Ensure /dev/pts is mounted in the chroot environment
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

    # Chroot and install essential packages
    echo "[Info] Installing essential packages..."
    chroot "$ROOTFS_DIR" /bin/bash -c "apt update && apt install -y sudo apt network-manager"
    if [ $? -ne 0 ]; then
        echo "[Error] Failed to install essential packages. Exiting."
        exit 1
    fi

    # Set up locales in the chroot environment
    chroot "$ROOTFS_DIR" /bin/bash -c "apt update && apt install -y locales"
    chroot "$ROOTFS_DIR" /bin/bash -c "locale-gen en_US.UTF-8"
    chroot "$ROOTFS_DIR" /bin/bash -c "update-locale LANG=en_US.UTF-8"

    # Verify and fix network-manager installation
    if [ ! -f "$ROOTFS_DIR/lib/systemd/system/network-manager.service" ]; then
        step "Reinstalling network-manager to fix missing service file..."
        chroot "$ROOTFS_DIR" /bin/bash -c "apt install --reinstall -y network-manager"

        if [ ! -f "$ROOTFS_DIR/lib/systemd/system/network-manager.service" ]; then
            error "network-manager.service still does not exist. Attempting to enable it manually."
            chroot "$ROOTFS_DIR" /bin/bash -c "systemctl enable network-manager || true"
        fi
    fi

    # Configure hostname and branding
    echo "SacrOS" | sudo tee "$ROOTFS_DIR/etc/hostname"
    echo "Welcome to SacrOS!" | sudo tee "$ROOTFS_DIR/etc/issue"

    # Enable network manager
    sudo chroot "$ROOTFS_DIR" systemctl enable network-manager && success "Network manager enabled."

    # Unmount /proc and /sys
    sudo umount "$ROOTFS_DIR/proc"
    sudo umount "$ROOTFS_DIR/sys"
}

# --- Disk Image Preparation ---
prepare_disk_image() {
    step "Preparing bootable disk image..."
    local disk_image="disk.img"
    local mount_dir="$HOME/mnt/disk"

    dd if=/dev/zero of=$disk_image bs=1M count=2048
    echo -e "o\nn\n\n\n\n\n+2G\na\nw" | fdisk $disk_image

    # Verify partition table
    step "Verifying partition table..."
    fdisk -l $disk_image | grep -q "Disklabel type: dos" || { error "Partition table verification failed"; exit 1; }

    if [ ! -f "$KERNEL_DIR/arch/x86/boot/bzImage" ]; then
        error "Kernel file 'bzImage' not found."
        exit 1
    fi

    sudo mkdir -p $mount_dir/boot
    sudo cp "$KERNEL_DIR/arch/x86/boot/bzImage" $mount_dir/boot/vmlinuz
    sudo cp initrd.img $mount_dir/boot/initrd.img

    if [ ! -d "$ROOTFS_DIR" ]; then
        error "Root filesystem directory $ROOTFS_DIR does not exist. Exiting."
        exit 1
    fi

    MOUNT_DIR="$HOME/mnt/disk"
    mkdir -p "$MOUNT_DIR"

    LOOP_DEVICE=$(losetup -f --show disk.img)
    if [ -z "$LOOP_DEVICE" ]; then
        error "Failed to set up loop device. Exiting."
        exit 1
    fi

    sudo mount "${LOOP_DEVICE}p1" "$MOUNT_DIR"

    step "Copying root filesystem to disk image..."
    sudo cp -a "$ROOTFS_DIR/." "$MOUNT_DIR" && success "Root filesystem copied."

    step "Installing GRUB bootloader..."
    sudo grub-install --boot-directory="$MOUNT_DIR/boot" --target=i386-pc --modules="part_msdos ext2" "$LOOP_DEVICE"
    if [ $? -ne 0 ]; then
        error "Failed to install GRUB bootloader. Exiting."
        exit 1
    fi

    cat <<EOF | sudo tee "$MOUNT_DIR/boot/grub/grub.cfg"
set default=0
set timeout=5

menuentry "SacrOS" {
    linux /boot/vmlinuz root=/dev/sda1 rw
    initrd /boot/initrd.img
}
EOF

    # Unmount and clean up
    sync && sudo umount "$MOUNT_DIR"
    sudo losetup -d "$LOOP_DEVICE"
    sudo rm -rf "$MOUNT_DIR"
}

# --- Start Kernel in QEMU ---
start_kernel() {
    step "Starting the Linux kernel in QEMU..."

    # Launch QEMU with graphical window and fallback display options
    qemu-system-x86_64 \
        -drive file=disk.img,format=raw,if=virtio \
        -m 1024 \
        -display gtk,zoom-to-fit=on \
        -no-reboot || {
            step "GTK display failed. Falling back to SDL display..."
            qemu-system-x86_64 \
                -drive file=disk.img,format=raw,if=virtio \
                -m 1024 \
                -display sdl \
                -no-reboot;
        }

    success "QEMU launched successfully."
}

# --- Main Script Execution ---
compile_kernel
generate_initramfs
create_root_filesystem
prepare_disk_image
start_kernel

# Cleanup runs automatically on exit