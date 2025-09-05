It took a whole day to get the libvmaf_cuda build to finally complete.
And then i tried to build a static binary but it failed.

So i made a script to automate the build, while its not fully static it should provide a starting point
if you are completely lost on how to build the cuda and nvenc accelerated ffmpeg version with cuda accelerated vmaf "libvmaf_cuda".

It is several times faster than the stantard version.

```
Notes on static linking:
Because of the NSS (Name Service Switch), glibc does not recommend static links. See more details here.
https://sourceware.org/glibc/wiki/FAQ#Even_statically_linked_programs_need_some_shared_libraries_which_is_not_acceptable_for_me.__What_can_I_do.3F
The libnpp in the CUDA SDK cannot be statically linked.
Vaapi cannot be statically linked.
```

```
ffmpeg -version
ffmpeg version N-120987-gfb4407797e Copyright (c) 2000-2025 the FFmpeg developers
built with gcc 12 (Ubuntu 12.4.0-2ubuntu1~24.04)
configuration: --pkg-config-flags=--static --ld=g++ --extra-cflags='-I/usr/local/include -I/usr/local/cuda-12.8/include -I/home/john/build_temp/vmaf/libvmaf/src -I/home/john/build_temp/vmaf/libvmaf/include' --extra-ldflags='-L/usr/local/lib -L/usr/local/cuda-12.8/lib64 -L/home/john/build_temp/vmaf/libvmaf/build/src' --extra-libs='-lpthread -lm -lstdc++ -ldl -lz -lvmaf -lcudart_static -lcudadevrt -lnvrtc_static -lnppc_static -lnppial_static -lnppicc_static -lnppidei_static -lnppif_static -lnppig_static -lnppim_static -lnppist_static -lnppisu_static -lnppitc_static -lnpps_static' --enable-gpl --enable-libvmaf --enable-static --disable-shared --enable-gnutls --enable-libnpp --enable-nonfree --enable-libx264 --enable-libx265 --enable-libaom --enable-libass --enable-libfdk-aac --enable-libfreetype --enable-libmp3lame --enable-libwebp --enable-libvpx --enable-libvorbis --enable-libopus --enable-libsvtav1 --enable-libdav1d --enable-libvorbis --enable-libvpx --enable-nvdec --enable-nvenc --enable-cuvid --enable-cuda --enable-cuda-nvcc --enable-ffnvcodec --enable-lv2
libavutil      60. 12.100 / 60. 12.100
libavcodec     62. 15.100 / 62. 15.100
libavformat    62.  4.102 / 62.  4.102
libavdevice    62.  2.100 / 62.  2.100
libavfilter    11.  8.100 / 11.  8.100
libswscale      9.  3.100 /  9.  3.100
libswresample   6.  2.100 /  6.  2.100

Exiting with exit code 0
```
