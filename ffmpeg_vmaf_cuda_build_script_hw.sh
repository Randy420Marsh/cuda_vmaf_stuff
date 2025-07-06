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

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Set Environment Variables for CUDA and Libraries ---
# These are crucial for the build process to find CUDA components.
# LD_LIBRARY_PATH is for runtime linking. This is crucial for the "cannot open shared object file" error.
# It tells the system where to look for shared libraries when executing a program.
# LIBRARY_PATH is for compile-time linking.
# Add CUDA bin to PATH

# Note: For static builds, LD_LIBRARY_PATH is less critical for the final binary,
# but it's still needed for tools run during the build (like pkg-config if it needs to find shared libs).
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:$HOME/build_temp/lib/pkgconfig"
export LIBRARY_PATH="/usr/local/lib:/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib"
export CUDA_PATH="/usr/local/cuda-12.8"
export PATH="${CUDA_PATH}/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/lib:${CUDA_PATH}/lib64:${CUDA_PATH}/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"

# The following lines were instructional echoes. They are removed as they are not executable commands.
# /lib64/ld-linux-x86-64.so.2 --help
# echo "You can do this:"
# echo "sudo nano /etc/ld.so.conf"
# echo. # This was an error, should be 'echo ""' or 'echo'
# echo "Add these in the file and run"
# echo "sudo ldconfig"
# echo "/usr/local/cuda-12.8/lib64"
# echo "/usr/local/cuda-12.8/targets/x86_64-linux/lib"

# --- Add CUDA Stubs to ldconfig (only for runtime, not build path) ---
echo "Adding CUDA stubs to ldconfig and updating shared library cache..."
# This command correctly adds the CUDA stubs path to ld.so.conf.d
sudo bash -c "echo '${CUDA_PATH}/lib64/stubs/' > /etc/ld.so.conf.d/cuda-stubs.conf"
# DO NOT add /usr/local/lib here for VMAF. VMAF will be linked statically
# and its shared library should not be installed system-wide to avoid conflicts.
sudo ldconfig
echo "CUDA stubs configured for ldconfig."

echo "Updating package list and installing core build dependencies..."
sudo apt-get update -qq && sudo apt-get -y install \
  autoconf \
  automake \
  build-essential \
  cmake \
  curl \
  git \
  git-core \
  libass-dev \
  libdav1d-dev \
  libfdk-aac-dev \
  libfreetype6-dev \
  libgnutls28-dev \
  libmp3lame-dev \
  libnuma-dev \
  libopenjp2-7-dev \
  libsdl2-dev \
  libssl-dev \
  libtool \
  libva-dev \
  libvdpau-dev \
  libwebp-dev \
  libvpx-dev \
  libvorbis-dev \
  libopus-dev \
  libx264-dev \
  libx265-dev \
  libxcb1-dev \
  libxcb-shm0-dev \
  libxcb-xfixes0-dev \
  meson \
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
  zlib1g-dev

echo "Core dependencies installed."

echo "Starting VMAF and FFmpeg build process for Ubuntu 24.04..."

# --- 1. Define Variables ---
VMAF_TAG="master" # Using 'master' branch for VMAF
FFMPEG_TAG="master" # Using 'master' branch for FFmpeg
NV_CODEC_HEADERS_TAG="master" # Using 'master' branch for NVIDIA codec headers

echo "Using VMAF tag: $VMAF_TAG"
echo "Using FFmpeg tag: $FFMPEG_TAG"
echo "Expecting CUDA in ${CUDA_PATH}"

# --- 2. Update System and Install Core Dependencies ---
# The previous `sudo apt-get update` was redundant as it's done above. Removed.

# --- 3. Clone Repositories ---
echo "Cloning VMAF, FFmpeg, and nv-codec-headers repositories..."

# Create a temporary directory for cloning if it doesn't exist
mkdir -p "$HOME/build_temp"
mkdir -p "$HOME/build_temp/bin" # Ensure this directory exists for installations
cd "$HOME/build_temp"

# Removed commented out `rm -rf` lines.

