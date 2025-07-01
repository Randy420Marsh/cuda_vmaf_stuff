#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import subprocess
import json
import os
import sys
import tempfile
import re

# --- Configuration ---
DEFAULT_TARGET_VMAF = 95.0
CRF_SEARCH_RANGE_MIN = 18
CRF_SEARCH_RANGE_MAX = 51  # x264/x265 CRF range
SEARCH_PRECISION = 0.5  # How close to the target VMAF is 'good enough'
MAX_ITERATIONS = 10     # Failsafe to prevent infinite loops
SAMPLE_DURATION_SECONDS = 10  # Duration of the video sample to test

# VMAF Model configuration for libvmaf_cuda
VMAF_MODEL = 'version=vmaf_v0.6.1'
# For 4K: VMAF_MODEL = 'version=vmaf_4k_v0.6.1'

def check_dependencies():
    """Checks if required command-line tools (ffmpeg, ffprobe) are available."""
    dependencies = ['ffmpeg', 'ffprobe']
    for dep in dependencies:
        try:
            subprocess.run([dep, '-version'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            if dep == 'ffmpeg':
                # Check if ffmpeg has libvmaf_cuda support
                result = subprocess.run(['ffmpeg', '-hide_banner', '-filters'], capture_output=True, text=True, check=True)
                if 'libvmaf_cuda' not in result.stdout:
                    print(f"Error: ffmpeg found, but it does not seem to have libvmaf_cuda filter enabled.")
                    print("Please ensure your ffmpeg build includes --enable-libvmaf --enable-cuda-sdk")
                    sys.exit(1)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print(f"Error: Required dependency '{dep}' not found in your system's PATH.")
            print("Please install it and ensure it's accessible.")
            sys.exit(1)
    print("All necessary dependencies (ffmpeg, ffprobe, and libvmaf_cuda support) are found.")

def get_video_properties(input_file):
    """Uses ffprobe to get essential properties from the input video file."""
    print(f"🔍 Probing video file: {input_file}")
    command = [
        'ffprobe',
        '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,pix_fmt,r_frame_rate,duration',
        '-of', 'json',
        input_file
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        streams = json.loads(result.stdout).get('streams', [])
        if not streams:
            raise IndexError("No video stream found.")
        properties = streams[0]

        # Get duration
        duration_str = properties.get('duration')
        if not duration_str:
            # Fallback for containers where duration is in format tags
            format_command = [
                'ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', input_file
            ]
            format_result = subprocess.run(format_command, capture_output=True, text=True, check=True)
            duration_str = json.loads(format_result.stdout).get('format', {}).get('duration', '0')
        duration = float(duration_str)

        # Get frame rate
        avg_frame_rate = properties.get('r_frame_rate', '24000/1001')
        if '/' in avg_frame_rate:
            num, den = map(int, avg_frame_rate.split('/'))
            fps = num / den if den != 0 else 24.0
        else:
            fps = float(avg_frame_rate)

        return {
            'width': properties['width'],
            'height': properties['height'],
            'pix_fmt': properties['pix_fmt'],
            'fps': fps,
            'duration': duration,
        }
    except (subprocess.CalledProcessError, KeyError, IndexError, ValueError) as e:
        print(f"Error probing video file: {e}")
        sys.exit(1)

def create_video_sample(input_file, start_time, duration, output_path):
    """Extracts a sample from the input video and saves it as an MP4 file."""
    print(f"✂️  Creating {duration}s reference sample starting at {start_time}s...")
    command = [
        'ffmpeg',
        '-v', 'error',
        '-ss', str(start_time),
        '-t', str(duration),
        '-i', input_file,
        '-c:v', 'copy',  # Copy video stream directly to avoid re-encoding
        '-an',  # No audio
        '-y',  # Overwrite output file without asking
        output_path
    ]
    try:
        subprocess.run(command, check=True)
        print(f"✅ Reference sample created: {output_path}")
    except subprocess.CalledProcessError as e:
        print(f"Error creating reference sample: {e}")
        sys.exit(1)

def encode_distorted_sample(reference_mp4, crf, output_path, props):
    """Encodes a distorted version of the reference sample using a given CRF."""
    print(f"🛠️  Encoding distorted sample with CRF {crf}...")
    encoder = 'libx264'
    # Check if h264_nvenc is available and prefer it for speed
    try:
        result = subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True, text=True, check=True)
        if 'h264_nvenc' in result.stdout:
            encoder = 'h264_nvenc'
            print("Using h264_nvenc for encoding.")
        else:
            print("h264_nvenc not found, falling back to libx264.")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Could not check for h264_nvenc, falling back to libx264.")

    if encoder == 'h264_nvenc':
        command = [
            'ffmpeg',
            '-v', 'error',
            '-i', reference_mp4,
            '-c:v', encoder,
            '-qp', str(int(crf)),  # -qp for h264_nvenc's constant quality mode, must be int
            '-preset', 'hq',
            '-y',
            output_path
        ]
    else:
        command = [
            'ffmpeg',
            '-v', 'error',
            '-i', reference_mp4,
            '-c:v', encoder,
            '-crf', str(crf),
            '-preset', 'medium',
            '-y',
            output_path
        ]
    try:
        subprocess.run(command, check=True)
        print(f"✅ Distorted sample created: {output_path}")
    except subprocess.CalledProcessError as e:
        print(f"Error creating distorted sample: {e}")
        sys.exit(1)

def run_vmaf(reference_path, distorted_path):
    """Runs VMAF comparison using ffmpeg with libvmaf_cuda filter and returns the aggregate VMAF score."""
    print(f"📊 Running VMAF for CRF using libvmaf_cuda...")

    filter_complex = (
        f"[0:v]scale_cuda=-2:-2:format=yuv420p[dis];"
        f"[1:v]scale_cuda=-2:-2:format=yuv420p[ref];"
        f"[dis][ref]libvmaf_cuda=shortest=true:ts_sync_mode=nearest:model={VMAF_MODEL}[vmaf_out]"
    )

    # Note: The log_path is not actually used, but we keep this for possible future enhancements.
    with tempfile.NamedTemporaryFile(mode='w+', delete=False, suffix=".log") as log_file:
        log_path = log_file.name

    # FIX: add -hwaccel cuda -hwaccel_output_format cuda before EACH -i
    command = [
        'ffmpeg',
        '-v', 'error',
        # Input 0 (distorted)
        '-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda',
        '-i', distorted_path,
        # Input 1 (reference)
        '-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda',
        '-i', reference_path,
        '-filter_complex', filter_complex,
        '-map', '[vmaf_out]',
        '-f', 'null',
        '-y',  # Overwrite if needed
        'NUL' if os.name == 'nt' else '/dev/null'
    ]

    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        # Parse VMAF score from stderr
        vmaf_score_match = re.search(r"VMAF score: (\d+\.\d+)", result.stderr)
        if vmaf_score_match:
            score = float(vmaf_score_match.group(1))
            print(f"📈 VMAF score: {score:.2f}")
            return score
        else:
            print("Error: Could not parse VMAF score from ffmpeg output.")
            print("FFmpeg stderr dump:", result.stderr)
            return None

    except subprocess.CalledProcessError as e:
        print(f"Error running ffmpeg with libvmaf_cuda: {e}")
        print("FFmpeg stdout:", e.stdout)
        print("FFmpeg stderr:", e.stderr)
        return None
    finally:
        if os.path.exists(log_path):
            os.remove(log_path)

def find_best_crf(input_file, target_vmaf):
    """Performs a binary search to find the CRF value that achieves the target VMAF score."""
    props = get_video_properties(input_file)
    # Create samples from the middle of the video for a representative test
    sample_start_time = max(0, (props['duration'] / 2) - (SAMPLE_DURATION_SECONDS / 2))

    with tempfile.TemporaryDirectory() as temp_dir:
        ref_path = os.path.join(temp_dir, "reference_sample.mp4")
        dist_path = os.path.join(temp_dir, "distorted_sample.mp4")
        create_video_sample(input_file, sample_start_time, SAMPLE_DURATION_SECONDS, ref_path)

        low_crf, high_crf = CRF_SEARCH_RANGE_MIN, CRF_SEARCH_RANGE_MAX
        best_crf = high_crf
        best_score_diff = float('inf')

        print("\n--- Starting CRF Search ---")
        for i in range(MAX_ITERATIONS):
            current_crf = (low_crf + high_crf) // 2
            print(f"\nIteration {i+1}/{MAX_ITERATIONS}: Testing CRF {current_crf} (Range: [{low_crf}-{high_crf}])")
            if os.path.exists(dist_path):
                os.remove(dist_path)
            encode_distorted_sample(ref_path, current_crf, dist_path, props)
            vmaf_score = run_vmaf(ref_path, dist_path)

            if vmaf_score is None:
                print("VMAF calculation failed. Aborting search for this branch.")
                low_crf = current_crf + 1
                continue

            diff = abs(vmaf_score - target_vmaf)
            if diff < best_score_diff:
                best_score_diff = diff
                best_crf = current_crf

            if diff <= SEARCH_PRECISION:
                print(f"\n🎯 Target VMAF score achieved within precision! (Score: {vmaf_score:.2f})")
                break

            if vmaf_score > target_vmaf:
                print(f"Score {vmaf_score:.2f} > {target_vmaf}. Increasing CRF.")
                low_crf = current_crf + 1
            else:
                print(f"Score {vmaf_score:.2f} < {target_vmaf}. Decreasing CRF.")
                high_crf = current_crf - 1

            if low_crf > high_crf:
                print("\nSearch range collapsed. Concluding search.")
                break

        print("\n--- Search Complete ---")
        return best_crf

def main():
    """Main function to parse arguments and run the optimizer."""
    parser = argparse.ArgumentParser(
        description="Find the optimal CRF for a target VMAF score using ffmpeg's libvmaf_cuda.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument(
        '-i', '--input',
        required=True,
        help="Path to the input video file."
    )
    parser.add_argument(
        '-t', '--target-vmaf',
        type=float,
        default=DEFAULT_TARGET_VMAF,
        help=f"The target VMAF score to aim for (default: {DEFAULT_TARGET_VMAF})."
    )
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"Error: Input file not found at '{args.input}'")
        sys.exit(1)

    check_dependencies()
    optimal_crf = find_best_crf(args.input, args.target_vmaf)

    print(f"\n🎉 Optimal CRF found: {optimal_crf}")
    print(f"This CRF value is the best estimate to achieve a VMAF score of ~{args.target_vmaf}.")
    print("\nExample FFmpeg command for full video encode:")
    print(f"ffmpeg -i \"{args.input}\" -c:v libx264 -crf {optimal_crf} -preset medium -c:a copy output.mkv")

if __name__ == '__main__':
    main()
