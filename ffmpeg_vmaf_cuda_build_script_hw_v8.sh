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
pip install meson Jinja2
echo "Python virtual environment configured."

# --- Set Environment Variables for CUDA and Libraries ---
# These are crucial for the build process to find CUDA components and custom libraries.
CUDA_VERSION="13.0"
CUDA_PATH="/usr/local/cuda-${CUDA_VERSION}"

# FIX: Explicitly prioritize the custom pkgconfig path over system paths,
# including the new custom install location /usr/local/lib/pkgconfig.
export PKG_CONFIG_PATH="$HOME/build_temp/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig"
export LIBRARY_PATH="/usr/local/lib:${CUDA_PATH}/lib64:${CUDA_PATH}/targets/x86_64-linux/lib"
export CUDA_PATH="${CUDA_PATH}"
export PATH="${CUDA_PATH}/bin:${PATH}"

# --- Add CUDA Libraries to ldconfig (PERMANENT FIX FOR RUNTIME) ---
sudo ldconfig
echo "System dynamic linker cache updated. FFmpeg should now find CUDA libraries at runtime."

# --- REMOVE CONFLICTING SYSTEM PACKAGE ---
echo "PURGING CONFLICTING SYSTEM PACKAGE: libdav1d-dev (version 0.9.2)..."
sudo apt-get purge -y libdav1d-dev || true

echo "Updating package list and installing core build dependencies (excluding liblcms2-dev)..."
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

# --- 0. Build lcms2 v2.17 (Required by FFmpeg's --enable-lcms2) ---
echo "--- Building lcms2 v2.17 (Little CMS 2) ---"

LCMS_VERSION="2.17"
LCMS_URL="https://github.com/mm2/Little-CMS/releases/download/lcms${LCMS_VERSION}/lcms2-${LCMS_VERSION}.tar.gz"
LCMS_ARCHIVE="lcms2-${LCMS_VERSION}.tar.gz"
# SHA256 hash provided: d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074
LCMS_HASH="d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074"

# Ensure we are in the main build directory
cd "$HOME/build_temp"

echo "Downloading lcms2 v${LCMS_VERSION}..."
wget -q --show-progress ${LCMS_URL}

echo "Verifying SHA256 hash..."
# Check the hash and verify
echo "${LCMS_HASH}  ${LCMS_ARCHIVE}" | sha256sum --check --status
if [ $? -ne 0 ]; then
    echo "ERROR: SHA256 checksum failed for ${LCMS_ARCHIVE}. Aborting build."
    exit 1
fi
echo "SHA256 hash verified successfully."

# Extract and build
echo "Extracting and building lcms2..."
tar xzf ${LCMS_ARCHIVE}
cd lcms2-${LCMS_VERSION}

# Configure to install to the custom prefix $HOME/build_temp.
# The pkg-config file will be in $HOME/build_temp/lib/pkgconfig
./configure --prefix="$HOME/build_temp" --enable-static 
make -j$(nproc)

# Install
make install

# Return to $HOME/build_temp
cd "$HOME/build_temp"
rm -rf lcms2-${LCMS_VERSION} ${LCMS_ARCHIVE} # Clean up source

echo "lcms2 v${LCMS_VERSION} installed to $HOME/build_temp successfully."
echo "Starting VMAF and FFmpeg build process..."

# --- 1. Define Variables ---
VMAF_TAG="v3.0.0-117-g7c4beca3"
FFMPEG_TAG="n8.1-dev-1030-g3eb0cb3b0b"
NV_CODEC_HEADERS_TAG="n13.0.19.0-2-g876af32"
LV2_VERSION="1.18.10"
LIBPLACEBO_TAG="v7.351.0" # Use a known modern version required by FFmpeg

echo "Using VMAF tag: $VMAF_TAG"
echo "Using FFmpeg tag: $FFMPEG_TAG"
echo "Expecting CUDA in ${CUDA_PATH}"
echo "Expecting CUDA in ${LV2_VERSION}"
echo "Using libplacebo tag: $LIBPLACEBO_TAG"

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

# --- 8. Build libplacebo ---
echo "Building libplacebo (required for modern FFmpeg)..."
if [ ! -d "libplacebo" ]; then
    git clone https://github.com/haasn/libplacebo.git
fi
cd libplacebo
git checkout "$LIBPLACEBO_TAG"

# FIX: Initialize and update submodules, specifically for the 'glad' dependency.
echo "Initializing and updating libplacebo submodules..."
git submodule update --init --recursive

