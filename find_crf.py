#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import subprocess
import json
import os
import sys
import tempfile
import re

#python -s find_crf.py -i "test.mp4" -e hevc_nvenc -p p7 -t 98 --min-quality-param 1 --max-quality-param 40 --search-precision 0.1 --max-iterations 10 --sample-duration 60 --save-frames-to "$HOME/cuda_vmaf_stuff/frames"

# --- Configuration (These will be overwritten by command-line arguments if provided) ---
DEFAULT_TARGET_VMAF = 95.0
QUALITY_PARAM_SEARCH_RANGE_MIN = 0
QUALITY_PARAM_SEARCH_RANGE_MAX = 51 # Max QP or common CRF max

SEARCH_PRECISION = 0.5     # How close to the target VMAF is 'good enough' (Note: Not directly used in current binary search termination logic)
MAX_ITERATIONS = 10        # Failsafe to prevent infinite loops
SAMPLE_DURATION_SECONDS = 10.0 # Duration of the video sample to test (float for precision)

# VMAF Model configuration for libvmaf_cuda
VMAF_MODEL = 'version=vmaf_v0.6.1'
# For 4K: VMAF_MODEL = 'version=vmaf_4k_v0.6.1'

def get_encoder_quality_param_info(encoder_name):
    """
    Returns a dictionary with the quality parameter flag (-qp or -crf)
    and typical min/max ranges for the given encoder.
    """
    info = {
        'flag': '-qp', # Default to -qp
        'min': QUALITY_PARAM_SEARCH_RANGE_MIN, # Use global default as fallback
        'max': QUALITY_PARAM_SEARCH_RANGE_MAX  # Use global default as fallback
    }

    if encoder_name == 'h264_nvenc' or encoder_name == 'hevc_nvenc':
        info['flag'] = '-qp'
        info['min'] = 0 # NVENC QP range is 0-51
        info['max'] = 51
    elif encoder_name == 'libx264' or encoder_name == 'libx265':
        info['flag'] = '-crf'
        info['min'] = 0 # CRF range is typically 0-51 (or 0-63 for x264, but >51 is rarely useful)
        info['max'] = 51
    # Add more encoders here as needed
    elif encoder_name == 'vp9_nvenc':
        info['flag'] = '-qp' # VP9 NVENC also uses -qp
        info['min'] = 0
        info['max'] = 63 # VP9 NVENC QP range is 0-63
    else:
        print(f"Warning: Encoder '{encoder_name}' not explicitly recognized for quality parameter type. Using default quality parameter range {QUALITY_PARAM_SEARCH_RANGE_MIN}-{QUALITY_PARAM_SEARCH_RANGE_MAX}.")
        # Fallback to general QP/CRF range if not recognized.
    return info

def check_dependencies(encoder_to_check):
    """Checks if required command-line tools (ffmpeg, ffprobe) and the specified encoder are available."""
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
                
                # Check for the specified encoder
                result = subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True, text=True, check=True)
                if encoder_to_check not in result.stdout:
                    print(f"Error: ffmpeg found, but it does not seem to have '{encoder_to_check}' encoder enabled.")
                    print(f"Please ensure your ffmpeg build includes necessary flags for '{encoder_to_check}' (e.g., --enable-cuda-sdk --enable-nonfree for NVENC, --enable-libx264 for x264).")
                    sys.exit(1)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print(f"Error: Required dependency '{dep}' not found in your system's PATH.")
            print("Please install it and ensure it's accessible.")
            sys.exit(1)
    print(f"All necessary dependencies (ffmpeg, ffprobe, libvmaf_cuda, and {encoder_to_check} support) are found.")

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
                'ffprobe', '-v', 'info', '-show_entries', 'format=duration', '-of', 'json', input_file
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

