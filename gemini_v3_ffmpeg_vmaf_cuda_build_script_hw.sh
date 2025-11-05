#!/bin/bash

# This script converts a Dockerfile into a local build script for Ubuntu 24.04.
# It installs necessary dependencies, clones repositories, builds VMAF and FFmpeg
# with CUDA support, and performs a test conversion and VMAF analysis.

# IMPORTANT PREREQUISITES:
# 1. NVIDIA GPU: Ensure you have a compatible NVIDIA GPU.
# 2. NVIDIA Drivers: Ensure NVIDIA proprietary drivers are correctly installed on your system.
#    You can typically install them using `sudo ubuntu-drivers autoinstall`.
# 3. CUDA Toolkit: The script expects CUDA to be installed in `/usr/local/cuda-13.0`.
#    If you haven't installed CUDA 13.0, download and install the appropriate version
#    from NVIDIA's website for Ubuntu 24.04.
# 4. Internet Connection: Required to download packages and clone repositories.
# 5. Root Privileges: The script will use `sudo` for system-wide installations.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Set up Meson Environment ---
echo "Setting up Python virtual environment and installing newer Meson..."
# Create build directory structure
mkdir -p "$HOME/build_temp"
cd "$HOME/build_temp"

# If the venv exists, delete and recreate it to ensure a clean state
if [ -d "venv" ]; then
    rm -rf venv
fi
python3 -m venv venv
source ./venv/bin/activate
pip install meson
echo "Python virtual environment configured."

# --- Set Environment Variables for CUDA and Libraries ---
# These are crucial for the build process to find CUDA components and for static linking.
CUDA_VERSION="13.0"
CUDA_PATH="/usr/local/cuda-${CUDA_VERSION}"

# FIX: Explicitly prioritize the custom pkgconfig path over system paths
export PKG_CONFIG_PATH="$HOME/build_temp/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig"
export LIBRARY_PATH="/usr/local/lib:${CUDA_PATH}/lib64:${CUDA_PATH}/targets/x86_64-linux/lib"
export CUDA_PATH="${CUDA_PATH}"
export PATH="${CUDA_PATH}/bin:${PATH}"


# The following lines were instructional echoes. They are removed as they are not executable commands.
# /lib64/ld-linux-x86-64.so.2 --help
# echo "You can do this:"
# echo "sudo nano /etc/ld.so.conf"
# echo. # This was an error, should be 'echo ""' or 'echo'
# echo "Add these in the file and run"
# echo "sudo ldconfig"
# echo "/usr/local/cuda-13.0/lib64"
# echo "/usr/local/cuda-13.0/targets/x86_64-linux/lib"


# NOTE: Removed LD_LIBRARY_PATH export. We will use ldconfig for permanent system visibility.
#This in the below is if you can't install the display driver, only for building!
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#WARNING:

#You should always run with libnvidia-ml.so that is installed with your
#NVIDIA Display Driver. By default it's installed in /usr/lib and /usr/lib64.
#libnvidia-ml.so in GDK package is a stub library that is attached only for
#build purposes (e.g. machine that you build your application doesn't have
#to have Display Driver installed).
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# --- Add CUDA Libraries to ldconfig (PERMANENT FIX FOR RUNTIME) ---
##echo "Adding CUDA libraries and stubs to ldconfig for permanent runtime visibility..."
# 1. Add the main CUDA lib path (Crucial for finding libcudart.so and other CUDA toolkit libs)
##sudo bash -c "echo '${CUDA_PATH}/lib64' > /etc/ld.so.conf.d/cuda-lib.conf"
# 2. Add the CUDA stubs path (For linking protection/compatibility)
##sudo bash -c "echo '${CUDA_PATH}/lib64/stubs/' > /etc/ld.so.conf.d/cuda-stubs.conf"
# 3. Add the common NVIDIA driver path (Crucial for finding libcuda.so, required by cuInit)
# This path is standard on Ubuntu systems that have the proprietary NVIDIA drivers installed.
##sudo bash -c "echo '/usr/lib/x86_64-linux-gnu/' > /etc/ld.so.conf.d/nvidia-driver.conf"
# 4. Update the linker cache
sudo ldconfig
echo "System dynamic linker cache updated. FFmpeg should now find CUDA libraries at runtime."

