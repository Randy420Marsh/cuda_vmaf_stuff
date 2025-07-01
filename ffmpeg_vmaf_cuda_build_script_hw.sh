#!/bin/bash

# This script converts a Dockerfile into a local build script for Ubuntu 24.04.
# It installs necessary dependencies, clones repositories, builds VMAF and FFmpeg
# with CUDA support, and performs a test conversion and VMAF analysis.

# IMPORTANT PREREQUISITES:
# 1. NVIDIA GPU: Ensure you have a compatible NVIDIA GPU.
# 2. NVIDIA Drivers: Ensure NVIDIA proprietary drivers are correctly installed on your system.
#    You can typically install them using `sudo ubuntu-drivers autoinstall`.
# 3. CUDA Toolkit: The script expects CUDA to be installed in `/usr/local/cuda-12.8`.
#    If you haven't installed CUDA 12.8, download and install the appropriate version
#    from NVIDIA's website for Ubuntu 24.04.
# 4. Internet Connection: Required to download packages and clone repositories.
# 5. Root Privileges: The script will use `sudo` for system-wide installations.

# --- Set Environment Variables for CUDA and Libraries ---
# These are crucial for the build process to find CUDA components.
# LD_LIBRARY_PATH is for runtime linking. This is crucial for the "cannot open shared object file" error.
# It tells the system where to look for shared libraries when executing a program.
# LIBRARY_PATH is for compile-time linking.
# Add CUDA bin to PATH

# Note: For static builds, LD_LIBRARY_PATH is less critical for the final binary,
# but it's still needed for tools run during the build (like pkg-config if it needs to find shared libs).
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
export LIBRARY_PATH="/usr/local/lib:/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib"
export CUDA_PATH="/usr/local/cuda-12.8"
export PATH="${CUDA_PATH}/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/lib:${CUDA_PATH}/lib64:${CUDA_PATH}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"

/lib64/ld-linux-x86-64.so.2 --help

echo "You can do this:"
echo "sudo nano /etc/ld.so.conf"
echo.
echo "Add these in the file and run"
echo "sudo ldconfig"
echo "/usr/local/cuda-12.8/lib64"
echo "/usr/local/cuda-12.8/targets/x86_64-linux/lib"

# --- Add CUDA Stubs to ldconfig (only for runtime, not build path) ---
echo "Adding CUDA stubs to ldconfig and updating shared library cache..."
sudo bash -c "echo '${CUDA_PATH}/lib64/stubs/' > /etc/ld.so.conf.d/cuda-stubs.conf"
# DO NOT add /usr/local/lib here for VMAF. VMAF will be linked statically
# and its shared library should not be installed system-wide to avoid conflicts.
sudo ldconfig
echo "CUDA stubs configured for ldconfig."

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Starting VMAF and FFmpeg build process for Ubuntu 24.04..."

# --- 1. Define Variables ---
VMAF_TAG="master" # Using 'master' branch for VMAF
FFFMPEG_TAG="master" # Using 'master' branch for FFmpeg
NV_CODEC_HEADERS_TAG="master" # Using 'master' branch for NVIDIA codec headers

echo "Using VMAF tag: $VMAF_TAG"
echo "Using FFmpeg tag: $FFFMPEG_TAG"
echo "Expecting CUDA in ${CUDA_PATH}"

# --- 2. Update System and Install Core Dependencies ---
echo "Updating package list and installing core build dependencies..."
sudo apt-get update
# Install development packages including those with static archives (-dev suffix).
# build-essential for common build tools (gcc, g++, make).
# yasm/nasm are assemblers often required by x264/x265.
# libtool, automake for other build systems.
# libssl-dev for TLS/SSL support (gnutls alternative).
sudo apt install -y \
    libopenjp2-7-dev ninja-build cmake git python3 python3-pip nasm xxd pkg-config curl unzip \
    libx264-dev libx265-dev libnuma-dev libgnutls28-dev \
    build-essential yasm libtool automake libssl-dev

echo "Core dependencies installed."

# --- 3. Clone Repositories ---
echo "Cloning VMAF, FFmpeg, and nv-codec-headers repositories..."

# Create a temporary directory for cloning if it doesn't exist
mkdir -p ~/build_temp
cd ~/build_temp

# Clean previous clones to ensure fresh start, especially after config changes.
# This assumes you want to re-clone or pull updates.
rm -rf vmaf FFmpeg nv-codec-headers

# Clone VMAF repository and checkout specified tag
if [ ! -d "vmaf" ]; then
    git clone https://github.com/Netflix/vmaf.git
fi
cd vmaf
git checkout "$VMAF_TAG"
cd ..

# Clone FFmpeg repository and checkout specified tag
if [ ! -d "FFmpeg" ]; then
    git clone https://github.com/FFmpeg/FFmpeg.git
fi
cd FFmpeg
git checkout "$FFFMPEG_TAG"
cd ..

# Clone nv-codec-headers and build/install them.
if [ ! -d "nv-codec-headers" ]; then
    git clone https://github.com/FFmpeg/nv-codec-headers.git
fi
cd nv-codec-headers
git checkout "$NV_CODEC_HEADERS_TAG"
echo "Building and installing nv-codec-headers..."
make
sudo make install
cd .. # Go back to ~/build_temp

echo "Repositories cloned and nv-codec-headers installed."

# --- 5. Install VMAF (static build) ---
echo "Installing VMAF (static library only)..."
python3 -m pip install meson
python3 --version

cd vmaf
meson setup --reconfigure \
    libvmaf/build libvmaf \
    --default-library=static \
    -Denable_tests=false \
    -Denable_cuda=true \
    -Denable_docs=false \
    -Dbuilt_in_models=true \
    -Denable_avx512=true \
    --buildtype release

