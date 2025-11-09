#!/bin/bash
set -e  # Exit immediately if any command fails

# --------------- Helper Functions ------------------

echo "Build and install"
echo "https://github.com/NVIDIA/open-gpu-kernel-modules"

log() {
    echo -e "\e[1;34m[INFO]\e[0m $1"
}

error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1" >&2
    exit 1
}

check_cmd_exists() {
    command -v "$1" >/dev/null 2>&1 \
        || error "'$1' command not found. Please install it and retry."
}

# --------------- Step 1: Stop GUI ------------------

log "Switching to multi-user (non-GUI) runlevel to prepare for driver install."
echo "Run this manually in another terminal if you want:"
echo "    sudo systemctl isolate multi-user.target"
read -p "Press Enter when ready to proceed..."

# --------------- Step 2: Install NVIDIA Driver ------------------

log "Installing NVIDIA driver with DKMS and module signing..."

sudo ./NVIDIA-Linux-x86_64-580.105.08.run \
    --dkms \
    --module-signing-secret-key=/root/module-signing/MOK.key \
    --module-signing-public-key=/root/module-signing/MOK.der \
    --glvnd-egl-config-path /usr/share/glvnd/egl_vendor.d \
    --kernel-module-type=open || error "NVIDIA .run installer failed."

# --------------- Step 3: Verify Driver Installation ------------------

log "Verifying driver installation using nvidia-smi..."
if ! nvidia-smi &>/dev/null; then
    error "nvidia-smi failed — driver might not be installed or loaded correctly."
else
    log "nvidia-smi reports the GPU and driver are working."
fi

# --------------- Step 4: Reinstall nvidia-settings ------------------

log "Reinstalling 'nvidia-settings' package via apt..."

sudo apt update
sudo apt --reinstall install nvidia-settings || error "Failed to reinstall nvidia-settings."

# Verify executable presence
if ! command -v nvidia-settings &>/dev/null; then
    error "nvidia-settings binary not found after reinstall."
else
    log "nvidia-settings is now available."
fi

# --------------- Step 5: Fix Polkit Wrapper Permissions (Ubuntu-specific) ------------------

POLKIT_WRAPPER="/usr/share/screen-resolution-extra/nvidia-polkit"
if [ -f "$POLKIT_WRAPPER" ]; then
    if [ ! -x "$POLKIT_WRAPPER" ]; then
        log "Making polkit helper executable so GUI saving works without manual sudo..."
        sudo chmod +x "$POLKIT_WRAPPER" || error "Failed to chmod polkit helper."
        log "Permissions fixed for polkit helper."
    else
        log "Polkit helper is already executable."
    fi
else
    log "Polkit helper script not found; skipping permission fix."
fi

# --------------- Step 6: Feedback and Next Steps ------------------

log "All steps completed successfully."
log "You may now run 'nvidia-settings' (with or without sudo) and test saving settings."

read -p "Press Enter to return to console (or run 'sudo systemctl isolate graphical.target' manually)..."


#echo "First exit to terminal using:"
#echo ""
#echo "sudo systemctl isolate multi-user.target"
#echo ""
#read -p "Press Enter to continue..."

#sudo ./NVIDIA-Linux-x86_64-580.76.05.run \
#--dkms \
#--module-signing-secret-key=/root/module-signing/MOK.key \
#--module-signing-public-key=/root/module-signing/MOK.der \
#--glvnd-egl-config-path /usr/share/glvnd/egl_vendor.d \
#--kernel-module-type=open
