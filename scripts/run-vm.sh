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
cleanup() {
    echo -e "${BLUE_BG}${WHITE}[Cleanup] Cleaning system...${RESET}"
    [ -n "$NM_PID" ] && kill "$NM_PID" 2>/dev/null && echo -e "${CYAN}Stopped NetworkManager${RESET}"
    [ -n "$DBUS_PID" ] && kill "$DBUS_PID" 2>/dev/null && echo -e "${CYAN}Stopped dbus-daemon${RESET}"
    sync
    for dir in /dev/pts /dev /run /sys /proc; do
        umount $dir 2>/dev/null && echo -e "${CYAN}Unmounted $dir${RESET}"
    done
    echo -e "${BLUE_BG}${WHITE}[Cleanup] Done. System safe to power off.${RESET}"
}

# Exit script on any error, call cleanup
trap 'error "An error occurred. Running cleanup..."; cleanup; exit 1' ERR
trap cleanup EXIT

# --- START BOOT STEPS ---
step "Mounting essential filesystems..."
mount -t proc /proc /proc && echo -e "${GREEN}Mounted /proc${RESET}"
mount -t sysfs /sys /sys && echo -e "${GREEN}Mounted /sys${RESET}"
mount -t tmpfs tmpfs /run && echo -e "${GREEN}Mounted /run${RESET}"
mount -t devtmpfs devtmpfs /dev && echo -e "${GREEN}Mounted /dev${RESET}"
[ -d /dev/pts ] && mount -t devpts devpts /dev/pts && echo -e "${GREEN}Mounted /dev/pts${RESET}"

step "Starting D-Bus..."
if command -v dbus-daemon >/dev/null 2>&1; then
    dbus-daemon --system &
    DBUS_PID=$!
    success "D-Bus started (PID $DBUS_PID)"
else
    echo -e "${RED}dbus-daemon not found, skipping${RESET}"
fi

step "Starting NetworkManager..."
if command -v NetworkManager >/dev/null 2>&1; then
    /usr/sbin/NetworkManager &
    NM_PID=$!
    success "NetworkManager started (PID $NM_PID)"
else
    echo -e "${RED}NetworkManager not found, skipping${RESET}"
fi

step "Updating apt sources..."
if command -v apt >/dev/null 2>&1; then
    apt update && success "apt sources updated" || echo -e "${RED}apt update failed (offline?)${RESET}"
fi

step "Displaying system info..."
echo -e "${CYAN}Kernel: $(uname -r)${RESET}"

step "Launching interactive shell..."
echo -e "${BLUE_BG}${WHITE}You are now in the shell. Type 'exit' to quit.${RESET}"
/bin/bash

# Cleanup runs automatically on exit