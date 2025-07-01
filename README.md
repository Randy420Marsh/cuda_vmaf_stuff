It took a whole day to get the libvmaf_cuda build to finally complete.
And then i tried to build a static binary but failed.
So i made a script to automate the build, while its not fully static it should provide a starting point
if you are completely lost how to build the cuda accelerated ffmpeg version with cuda accelerated vmaf "libvmaf_cuda".

It is several times faster than the stantard version and the "ffmpeg_vmaf_cuda_build_script_hw.sh"
script will run after a successful build a comparison run for cuda and cpu version.