# --- REMOVE CONFLICTING SYSTEM PACKAGE ---
echo "PURGING CONFLICTING SYSTEM PACKAGE: libdav1d-dev (version 0.9.2)..."
sudo apt-get purge -y libdav1d-dev || true

echo "Updating package list and installing core build dependencies (excluding libdav1d-dev and libnuma-dev)..."
sudo apt-get update -qq && sudo apt-get -y install \
  autoconf \
  automake \
  build-essential \
  cmake \
  curl \
  doxygen \
  git \
  libass-dev \
  libfdk-aac-dev \
  libfreetype6-dev \
  libgnutls28-dev \
  libmp3lame-dev \
  libopenjp2-7-dev \
  libsdl2-dev \
  libssl-dev \
  libunistring-dev \
  liblilv-dev \
  libtool \
  libva-dev \
  libvdpau-dev \
  libwebp-dev \
  libvpx-dev \
  libvorbis-dev \
  libopus-dev \
  libx264-dev \
  libx265-dev \
  libaom-dev \
  libxcb1-dev \
  libxcb-shm0-dev \
  libxcb-xfixes0-dev \
  nasm \
  ninja-build \
  pkg-config \
  python3 \
  python3-pip \
  texinfo \
  unzip \
  wget \
  xxd \
  yasm \
  zlib1g-dev \
  asciidoc # Ensure asciidoc is installed system-wide

echo "Core dependencies installed."
echo "Starting VMAF and FFmpeg build process..."

# --- 1. Define Variables ---
VMAF_TAG="master"
FFMPEG_TAG="master"
NV_CODEC_HEADERS_TAG="master"

echo "Using VMAF tag: $VMAF_TAG"
echo "Using FFmpeg tag: $FFMPEG_TAG"
echo "Expecting CUDA in ${CUDA_PATH}"

# Change to build directory
cd "$HOME/build_temp"

# --- 2. Build AOM (AV1 Encoder) ---
echo "Building AOM..."
git -C aom pull 2> /dev/null || git clone --depth 1 https://aomedia.googlesource.com/aom
mkdir -p aom_build
cd aom_build
cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$HOME/build_temp" -DENABLE_TESTS=OFF -DENABLE_NASM=on ../aom
make -j$(nproc)
make install
cd "$HOME/build_temp"

# --- 3. Build SVT-AV1 (Another AV1 Encoder) ---
echo "Building SVT-AV1..."
git -C SVT-AV1 pull 2> /dev/null || git clone https://gitlab.com/AOMediaCodec/SVT-AV1.git
mkdir -p SVT-AV1/build
cd SVT-AV1/build
cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$HOME/build_temp" -DCMAKE_BUILD_TYPE=Release -DBUILD_DEC=OFF -DBUILD_SHARED_LIBS=OFF ..
make -j$(nproc)
make install
cd "$HOME/build_temp"

# --- 4. Build LV2 (Audio Plugin Specification) ---
echo "Building LV2, disabling documentation and examples to avoid dependency errors..."
LV2_VERSION="1.18.10"
if [ ! -d "lv2-${LV2_VERSION}" ]; then
    curl -o "lv2-${LV2_VERSION}.tar.xz" "https://lv2plug.in/spec/lv2-${LV2_VERSION}.tar.xz"
    tar xf lv2-${LV2_VERSION}.tar.xz
fi
cd lv2-${LV2_VERSION}
# Remove old build directory after configuration failure
if [ -d "build" ]; then
    rm -rf build
fi
# LV2 build setup
meson setup build \
    --prefix="$HOME/build_temp" \
    --buildtype=release \
    --default-library=static \
    --libdir="$HOME/build_temp/lib" \
    -Ddocs=disabled \
    -Dtests=disabled
ninja -C build -j$(nproc)
ninja -C build install
cd "$HOME/build_temp" # Go back to $HOME/build_temp

# --- 5. Install nv-codec-headers ---
echo "Installing nv-codec-headers..."
if [ ! -d "nv-codec-headers" ]; then
    git clone https://github.com/FFmpeg/nv-codec-headers.git