# Build AOM
cd "$HOME/build_temp" && \
git -C aom pull 2> /dev/null || git clone --depth 1 https://aomedia.googlesource.com/aom && \
mkdir -p aom_build && \
cd aom_build && \
# Corrected PATH to point to $HOME/build_temp/bin for cmake
PATH="$HOME/build_temp/bin:$PATH" cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$HOME/build_temp" -DENABLE_TESTS=OFF -DENABLE_NASM=on ../aom && \
\
# Check if aom executable already exists in $HOME/build_temp/bin
# Corrected path for the file existence check
if [ -f "$HOME/build_temp/bin/aomenc" ]; then
  echo "aom already exists in $HOME/build_temp/bin. Skipping recompilation and installation."
else
  echo "aom not found or needs recompilation. Building and installing..."
  PATH="$HOME/build_temp/bin:$PATH" make && \
  make install
fi

# Build SVT-AV1
cd "$HOME/build_temp" && \
git -C SVT-AV1 pull 2> /dev/null || git clone https://gitlab.com/AOMediaCodec/SVT-AV1.git && \
mkdir -p SVT-AV1/build && \
cd SVT-AV1/build && \
# Corrected PATH to point to $HOME/build_temp/bin for cmake
PATH="$HOME/build_temp/bin:$PATH" cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$HOME/build_temp" -DCMAKE_BUILD_TYPE=Release -DBUILD_DEC=OFF -DBUILD_SHARED_LIBS=OFF .. && \
\
# Check if SvtAv1EncApp executable already exists in $HOME/build_temp/bin
if [ -f "$HOME/build_temp/bin/SvtAv1EncApp" ]; then
  echo "SvtAv1EncApp already exists in $HOME/build_temp/bin. Skipping recompilation and installation."
else
  echo "SvtAv1EncApp not found or needs recompilation. Building and installing..."
  PATH="$HOME/build_temp/bin:$PATH" make && \
  make install
fi

cd "$HOME/build_temp" && \
curl -o "lv2-1.18.10.tar.xz" "https://lv2plug.in/spec/lv2-1.18.10.tar.xz" && \
meson build --prefix="$HOME/build_temp/" --buildtype=release --default-library=static --libdir="$HOME/build_temp/lib" && \
ninja -C build && \
ninja -C build install

cd "$HOME/build_temp/"
# Clone nv-codec-headers and build/install them.
if [ ! -d "nv-codec-headers" ]; then
    git clone https://github.com/FFmpeg/nv-codec-headers.git
fi
cd nv-codec-headers
git checkout "$NV_CODEC_HEADERS_TAG"
echo "Building and installing nv-codec-headers..."
make
sudo make install
cd "$HOME/build_temp/" # Go back to $HOME/build_temp

echo "Repositories cloned and nv-codec-headers installed."

# --- Install VMAF (static build) ---
echo "Installing VMAF (static library only)..."
python3 -m pip install meson
# python3 --version # This line is for debugging, not necessary for script execution.

cd "$HOME/build_temp/"
# Clone VMAF repository and checkout specified tag
if [ ! -d "vmaf" ]; then
    git clone https://github.com/Netflix/vmaf.git
fi
cd vmaf
git checkout "$VMAF_TAG"

cd "${HOME}/build_temp/vmaf" && \
    meson setup --reconfigure \
    libvmaf/build libvmaf \
    --default-library=static \
    -Denable_tests=false \
    -Denable_cuda=true \
    -Denable_docs=false \
    -Dbuilt_in_models=true \
    -Denable_avx512=true \
    --buildtype release && \
    ninja -vC libvmaf/build

cd "$HOME/build_temp/"
if [ -f "$HOME/build_temp/vmaf/libvmaf/build/src/libvmaf.a" ]; then
    echo "Verification: libvmaf.a found at $HOME/build_temp/vmaf/libvmaf/build/src/"
else
    echo "ERROR: libvmaf.a NOT found at $HOME/build_temp/vmaf/libvmaf/build/src/. VMAF static library build might have failed."
    exit 1
fi

echo "Copying VMAF models to /usr/local/share/model/..."
sudo mkdir -p /usr/local/share/model/
sudo cp -r "$HOME/build_temp/vmaf/model/"* /usr/local/share/model/

echo "VMAF static library built and models copied."

