#!/bin/bash

# IMPORTANT:
# This script uses CUDA 13.1 Toolkit paths.
# It intentionally uses older NV-CODEC-HEADERS (n12.1.148) because
# libvmaf 3.0.0 cannot compile against the newer n13 headers.
# This combination is valid and works on Driver 590.44.

set -e

# --- 1. Define Versions ---
CUDA_VERSION="12.8"
CUDA_PATH="/usr/local/cuda-${CUDA_VERSION}"

# "Golden" version for VMAF 3.0 compatibility
NV_CODEC_HEADERS_TAG="n12.2.72.0" 

VMAF_TAG="v3.0.0"
FFMPEG_TAG="n8.1-dev"
LIBPLACEBO_TAG="v7.351.0" 
LCMS_VERSION="2.17"
LV2_VERSION="1.18.10"

echo "Using CUDA Toolkit: $CUDA_VERSION"
echo "Using Codec Headers: $NV_CODEC_HEADERS_TAG"

# --- 2. Environment Setup ---
mkdir -p "$HOME/build_temp"
cd "$HOME/build_temp"

# Reset Python Environment
if [ -d "venv" ]; then rm -rf venv; fi
python3 -m venv venv
source ./venv/bin/activate
pip install meson Jinja2

# Prioritize our custom build paths
export PKG_CONFIG_PATH="$HOME/build_temp/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
export PATH="${CUDA_PATH}/bin:${PATH}"

# IMPORTANT: We add the CUDA targets lib, but NOT the generic lib64 
# to avoid picking up stubs during the wrong phase.
export LIBRARY_PATH="/usr/local/lib:${CUDA_PATH}/targets/x86_64-linux/lib"

# --- 3. THE "POISON" FIX (CRITICAL) ---
# We must remove the broken NVENC stubs from the CUDA 13.1 toolkit
# or FFmpeg will link to them and fail at runtime.
echo "Removing broken NVENC stubs from CUDA Toolkit..."
sudo rm -f ${CUDA_PATH}/targets/x86_64-linux/lib/libnvidia-encode.so*
sudo rm -f ${CUDA_PATH}/lib64/libnvidia-encode.so*

# Clean up system headers to avoid conflicts
sudo rm -rf /usr/local/include/ffnvcodec
sudo rm -rf /usr/local/lib/pkgconfig/ffnvcodec.pc

# FORCE CLEAN build directories to ensure we get the right git tags
rm -rf "$HOME/build_temp/nv-codec-headers"
rm -rf "$HOME/build_temp/vmaf"

# Update Linker Cache
sudo ldconfig

# --- 4. Dependencies ---
sudo apt-get update -qq
sudo apt-get -y install \
  autoconf automake build-essential cmake git libass-dev libfreetype6-dev \
  libgnutls28-dev libmp3lame-dev libsdl2-dev libtool libva-dev libvdpau-dev \
  libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev nasm ninja-build \
  pkg-config python3-pip texinfo yasm zlib1g-dev libunistring-dev \
  libx264-dev libx265-dev libnuma-dev libfdk-aac-dev libopus-dev libwebp-dev \
  libvpx-dev libplacebo-dev asciidoc unzip wget xxd

# --- 5. Build Components ---

# 5.1 LCMS2
echo "Building lcms2..."
cd "$HOME/build_temp"
LCMS_ARCHIVE="lcms2-${LCMS_VERSION}.tar.gz"
wget -q -c "https://github.com/mm2/Little-CMS/releases/download/lcms${LCMS_VERSION}/${LCMS_ARCHIVE}"
tar xzf ${LCMS_ARCHIVE}
cd lcms2-${LCMS_VERSION}
./configure --prefix="$HOME/build_temp" --enable-shared
make -j$(nproc)
make install
cd "$HOME/build_temp"

# 5.2 NV-CODEC-HEADERS
echo "Installing nv-codec-headers..."
cd "$HOME/build_temp"
git clone https://github.com/FFmpeg/nv-codec-headers.git
cd nv-codec-headers
git checkout "$NV_CODEC_HEADERS_TAG"
make
sudo make install

# 5.3 VMAF (Shared with CUDA)
echo "Building VMAF..."
cd "$HOME/build_temp"
git clone https://github.com/Netflix/vmaf.git
cd vmaf
git checkout "$VMAF_TAG"
cd libvmaf
meson setup build \
    --prefix="$HOME/build_temp" \
    --default-library=shared \
    --libdir=lib \
    -Denable_tests=false \
    -Denable_cuda=true \
    -Denable_docs=false \
    -Dbuilt_in_models=true \
    -Denable_avx512=true \
    --buildtype release
ninja -vC build install

# Fix Model Paths
sudo mkdir -p /usr/local/share/vmaf/model/
sudo cp -r "$HOME/build_temp/vmaf/model/"* /usr/local/share/vmaf/model/

# 5.4 DAV1D
echo "Building DAV1D..."
cd "$HOME/build_temp"
if [ ! -d "dav1d" ]; then git clone https://code.videolan.org/videolan/dav1d.git; fi
cd dav1d
git checkout master
if [ -d "build" ]; then rm -rf build; fi
meson setup build \
    --prefix="$HOME/build_temp" \
    --default-library=shared \
    --libdir=lib \
    -Denable_tests=false \
    --buildtype release
ninja -vC build install