ninja -vC libvmaf/build

if [ -f "libvmaf/build/src/libvmaf.a" ]; then
    echo "Verification: libvmaf.a found at libvmaf/build/src"
else
    echo "ERROR: libvmaf.a NOT found at libvmaf/build/src. VMAF static library build might have failed."
    exit 1
fi

echo "Copying VMAF models to /usr/local/share/model/..."
sudo mkdir -p /usr/local/share/model/
sudo cp -r model/* /usr/local/share/model/

cd .. # Go back to ~/build_temp
echo "VMAF static library built and models copied."

# --- 6. Install FFmpeg ---
echo "Installing FFmpeg with VMAF (static) and CUDA support..."
cd FFmpeg

make clean || true

# Define the exact paths to the VMAF static library and its include directories.
VMAF_BUILD_LIB_DIR="${HOME}/build_temp/vmaf/libvmaf/build/src"
VMAF_SRC_INCLUDE_DIR="${HOME}/build_temp/vmaf/libvmaf/src"
VMAF_PUBLIC_INCLUDE_DIR="${HOME}/build_temp/vmaf/libvmaf/include"

# Crucial adjustment: Use the actual static library names found via `ls -lh *.a`
# We are removing -lnvenc and the NPP libraries that don't have a `_static.a` version on your system.
# -lcuda is typically for the driver API, which is usually dynamically linked to the driver.
# -lcudart_static is the static CUDA runtime library.
# -lnvrtc_static is for CUDA Runtime Compilation.
# The remaining NPP libraries are the ones you confirmed exist as *_static.a.
# libnvcuvid (for decoding) and libnvenc (for encoding) are often only available as shared libraries
# unless a specific `nv-codec-sdk` installation provides static versions (which are not in lib64).
# If you *need* these, you might have to enable shared linking for them or use a different CUDA SDK component.
# For a "completely static" build, if these are not present as .a, FFmpeg might not be truly static for ALL CUDA features.
# Let's try building with what IS available statically.

./configure \
  --pkg-config-flags="--static" \
  --ld="g++" \
  --extra-cflags="-I/usr/local/include -I${CUDA_PATH}/include -I${VMAF_SRC_INCLUDE_DIR} -I${VMAF_PUBLIC_INCLUDE_DIR}" \
  --extra-ldflags="-L/usr/local/lib -L${CUDA_PATH}/lib64 -L${VMAF_BUILD_LIB_DIR}" \
  --extra-libs="-lpthread -lm -lstdc++ -ldl -lz -lvmaf \
    -lcudart_static -lcudadevrt -lnvrtc_static \
    -lnppc_static -lnppial_static -lnppicc_static -lnppidei_static -lnppif_static -lnppig_static -lnppim_static -lnppist_static -lnppisu_static -lnppitc_static -lnpps_static" \
  --enable-gpl \
  --enable-libvmaf \
  --enable-static \
  --disable-shared \
  --enable-gnutls \
  --enable-libnpp \
  --enable-nonfree \
  --enable-libx264 \
  --enable-libx265 \
  --enable-nvdec \
  --enable-nvenc \
  --enable-cuvid \
  --enable-cuda \
  --enable-cuda-nvcc \
  --enable-ffnvcodec \
  --disable-stripping

echo "Compiling FFmpeg (this may take a while)..."
make -j$(nproc)

echo "Installing FFmpeg..."
sudo make install

cd .. # Go back to ~/build_temp
echo "FFmpeg installed successfully."

# --- 7. Data Directory and Test Files ---
echo "Creating data directory and downloading test video..."
mkdir -p ~/build/data
cd ~/build/data

if [ ! -f "ref.mp4" ]; then
    curl -o ref.mp4 https://videos.pexels.com/video-files/4307941/4307941-uhd_2560_1440_30fps.mp4
    echo "Downloaded ref.mp4"
else
    echo "ref.mp4 already exists, skipping download."
fi

echo "Converting ref.mp4 to dist-nvenc.mp4 using h264_nvenc..."
ffmpeg -i ref.mp4 -c:v h264_nvenc -preset fast -pix_fmt yuv420p dist-nvenc.mp4

echo "Test video converted."

# --- 8. Verify FFmpeg Capabilities and Run VMAF Analysis ---
echo "Verifying FFmpeg hardware acceleration and encoders..."
ffmpeg -hwaccels
ffmpeg -encoders

echo "Running VMAF analysis with GPU decoding (this will output to null)..."
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/ref.mp4" \
    -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale_cuda=1920:1080:format=yuv420p[ref];[1:v]scale_cuda=1920:1080:format=yuv420p[dist];[dist][ref]libvmaf_cuda" \
    -f null -

echo "VMAF analysis command executed. Script will pause for 5 seconds."
sleep 1

ffmpeg -version

echo "Script finished successfully!"
echo ""
echo "You can find the test files in ~/build/data."
echo "To run the VMAF analysis again, use:"
echo ""
echo "ffmpeg \\"
echo "    -hwaccel cuda -hwaccel_output_format cuda -i \"${HOME}/build/data/ref.mp4\" \\"
echo "    -hwaccel cuda -hwaccel_output_format cuda -i \"${HOME}/build/data/dist-nvenc.mp4\" \\"
echo "    -filter_complex \"[0:v]scale_cuda=1920:1080:format=yuv420p[ref];[1:v]scale_cuda=1920:1080:format=yuv420p[dist];[dist][ref]libvmaf_cuda\" \\"
echo "    -f null -"