# FIX: Patch the utils_gen.py script to fix ElementTree parsing issue
echo "Patching libplacebo utils_gen.py for Python 3.14 compatibility..."
sed -i 's/registry = VkXML(ET.parse(xmlfile))/registry = VkXML(ET.parse(xmlfile).getroot())/' src/vulkan/utils_gen.py

cd "${HOME}/build_temp/libplacebo"
if [ -d "build" ]; then
    rm -rf build
fi

# Build with Vulkan support (which we enable in FFmpeg config)
meson setup build \
    --prefix="$HOME/build_temp" \
    --default-library=static \
    --libdir=lib \
    -Dshaderc=enabled \
    -Dvulkan=enabled \
    --buildtype release
ninja -vC build -j$(nproc)
ninja -vC build install

cd "$HOME/build_temp"
if [ -f "$HOME/build_temp/lib/libplacebo.a" ]; then
    echo "Verification: libplacebo.a found."
else
    echo "ERROR: libplacebo.a NOT found. Build failed."
    exit 1
fi
echo "libplacebo built successfully."


# --- 9. Install FFmpeg ---
echo "Installing FFmpeg with VMAF (static), libplacebo, and CUDA support..."
cd "$HOME/build_temp"
if [ ! -d "FFmpeg" ]; then
    git clone https://github.com/FFmpeg/FFmpeg.git
fi
cd FFmpeg
git checkout "$FFMPEG_TAG"

# --- FFmpeg Diagnostic and Clean Step (FIX) ---
echo "--- PKG-CONFIG DIAGNOSTICS ---"
# Test for custom libraries to ensure PKG_CONFIG_PATH is working
pkg-config --modversion dav1d || { echo "ERROR: DAV1D pkg-config check failed. Check PKG_CONFIG_PATH and installation." ; exit 1; }
pkg-config --modversion libvmaf || { echo "ERROR: VMAF pkg-config check failed. Check PKG_CONFIG_PATH and installation." ; exit 1; }
pkg-config --modversion lcms2 || { echo "ERROR: lcms2 pkg-config check failed. Check PKG_CONFIG_PATH and installation." ; exit 1; }
pkg-config --modversion libplacebo || { echo "ERROR: libplacebo pkg-config check failed. Check PKG_CONFIG_PATH and installation." ; exit 1; }
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
  --prefix="/usr/local" \
  --pkg-config-flags="--static" \
  --ld="g++" \
  --extra-cflags="-I${VMAF_INCLUDE_DIR} -I${CUDA_PATH}/include" \
  --extra-ldflags="-L${VMAF_LIB_DIR} -L${CUDA_PATH}/lib64" \
  --extra-libs="-lpthread -lm -lstdc++ -ldl -lz -lvmaf -ldav1d -llcms2 -lplacebo \
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
  --enable-libharfbuzz \
  --enable-libfontconfig \
  --enable-libfribidi \
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
  --enable-lv2 \
  --enable-libplacebo \
  --enable-libshaderc \
  --enable-vulkan \
  --enable-lcms2


echo "Compiling FFmpeg (this may take a while)..."
make -j$(nproc)

echo "Installing FFmpeg..."
sudo make install

cd "$HOME/build_temp"
echo "FFmpeg installed successfully."

# --- 10. Data Directory and Test Files ---
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

# --- 11. Verify FFmpeg Capabilities and Run VMAF Analysis ---
echo "Verifying FFmpeg hardware acceleration and encoders..."
ffmpeg -hwaccels
ffmpeg -encoders

# VMAF Model configuration for libvmaf_cuda
VMAF_MODEL="version=vmaf_v0.6.1"

# For 4K: 
#VMAF_MODEL="version=vmaf_4k_v0.6.1"

echo "Running GPU VMAF analysis with GPU decoding (libvmaf_cuda)..."
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/ref.mp4" \
    -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda=shortest=true:ts_sync_mode=nearest:model=$VMAF_MODEL" \
    -f null -

echo "Running CPU VMAF analysis (libvmaf)..."
ffmpeg \
    -i "${HOME}/build/data/ref.mp4" \
    -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale=w=-2:h=1080:sws_flags=lanczos,format=yuv420p[ref];[1:v]scale=w=-2:h=1080:sws_flags=lanczos,format=yuv420p[dist];[dist][ref]libvmaf=shortest=true:ts_sync_mode=nearest:model=$VMAF_MODEL:n_threads=8" \
    -f null -

# --- 12. Cleanup ---
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
echo "    -filter_complex \"[0:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda\" \\"
echo "    -f null -"
echo "---------------------------------------------------"