fi
cd nv-codec-headers
git checkout "$NV_CODEC_HEADERS_TAG"
make
sudo make install
cd "$HOME/build_temp"

# --- 6. Install VMAF (static build with CUDA) ---
echo "Building VMAF (static library with CUDA support)..."
if [ ! -d "vmaf" ]; then
    git clone https://github.com/Netflix/vmaf.git
fi
cd vmaf
git checkout "$VMAF_TAG"

# VMAF build requires a specific directory structure for Meson
cd "${HOME}/build_temp/vmaf"
# Clean up previous build directory before configuring
if [ -d "libvmaf/build" ]; then
    rm -rf libvmaf/build
fi
# FIX: Added --libdir=lib to force installation to $HOME/build_temp/lib, overriding the x86_64-linux-gnu path
meson setup \
    libvmaf/build libvmaf \
    --prefix="$HOME/build_temp" \
    --default-library=static \
    --libdir=lib \
    -Denable_tests=false \
    -Denable_cuda=true \
    -Denable_docs=false \
    -Dbuilt_in_models=true \
    -Denable_avx512=true \
    --buildtype release
ninja -vC libvmaf/build -j$(nproc)
ninja -vC libvmaf/build install

cd "$HOME/build_temp"
if [ -f "$HOME/build_temp/lib/libvmaf.a" ]; then
    echo "Verification: libvmaf.a found at $HOME/build_temp/lib/libvmaf.a"
else
    echo "ERROR: libvmaf.a NOT found. VMAF static library build might have failed."
    exit 1
fi

# --- 7. Install DAV1D (static build) ---
echo "Building DAV1D (static library)..."
if [ ! -d "dav1d" ]; then
    git clone https://code.videolan.org/videolan/dav1d.git
fi
cd dav1d
git checkout master # Use master for latest dav1d

cd "${HOME}/build_temp/dav1d"
# Clean up previous build directory before configuring
if [ -d "build" ]; then
    rm -rf build
fi
# FIX: Added --libdir=lib to force installation to $HOME/build_temp/lib
meson setup build \
    --prefix="$HOME/build_temp" \
    --default-library=static \
    --libdir=lib \
    -Denable_tests=false \
    -Denable_docs=false \
    --buildtype release
ninja -vC build -j$(nproc)
ninja -vC build install

cd "$HOME/build_temp"
if [ -f "$HOME/build_temp/lib/libdav1d.a" ]; then
    echo "Verification: libdav1d.a found at $HOME/build_temp/lib/libdav1d.a"
else
    echo "ERROR: libdav1d.a NOT found. DAV1D static library build might have failed."
    exit 1
fi

echo "Copying VMAF models to /usr/local/share/model/..."
sudo mkdir -p /usr/local/share/model/
# Meson installed models to the prefix, but for robustness, copy from source if not found there.
sudo cp -r "$HOME/build_temp/vmaf/model/"* /usr/local/share/model/

echo "VMAF and DAV1D built successfully."

# --- 8. Install FFmpeg ---
echo "Installing FFmpeg with VMAF (static) and CUDA support..."
cd "$HOME/build_temp"
if [ ! -d "FFmpeg" ]; then
    git clone https://github.com/FFmpeg/FFmpeg.git
fi
cd FFmpeg
git checkout "$FFMPEG_TAG"

# --- FFmpeg Diagnostic and Clean Step (FIX) ---
echo "--- PKG-CONFIG DIAGNOSTICS ---"
pkg-config --modversion dav1d || { echo "ERROR: DAV1D pkg-config check failed. Check PKG_CONFIG_PATH and installation." ; exit 1; }
pkg-config --modversion libvmaf || { echo "ERROR: VMAF pkg-config check failed. Check PKG_CONFIG_PATH and installation." ; exit 1; }
echo "--- END DIAGNOSTICS ---"

# Aggressively clean up previous build attempts and configuration logs
echo "Aggressively cleaning FFmpeg build directory..."
rm -rf ffbuild/config.log ffbuild/config.* || true
make clean || true 
# ----------------------------------------------

