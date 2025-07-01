import os
import sys # Import sys for better error handling/exiting
from ffmpeg_quality_metrics import FfmpegQualityMetrics

# --- Configuration ---
reference_video = "/home/john/Downloads/5310965-uhd_3840_2160_25fps.mp4"
distorted_video = "/home/john/Downloads/5310965-uhd_3840_2160_25fps-ab-av1-vmaf_auto.mp4"

# Define the path to the VMAF model file
vmaf_model_path = "/usr/local/share/model/vmaf_v0.6.1.json"

# --- Path Validation (Crucial for Debugging) ---
print(f"Checking video file paths:")
if not os.path.exists(reference_video):
    print(f"ERROR: Reference video not found at: {reference_video}")
    sys.exit(1) # Exit if file doesn't exist
else:
    print(f"Reference video found: {reference_video}")

if not os.path.exists(distorted_video):
    print(f"ERROR: Distorted video not found at: {distorted_video}")
    sys.exit(1) # Exit if file doesn't exist
else:
    print(f"Distorted video found: {distorted_video}")

print(f"\nChecking VMAF model path:")
if not os.path.exists(vmaf_model_path):
    print(f"ERROR: VMAF model file not found at: {vmaf_model_path}")
    print("Please verify the path. Common locations: /usr/share/vmaf/model/vmaf_v0.6.1.json or similar.")
    sys.exit(1) # Exit if file doesn't exist
else:
    print(f"VMAF model found: {vmaf_model_path}")

print("\n--- Starting VMAF Calculation ---")

try:
    # Initialize the quality metrics calculator for version 3.6.0
    # No 'metrics' argument here.
    metrics_calculator = FfmpegQualityMetrics(
        distorted_video,
        reference_video,
        vmaf_options={"model_path": vmaf_model_path}
    )
    print("FfmpegQualityMetrics object initialized successfully.")

    # Check if 'vmaf' attribute exists and has data
    if hasattr(metrics_calculator, 'vmaf'):
        vmaf_results = metrics_calculator.vmaf
        print(f"\nAccessing 'vmaf' attribute. Type: {type(vmaf_results)}")
        print(f"Content of 'vmaf' attribute: {vmaf_results}") # Print raw content

        if isinstance(vmaf_results, list) and all(isinstance(item, dict) for item in vmaf_results):
            if vmaf_results:
                # Calculate average VMAF from list of per-frame dictionaries
                average_vmaf = sum(item.get('vmaf', 0) for item in vmaf_results) / len(vmaf_results)
                print(f"\nAverage VMAF Score (from list of frames): {average_vmaf:.2f}")
            else:
                print("\nVMAF results list is empty. Calculation might have failed silently.")
        elif isinstance(vmaf_results, (int, float)):
            # If it's a single aggregate score
            print(f"\nOverall VMAF Score: {vmaf_results:.2f}")
        else:
            print(f"\nUnexpected format for VMAF results in '.vmaf' attribute. Cannot parse.")

    # Fallback/alternative check: if results are in a 'results' dictionary
    elif hasattr(metrics_calculator, 'results') and isinstance(metrics_calculator.results, dict) and 'vmaf' in metrics_calculator.results:
        all_results = metrics_calculator.results
        vmaf_data = all_results['vmaf']
        print(f"\nAccessing 'results' dictionary. Type of 'vmaf' data: {type(vmaf_data)}")
        print(f"Content of 'vmaf' in 'results': {vmaf_data}") # Print raw content

        if isinstance(vmaf_data, list) and all(isinstance(item, dict) for item in vmaf_data):
            if vmaf_data:
                average_vmaf = sum(item.get('vmaf', 0) for item in vmaf_data) / len(vmaf_data)
                print(f"\nAverage VMAF Score (from 'results' dictionary): {average_vmaf:.2f}")
            else:
                print("\n'vmaf' in 'results' dictionary is an empty list.")
        elif isinstance(vmaf_data, (int, float)):
            print(f"\nOverall VMAF Score (from 'results' dictionary): {vmaf_data:.2f}")
        else:
            print("\nUnexpected format for VMAF results in 'results' dictionary. Cannot parse.")
    else:
        print("\nCould not find 'vmaf' attribute or 'vmaf' data within 'results' dictionary.")
        print("This suggests the VMAF calculation either failed internally or was not performed.")
        print("Raw attributes of metrics_calculator: ", dir(metrics_calculator))
        print("Raw internal data of metrics_calculator: ", metrics_calculator.__dict__)


except Exception as e:
    print(f"\nAn unexpected Python error occurred: {e}")
    import traceback
    traceback.print_exc() # Print full traceback for more details
    print("\n--- Troubleshooting Steps ---")
    print("1. **Check Video & Model Paths:** The script now exits early if files aren't found.")
    print("2. **FFmpeg & VMAF Executables:** Ensure `ffmpeg` and `vmaf` are truly working from your terminal.")
    print("   Try running `ffmpeg -h full` and `vmaf -h` to confirm they execute.")
    print("   The library calls these executables internally. Any issue with them will cause problems.")
    print("3. **Permissions:** Ensure the Python script has read permissions for the video files and the VMAF model.")
    print("4. **Video Compatibility:** Make sure FFmpeg can decode your MP4 files. Sometimes corrupted or unusual encodings can cause issues.")
    print("5. **Manual Run:** Try running the equivalent command manually in your terminal:")
    print(f"   ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i {distorted_video} -hwaccel cuda -hwaccel_output_format cuda -i {reference_video} -lavfi \"[0:v]scale_cuda=-2:-2:format=yuv420p,setpts=PTS-STARTPTS[dist];[1:v]scale_cuda=-2:-2:format=yuv420p,setpts=PTS-STARTPTS[ref];[dist][ref]libvmaf_cuda\" -f null -")