def encode_distorted_sample(reference_mp4, quality_value, output_path, encoder, preset, quality_flag):
    """
    Encodes a distorted version of the reference sample using the given encoder,
    quality value, and preset, and returns the average bitrate.
    """
    print(f"🛠️  Encoding distorted sample with {quality_flag} {quality_value} using {encoder} and preset '{preset}'...")

    command = [
        'ffmpeg',
        '-v', 'error', # Using 'error' here for encoding itself
        '-i', reference_mp4,
        '-c:v', encoder,
        quality_flag, str(int(quality_value)), # Use the determined flag (-qp or -crf)
        '-preset', preset,
        '-y',
        output_path
    ]
    try:
        subprocess.run(command, check=True)
        print(f"✅ Distorted sample created: {output_path}")

        # --- Get Bitrate of the encoded file ---
        bitrate_command = [
            'ffprobe',
            '-v', 'error',
            '-select_streams', 'v:0', # Select video stream only
            '-show_entries', 'format=bit_rate', # Get overall format bitrate
            '-of', 'default=noprint_wrappers=1:nokey=1', # Plain output
            output_path
        ]
        bitrate_result = subprocess.run(bitrate_command, capture_output=True, text=True, check=True)
        bitrate_bps = float(bitrate_result.stdout.strip())
        bitrate_mbps = bitrate_bps / 1_000_000 # Convert to Mbps
        return bitrate_mbps

    except subprocess.CalledProcessError as e:
        print(f"Error creating distorted sample with {quality_flag} {quality_value}: {e}")
        sys.exit(1)
    except ValueError:
        print(f"Warning: Could not parse bitrate from {output_path}.")
        return None # Return None if bitrate parsing fails