# Define paths relative to the $HOME/build_temp prefix
VMAF_INCLUDE_DIR="${HOME}/build_temp/include"
VMAF_LIB_DIR="${HOME}/build_temp/lib"

# The FFmpeg configuration flags are set for static linking and to explicitly find VMAF/CUDA
./configure \
  --pkg-config-flags="--static" \
  --ld="g++" \
  --extra-cflags="-I${VMAF_INCLUDE_DIR} -I${CUDA_PATH}/include" \
  --extra-ldflags="-L${VMAF_LIB_DIR} -L${CUDA_PATH}/lib64" \
  --extra-libs="-lpthread -lm -lstdc++ -ldl -lz -lvmaf -ldav1d \
  -lcudart_static -lcudadevrt -lnvrtc_static \
  -lnppc -lnppicc -lnppig -lnppim -lnpps" \
  --enable-gpl \
  --enable-libvmaf \
  --enable-static \
  --disable-shared \
  --enable-gnutls \
  --enable-nonfree \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libaom \
  --enable-libass \
  --enable-libfdk-aac \
  --enable-libfreetype \
  --enable-libmp3lame \
  --enable-libwebp \
  --enable-libvpx \
  --enable-libvorbis \
  --enable-libopus \
  --enable-libsvtav1 \
  --enable-libdav1d \
  --enable-nvdec \
  --enable-nvenc \
  --enable-cuvid \
  --enable-cuda \
  --enable-cuda-nvcc \
  --enable-ffnvcodec \
  --enable-lv2

echo "Compiling FFmpeg (this may take a while)..."
make -j$(nproc)

echo "Installing FFmpeg..."
sudo make install

cd "$HOME/build_temp"
echo "FFmpeg installed successfully."

# --- 9. Data Directory and Test Files ---
echo "Creating data directory and downloading test video..."
mkdir -p "$HOME/build/data"
cd "$HOME/build/data"

if [ ! -f "ref.mp4" ]; then
    curl -o ref.mp4 https://videos.pexels.com/video-files/4307941/4307941-uhd_2560_1440_30fps.mp4
    echo "Downloaded ref.mp4"
else
    echo "ref.mp4 already exists, skipping download."
fi

echo "Converting ref.mp4 to dist-nvenc.mp4 using h264_nvenc (Checking CUDA Runtime)..."
# We rely on ldconfig for permanent system visibility of CUDA libraries
ffmpeg -i ref.mp4 -c:v h264_nvenc -preset fast -pix_fmt yuv420p dist-nvenc.mp4

echo "Test video converted."

# --- 10. Verify FFmpeg Capabilities and Run VMAF Analysis ---
echo "Verifying FFmpeg hardware acceleration and encoders..."
ffmpeg -hwaccels
ffmpeg -encoders

echo "Running GPU VMAF analysis with GPU decoding (libvmaf_cuda)..."
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/ref.mp4" \
    -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda" \
    -f null -

echo "Running CPU VMAF analysis (libvmaf)..."
ffmpeg \
    -i "${HOME}/build/data/ref.mp4" \
    -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale=w=-2:h=720:sws_flags=lanczos,format=yuv420p[ref];[1:v]scale=w=-2:h=720:sws_flags=lanczos,format=yuv420p[dist];[dist][ref]libvmaf" \
    -f null -

# --- 11. Cleanup ---
echo "Deactivating Python virtual environment..."
deactivate

echo "Script finished successfully!"
echo ""
echo "You can find the test files in $HOME/build/data."
ffmpeg -version
echo "---------------------------------------------------"
echo "To run the GPU VMAF analysis again, use:"
echo ""
echo "ffmpeg \\"
echo "    -hwaccel cuda -hwaccel_output_format cuda -i \"${HOME}/build/data/ref.mp4\" \\"
echo "    -hwaccel cuda -hwaccel_output_format cuda -i \"${HOME}/build/data/dist-nvenc.mp4\" \\"
echo "    -filter_complex \"[0:v]scale_cuda=1280:-2:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=1280:-2:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda\" \\"
echo "    -f null -"
echo "---------------------------------------------------"
