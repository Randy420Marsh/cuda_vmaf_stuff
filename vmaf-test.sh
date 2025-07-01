#!/bin/bash

#----------------------
# Correct LD_LIBRARY_PATH (fix typo: $/usr/local/cuda -> /usr/local/cuda)
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/x86_64-linux/lib:${LD_LIBRARY_PATH}"

# Show dynamic linker help
/lib64/ld-linux-x86-64.so.2 --help

echo "You can do this:"
echo "sudo nano /etc/ld.so.conf"
echo
echo "Add these in the file and run"
echo "sudo ldconfig"
echo "/usr/local/cuda-12.8/lib64"
echo "/usr/local/cuda-12.8/targets/x86_64-linux/lib"

#----------------------

# Add CUDA stubs and local lib to ld.so.conf.d
sudo bash -c "echo '${CUDA_PATH}/lib64/stubs/' > /etc/ld.so.conf.d/cuda-stubs.conf"
sudo bash -c "echo '/usr/local/lib' > /etc/ld.so.conf.d/vmaf-local.conf"
sudo ldconfig

# Download test video if not present
mkdir -p "${HOME}/build/data"
if [ ! -f "${HOME}/build/data/ref.mp4" ]; then
    curl -o "${HOME}/build/data/ref.mp4" https://videos.pexels.com/video-files/4307941/4307941-uhd_2560_1440_30fps.mp4
    echo "Downloaded ref.mp4"
else
    echo "ref.mp4 already exists, skipping download."
fi

# Convert reference video to MP4s with x264 and NVENC
echo "Converting ref.mp4 to dist-x264.mp4 using libx264..."
ffmpeg -i "${HOME}/build/data/ref.mp4" -c:v libx264 -preset fast -pix_fmt yuv420p "${HOME}/build/data/dist-x264.mp4"
echo "Converting ref.mp4 to dist-nvenc.mp4 using h264_nvenc..."
ffmpeg -i "${HOME}/build/data/ref.mp4" -c:v h264_nvenc -preset p7 -pix_fmt yuv420p "${HOME}/build/data/dist-nvenc.mp4"
echo "Test videos converted."

# --- Verify FFmpeg Capabilities and Run VMAF Analysis ---
echo "Verifying FFmpeg hardware acceleration and encoders..."
ffmpeg -hwaccels
ffmpeg -encoders

echo "Running VMAF analysis with CPU decoding (libvmaf, software)..."
ffmpeg -i "${HOME}/build/data/ref.mp4" -i "${HOME}/build/data/dist-x264.mp4" -filter_complex "[0:v]scale=1920:1080[ref];[1:v]scale=1920:1080[dist];[dist][ref]libvmaf" -f null -

echo "Running VMAF analysis with GPU decoding and libvmaf_cuda (recommended configuration)..."
# Use -hwaccel cuda -hwaccel_output_format cuda BEFORE EACH -i
ffmpeg \
  -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/ref.mp4" \
  -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/dist-x264.mp4" \
  -filter_complex "[0:v]scale_cuda=1920:1080:format=yuv420p[ref];[1:v]scale_cuda=1920:1080:format=yuv420p[dist];[dist][ref]libvmaf_cuda" \
  -f null -

ffmpeg \
  -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/ref.mp4" \
  -hwaccel cuda -hwaccel_output_format cuda -i "${HOME}/build/data/dist-nvenc.mp4" \
  -filter_complex "[0:v]scale_cuda=1920:1080:format=yuv420p[ref];[1:v]scale_cuda=1920:1080:format=yuv420p[dist];[dist][ref]libvmaf_cuda" \
  -f null -

echo "VMAF analysis commands executed. Script will pause for 5 seconds."
sleep 5