# --- Install FFmpeg ---
echo "Installing FFmpeg with VMAF (static) and CUDA support..."
cd "$HOME/build_temp/" # Ensure we are in build_temp before cloning/cd'ing to FFmpeg
# Clone FFmpeg repository and checkout specified tag
if [ ! -d "FFmpeg" ]; then
    git clone https://github.com/FFmpeg/FFmpeg.git
fi
cd FFmpeg # Added cd into FFmpeg directory before git checkout
git checkout "$FFMPEG_TAG"

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
  --enable-libvorbis \
  --enable-libvpx \
  --enable-nvdec \
  --enable-nvenc \
  --enable-cuvid \
  --enable-cuda \
  --enable-cuda-nvcc \
  --enable-ffnvcodec \
  --enable-lv2 
# --disable-stripping

echo "Compiling FFmpeg (this may take a while)..."
make -j$(nproc)

echo "Installing FFmpeg..."
sudo make install

cd "$HOME/build_temp" # Go back to $HOME/build_temp
echo "FFmpeg installed successfully."

# --- 7. Data Directory and Test Files ---
echo "Creating data directory and downloading test video..."
mkdir -p "$HOME/build/data"
cd "$HOME/build/data"

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

echo "Running GPU VMAF analysis with GPU decoding (this will output to null)..."
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/ref.mp4" \
    -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=-2:1080:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda" \
    -f null -

echo "GPU VMAF analysis command executed. Script will pause for 1 seconds."
sleep 1 # sleep duration

echo "Running CPU VMAF analysis with CPU decoding (this will output to null)..."
ffmpeg -i "${HOME}/build/data/ref.mp4" \
    -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale=-2:1080:flags=lanczos[ref];[1:v]scale=-2:1080:flags=lanczos[dist];[dist][ref]libvmaf=threads=$(nproc)" \
    -f null -

echo "CPU VMAF analysis command executed. Script will pause for 1 seconds."
sleep 1 # sleep duration

ffmpeg \
    -i "${HOME}/build/data/ref.mp4" \
    -i "${HOME}/build/data/dist-nvenc.mp4" \
    -filter_complex "[0:v]scale=w=-2:h=720:sws_flags=lanczos,format=yuv420p[ref];[1:v]scale=w=-2:h=720:sws_flags=lanczos,format=yuv420p[dist];[dist][ref]libvmaf" \
    -f null -

echo "CPU VMAF analysis command executed. Script will pause for 1 seconds."
sleep 1 # sleep duration

ffmpeg -version

echo "Script finished successfully!"
echo ""
echo "You can find the test files in $HOME/build/data."
echo "To run the VMAF analysis again, use:"
echo ""
echo "ffmpeg \\"
echo "    -hwaccel cuda -hwaccel_output_format cuda -i \"${HOME}/build/data/ref.mp4\" \\"
echo "    -hwaccel cuda -hwaccel_output_format cuda -i \"${HOME}/build/data/dist-nvenc.mp4\" \\"
echo "    -filter_complex \"[0:v]scale_cuda=1280:-2:format=yuv420p:interp_algo=lanczos[ref];[1:v]scale_cuda=1280:-2:format=yuv420p:interp_algo=lanczos[dist];[dist][ref]libvmaf_cuda\" \\"
echo "    -f null -"
echo "---------------------------------------------------"
echo "You can do this:"
echo "sudo nano /etc/ld.so.conf"
echo "---------------------------------------------------"
echo "Add these in the file because:"
echo "---------------------------------------------------"
echo "/usr/local/cuda-12.8/lib64"
echo "/usr/local/cuda-12.8/targets/x86_64-linux/lib"
echo "---------------------------------------------------"
echo "and run:"
echo "sudo ldconfig"
echo "---------------------------------------------------"
echo "Notes on static linking:"
echo "Because of the NSS (Name Service Switch), glibc does not recommend static links. See more details here."
echo "https://sourceware.org/glibc/wiki/FAQ#Even_statically_linked_programs_need_some_shared_libraries_which_is_not_acceptable_for_me.__What_can_I_do.3F"
echo "The libnpp in the CUDA SDK cannot be statically linked."
echo "Vaapi cannot be statically linked."
