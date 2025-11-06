import os
import sys
import json
from ffmpeg_quality_metrics import FfmpegQualityMetrics

# --- Configuration ---
# Use os.path.expandvars() to replace '$HOME' with the actual home directory path.
reference_video = os.path.expandvars("$HOME/build/data/ref.mp4")
distorted_video = os.path.expandvars("$HOME/build/data/dist-nvenc.mp4")

# This path is for documentation; the library auto-discovers or relies on environment variables.
VMAF_MODEL_PATH_DOCS = "/usr/local/share/model/vmaf_v0.6.1.json"

# --- Path Validation (Crucial for Debugging) ---
print(f"Checking video file paths:")
if not os.path.exists(reference_video):
    print(f"ERROR: Reference video not found at: {reference_video}")
    sys.exit(1)
else:
    print(f"Reference video found: {reference_video}")

if not os.path.exists(distorted_video):
    print(f"ERROR: Distorted video not found at: {distorted_video}")
    sys.exit(1)
else:
    print(f"Distorted video found: {distorted_video}")

print(f"\nVMAF model path assumption (not passed directly to constructor): {VMAF_MODEL_PATH_DOCS}")


print("\n--- Starting VMAF Calculation ---")

try:
    # 1. Initialize: Only use positional arguments, and add verbose=True.
    # CRITICAL FIX: The 'verbose=True' flag ensures FFmpeg output verbosity 
    # is high enough for the library to capture the metric data needed for parsing.
    metrics_calculator = FfmpegQualityMetrics(
        distorted_video,
        reference_video,
        verbose=True # <-- Enables the necessary info/verbose output
    )
    print("FfmpegQualityMetrics object initialized successfully.")
    
    # 2. CRITICAL STEP: Explicitly call calculate() to execute the FFmpeg command.
    print("Executing FFmpeg command to calculate metrics...")
    metrics_calculator.calculate()
    print("Calculation finished.")


    # --- 3. Result Processing (Unified Logic) ---

    vmaf_results = None

    # Try retrieving results from the dedicated attribute first
    if hasattr(metrics_calculator, 'vmaf') and metrics_calculator.vmaf:
        vmaf_results = metrics_calculator.vmaf
        print("SUCCESS: Found VMAF results in the direct 'vmaf' attribute.")
        
    # Fallback retrieval from the generic data dictionary
    elif hasattr(metrics_calculator, 'data') and 'vmaf' in metrics_calculator.data:
        vmaf_results = metrics_calculator.data['vmaf']
        print("SUCCESS: Found VMAF results in the generic 'data' attribute.")
    
    
    # Process the results if they were found in either location
    if isinstance(vmaf_results, list) and vmaf_results:
        # Check if the list contains dictionaries with a 'vmaf' key
        if all(isinstance(item, dict) and 'vmaf' in item for item in vmaf_results):
            # Calculate average VMAF from list of per-frame dictionaries
            average_vmaf = sum(item.get('vmaf', 0) for item in vmaf_results) / len(vmaf_results)
            
            print(f"\n--- VMAF Calculation Results ---")
            print(f"Total Frames Processed: {len(vmaf_results)}")
            print(f"Average VMAF Score: {average_vmaf:.2f}")

            # Optional: Show other calculated metrics (e.g., PSNR)
            if hasattr(metrics_calculator, 'psnr'):
                if metrics_calculator.psnr and all(isinstance(item, dict) and 'psnr_avg' in item for item in metrics_calculator.psnr):
                    avg_psnr = sum(item.get('psnr_avg', 0) for item in metrics_calculator.psnr) / len(metrics_calculator.psnr)
                    print(f"Average PSNR Score: {avg_psnr:.2f}")

        else:
             print("\nWARNING: VMAF data structure is unexpected. Cannot calculate average.")
             # Final debugging step: print a sample of the raw data
             print(f"Raw Data Sample (First 5 Items): {vmaf_results[:5] if isinstance(vmaf_results, list) else vmaf_results}")


    elif vmaf_results is None:
        print("\nERROR: VMAF calculation failed or results could not be retrieved from the known attributes.")
        print("Please check the console for any low-level FFmpeg error messages that may have been captured.")

except Exception as e:
    print(f"\nAn unexpected Python error occurred: {e}")
    import traceback
    traceback.print_exc() 
    print("\n--- Troubleshooting Steps ---")
    print("1. **VMAF Executable:** Ensure `ffmpeg` and `libvmaf` are working together. Check with: `ffmpeg -v quiet -filters | grep vmaf`")
    print("2. **Environment Variable:** Set the VMAF model path environment variable manually before running the script (e.g., `export VMAF_MODEL_PATH=/usr/local/share/model/vmaf_v0.6.1.json`)")
    print("3. **Manual Run:** Run your manual command to confirm the underlying FFmpeg logic works.")