def run_vmaf(reference_path, distorted_path):
    """Runs VMAF comparison using ffmpeg with libvmaf_cuda filter and returns the aggregate VMAF score."""
    print(f"📊 Running VMAF comparison using libvmaf_cuda...")

    filter_complex = (
        f"[0:v]scale_cuda=w=-2:h=-2:format=yuv420p:interp_algo=lanczos[dist];" # dist input (first input)
        f"[1:v]scale_cuda=w=-2:h=-2:format=yuv420p:interp_algo=lanczos[ref];" # ref input (second input)
        f"[dist][ref]libvmaf_cuda=shortest=true:ts_sync_mode=nearest:model={VMAF_MODEL}"
    )

    with tempfile.NamedTemporaryFile(mode='w+', delete=False, suffix=".log") as log_file:
        log_path = log_file.name

    command = [
        'ffmpeg',
        '-v', 'info', # Keep 'info' as per your observation for VMAF score visibility
        # Input 0 (distorted) - MUST HAVE -hwaccel BEFORE -i
        '-hwaccel', 'cuda',
        '-hwaccel_output_format', 'cuda',
        '-i', distorted_path,
        # Input 1 (reference) - MUST HAVE -hwaccel BEFORE -i
        '-hwaccel', 'cuda',
        '-hwaccel_output_format', 'cuda',
        '-i', reference_path,
        '-filter_complex', filter_complex,
        '-f', 'null',
        '-y',  # Overwrite if needed
        'NUL' if os.name == 'nt' else '/dev/null' # Direct output to null
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
            # Print the full stderr for debugging
            print("FFmpeg stderr dump:\n", result.stderr)
            return None

    except subprocess.CalledProcessError as e:
        print(f"Error running ffmpeg with libvmaf_cuda: {e}")
        print("FFmpeg stdout:\n", e.stdout)
        print("FFmpeg stderr:\n", e.stderr)
        return None
    finally:
        if os.path.exists(log_path):
            os.remove(log_path)

def find_optimal_quality_param(input_file, target_vmaf, encoder, preset,
                               original_file_size_mb,
                               min_quality_param, max_quality_param,
                               search_precision, max_iterations, sample_duration_seconds,
                               save_frames_to): # Added save_frames_to
    """Performs a binary search to find the quality parameter (QP/CRF) that achieves the target VMAF score."""
    props = get_video_properties(input_file)
    # Create samples from the middle of the video for a representative test
    sample_start_time = max(0, (props['duration'] / 2) - (sample_duration_seconds / 2))

    encoder_qp_info = get_encoder_quality_param_info(encoder)
    quality_flag = encoder_qp_info['flag']

    # Use command-line provided min/max, otherwise fall back to encoder-specific or global defaults
    low_param = min_quality_param if min_quality_param is not None else encoder_qp_info['min']
    high_param = max_quality_param if max_quality_param is not None else encoder_qp_info['max']
    
    best_param = high_param # Initialize with the lowest quality setting (highest QP/CRF)

    with tempfile.TemporaryDirectory() as temp_dir:
        ref_path = os.path.join(temp_dir, "reference_sample.mp4")
        dist_path = os.path.join(temp_dir, "distorted_sample.mp4")
        create_video_sample(input_file, sample_start_time, sample_duration_seconds, ref_path)

        print("\n--- Starting Quality Parameter Search ---")
        for i in range(max_iterations): # Use max_iterations from argument
            current_param = (low_param + high_param) // 2
            if low_param == high_param:
                current_param = low_param
            elif low_param + 1 == high_param:
                current_param = low_param # Try the lower (higher quality) of the two remaining

            print(f"\nIteration {i+1}/{max_iterations}: Testing {quality_flag} {current_param} (Range: [{low_param}-{high_param}])")
            if os.path.exists(dist_path):
                os.remove(dist_path)

            # Capture the bitrate from the encoding step
            bitrate_mbps = encode_distorted_sample(ref_path, current_param, dist_path, encoder, preset, quality_flag)
            
            vmaf_score = run_vmaf(ref_path, dist_path)

            # --- Print bitrate and estimated file size/percentage ---
            estimated_full_video_size_mb = None
            percentage_of_original = None

            if bitrate_mbps is not None:
                print(f"📦 Average Bitrate: {bitrate_mbps:.2f} Mbps")
                
                # Calculate estimated file size for the full video based on sample's bitrate
                estimated_full_video_size_mb = (bitrate_mbps * props['duration']) / 8 # Mbps * seconds / 8 bits/byte = MB

                if original_file_size_mb > 0:
                    percentage_of_original = (estimated_full_video_size_mb / original_file_size_mb) * 100
                    print(f"📏 Estimated Full Video Size: {estimated_full_video_size_mb:.2f} MB ({percentage_of_original:.2f}% of original)")
                else:
                    print(f"📏 Estimated Full Video Size: {estimated_full_video_size_mb:.2f} MB (Original size unknown or zero)")

            # --- Optional: Save first frame ---
            if save_frames_to:
                # Ensure the output directory exists
                if not os.path.exists(save_frames_to):
                    try:
                        os.makedirs(save_frames_to)
                        print(f"Created output directory for frames: {save_frames_to}")
                    except OSError as e:
                        print(f"Error creating directory '{save_frames_to}': {e}. Skipping frame save for this run.")
                        save_frames_to = None # Disable further saving if creation fails

                if save_frames_to and vmaf_score is not None and bitrate_mbps is not None and estimated_full_video_size_mb is not None:
                    # Format filename: "VMAF_score_Bitrate_X.XXMbps_Size_Y.YYMB_Z.ZZPercent.png"
                    filename_vmaf = f"VMAF{vmaf_score:.2f}".replace('.', '_')
                    filename_bitrate = f"Bitrate{bitrate_mbps:.2f}Mbps".replace('.', '_')
                    
                    if percentage_of_original is not None:
                        filename_size_info = f"Size{estimated_full_video_size_mb:.2f}MB_{percentage_of_original:.2f}Percent".replace('.', '_')
                    else:
                        filename_size_info = f"Size{estimated_full_video_size_mb:.2f}MB".replace('.', '_')

                    frame_filename = f"{filename_vmaf}_{filename_bitrate}_{filename_size_info}.png"
                    frame_path = os.path.join(save_frames_to, frame_filename)

                    print(f"🖼️  Saving first frame to: {frame_path}")
                    frame_extract_command = [
                        'ffmpeg',
                        '-v', 'error', # Suppress ffmpeg's own output during frame extraction
                        '-i', dist_path,
                        '-vframes', '1',
                        '-y', # Overwrite if exists
                        frame_path
                    ]
                    try:
                        subprocess.run(frame_extract_command, check=True, capture_output=True)
                        print("✅ Frame saved successfully.")
                    except subprocess.CalledProcessError as e:
                        print(f"Error saving frame: {e}")
                        print("FFmpeg stdout:\n", e.stdout.decode() if e.stdout else "")
                        print("FFmpeg stderr:\n", e.stderr.decode() if e.stderr else "")
                    except FileNotFoundError:
                        print("Error: ffmpeg command not found for frame extraction. Please ensure ffmpeg is in your PATH.")


            if vmaf_score is None:
                print("VMAF calculation failed. Aborting search for this branch.")
                low_param = current_param + 1
                if low_param > high_param:
                    print("Quality parameter search range exhausted due to VMAF calculation failures.")
                    break
                continue

            if vmaf_score >= target_vmaf:
                if current_param < best_param or best_param == high_param: # Use high_param here (initial value of best_param)
                     best_param = current_param # Update if a higher quality (lower param) setting meets the target
                print(f"Score {vmaf_score:.2f} >= {target_vmaf}. Trying higher {quality_flag} to reduce bitrate.")
                low_param = current_param + 1 # Try higher param (lower quality)
            else: # vmaf_score < target_vmaf
                print(f"Score {vmaf_score:.2f} < {target_vmaf}. Need lower {quality_flag} for better quality.")
                high_param = current_param - 1 # Try lower param (higher quality)

            if low_param > high_param:
                print("\nSearch range collapsed. Concluding search.")
                break

        print("\n--- Search Complete ---")
        return best_param, quality_flag # Return both the optimal param and its flag

def main():
    """Main function to parse arguments and run the optimizer."""
    parser = argparse.ArgumentParser(
        description="Find the optimal quality parameter (QP/CRF) for a target VMAF score using ffmpeg's GPU encoders and libvmaf_cuda.",
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
    parser.add_argument(
        '-e', '--encoder',
        type=str,
        default='h264_nvenc',
        help="The FFmpeg video encoder to use (e.g., h264_nvenc, hevc_nvenc, libx264, libx265). Default: h264_nvenc."
    )
    parser.add_argument(
        '-p', '--preset',
        type=str,
        default='p7', # Default for NVENC
        help="The encoding preset for the chosen encoder (e.g., p7 for NVENC, medium for libx264/libx265). Default: p7."
    )
    parser.add_argument(
        '--min-quality-param',
        type=int,
        default=None, # Use None to indicate it's not set from command line
        help=f"Minimum value for the quality parameter search range (e.g., QP or CRF). Overrides encoder-specific min. Default (if not overridden): Encoder-specific (e.g., {QUALITY_PARAM_SEARCH_RANGE_MIN})."
    )
    parser.add_argument(
        '--max-quality-param',
        type=int,
        default=None, # Use None to indicate it's not set from command line
        help=f"Maximum value for the quality parameter search range (e.g., QP or CRF). Overrides encoder-specific max. Default (if not overridden): Encoder-specific (e.g., {QUALITY_PARAM_SEARCH_RANGE_MAX})."
    )
    parser.add_argument(
        '--search-precision',
        type=float,
        default=SEARCH_PRECISION,
        help=f"How close to the target VMAF score is 'good enough'. (Note: Current binary search primarily focuses on finding integer parameter, not VMAF delta for termination). Default: {SEARCH_PRECISION}."
    )
    parser.add_argument(
        '--max-iterations',
        type=int,
        default=MAX_ITERATIONS,
        help=f"Maximum number of iterations for the binary search. Failsafe to prevent infinite loops. Default: {MAX_ITERATIONS}."
    )
    parser.add_argument(
        '--sample-duration',
        type=float,
        default=SAMPLE_DURATION_SECONDS,
        help=f"Duration in seconds of the video sample to test in each iteration. Default: {SAMPLE_DURATION_SECONDS}."
    )
    parser.add_argument(
        '--save-frames-to',
        type=str,
        default=None,
        help='Optional: Directory to save the first frame of each distorted sample. Filenames will include VMAF, bitrate, and size info.'
    )
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"Error: Input file not found at '{args.input}'")
        sys.exit(1)

    # Get original file size
    original_file_size_bytes = os.path.getsize(args.input)
    original_file_size_mb = original_file_size_bytes / (1024 * 1024)
    print(f"Original file size: {original_file_size_mb:.2f} MB")

    check_dependencies(args.encoder)
    optimal_param, quality_flag_final = find_optimal_quality_param(
        args.input, args.target_vmaf, args.encoder, args.preset,
        original_file_size_mb,
        args.min_quality_param, args.max_quality_param,
        args.search_precision, args.max_iterations, args.sample_duration,
        args.save_frames_to # Pass the new argument
    )

    print(f"\n🎉 Optimal {quality_flag_final.strip('-').upper()} found: {optimal_param}")
    print(f"This value is the best estimate to achieve a VMAF score of ~{args.target_vmaf}.")
    print("\nExample FFmpeg command for full video encode:")
    print(f"ffmpeg -i \"{args.input}\" -c:v {args.encoder} {quality_flag_final} {optimal_param} -preset {args.preset} -c:a copy output.mkv")

if __name__ == '__main__':
    main()