# --- 5.4.5 Build SVT-AV1 (Another AV1 Encoder) ---
cd "$HOME/build_temp"
echo "Building SVT-AV1..."
git -C SVT-AV1 pull 2> /dev/null || git clone https://gitlab.com/AOMediaCodec/SVT-AV1.git
mkdir -p SVT-AV1/build
cd SVT-AV1/build
cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$HOME/build_temp" -DCMAKE_BUILD_TYPE=Release -DBUILD_DEC=OFF -DBUILD_SHARED_LIBS=ON ..
make -j$(nproc)
make install

# 5.5 LV2
echo "Building LV2..."
cd "$HOME/build_temp"
if [ ! -d "lv2-${LV2_VERSION}" ]; then
    curl -o "lv2-${LV2_VERSION}.tar.xz" "https://lv2plug.in/spec/lv2-${LV2_VERSION}.tar.xz"
    tar xf lv2-${LV2_VERSION}.tar.xz
fi
cd lv2-${LV2_VERSION}
if [ -d "build" ]; then rm -rf build; fi
meson setup build \
    --prefix="$HOME/build_temp" \
    --buildtype=release \
    --default-library=shared \
    --libdir="$HOME/build_temp/lib" \
    -Ddocs=disabled \
    -Dtests=disabled
ninja -C build install

# 5.6 Libplacebo
echo "Building libplacebo..."
cd "$HOME/build_temp"
if [ ! -d "libplacebo" ]; then git clone https://github.com/haasn/libplacebo.git; fi
cd libplacebo
git checkout "$LIBPLACEBO_TAG"
git submodule update --init --recursive
# Patch for Python 3.12+ ElementTree issue
sed -i 's/registry = VkXML(ET.parse(xmlfile))/registry = VkXML(ET.parse(xmlfile).getroot())/' src/vulkan/utils_gen.py
if [ -d "build" ]; then rm -rf build; fi
meson setup build \
    --prefix="$HOME/build_temp" \
    --default-library=shared \
    --libdir=lib \
    -Dshaderc=enabled \
    -Dvulkan=enabled \
    --buildtype release
ninja -vC build install

# --- Optional: Build AOM from Source ---
echo "Building AOM..."
cd "$HOME/build_temp"
git -C aom pull 2> /dev/null || git clone --depth 1 https://aomedia.googlesource.com/aom
mkdir -p aom_build
cd aom_build
cmake -G "Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX="$HOME/build_temp" \
    -DENABLE_TESTS=OFF \
    -DENABLE_NASM=on \
    -DBUILD_SHARED_LIBS=ON \
    ../aom
make -j$(nproc)
make install

# --- 6. Build FFmpeg ---
echo "Building FFmpeg..."
cd "$HOME/build_temp"
if [ ! -d "FFmpeg" ]; then git clone https://github.com/FFmpeg/FFmpeg.git; fi
cd FFmpeg
git checkout "$FFMPEG_TAG"

# Clean previous build
make distclean || true

# CONFIGURE
# Note: RPATH is set to build_temp/lib so it finds our custom libs (vmaf, dav1d, etc)
# But we DO NOT put CUDA in RPATH, forcing it to look at system (driver) libs.
./configure \
  --prefix="/usr/local" \
  --enable-gpl \
  --enable-nonfree \
  --enable-shared \
  --disable-static \
  --enable-gnutls \
  --enable-lcms2 \
  --enable-lv2 \
  --enable-libvmaf \
  --enable-libdav1d \
  --enable-libplacebo \
  --enable-libshaderc \
  --enable-vulkan \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libaom \
  --enable-libsvtav1 \
  --enable-libass \
  --enable-libfdk-aac \
  --enable-libfreetype \
  --enable-libharfbuzz \
  --enable-libfontconfig \
  --enable-libfribidi \
  --enable-libmp3lame \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libvpx \
  --enable-libwebp \
  --enable-cuda \
  --enable-nvenc \
  --enable-nvdec \
  --enable-cuvid \
  --enable-ffnvcodec \
  --extra-cflags="-I${HOME}/build_temp/include -I${CUDA_PATH}/include" \
  --extra-ldflags="-L${HOME}/build_temp/lib -Wl,-rpath,${HOME}/build_temp/lib" \
  --extra-libs="-lpthread -lm -ldl"

echo "Compiling FFmpeg..."
make -j$(nproc)

echo "Installing..."
sudo make install
sudo ldconfig

echo "FFmpeg Build Complete."

# --- 7. Verification Test ---
echo "Running Validation Test..."
mkdir -p "$HOME/build/data"
cd "$HOME/build/data"
if [ ! -f "ref.mp4" ]; then
    curl -o ref.mp4 https://videos.pexels.com/video-files/4307941/4307941-uhd_2560_1440_30fps.mp4
fi

# Use sudo/sg logic here if you aren't logged in with video groups
echo "Testing NVENC..."
ffmpeg -y -i ref.mp4 -c:v h264_nvenc -preset p5 -pix_fmt yuv420p dist-nvenc.mp4

echo "Testing VMAF CUDA..."
VMAF_MODEL="version=vmaf_v0.6.1"
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i ref.mp4 \
    -hwaccel cuda -hwaccel_output_format cuda -i dist-nvenc.mp4 \
    -filter_complex "[0:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda=shortest=true:ts_sync_mode=nearest:model=$VMAF_MODEL" \
    -f null -

echo "DONE."
