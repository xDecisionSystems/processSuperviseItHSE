#!/usr/bin/env bash

set -uo pipefail

DEFAULT_EXPERIMENT="SortAndPlaceNormal_SPNwithBT"
exp_name="${1:-$DEFAULT_EXPERIMENT}"
env_file="env/${exp_name}.env"

if [[ ! -f "$env_file" ]]; then
    echo "Environment file '$env_file' not found."
    exit 1
fi

# shellcheck source=/dev/null
source "$env_file"

if [[ -z "${DATA_FOLDER_PROCESSED:-}" ]]; then
    echo "DATA_FOLDER_PROCESSED is not defined in ${env_file}."
    exit 1
fi

for tool in ffmpeg; do
    if ! command -v "$tool" &>/dev/null; then
        echo "${tool} is required but not found in PATH."
        exit 1
    fi
done

exp_processed_dir="${DATA_FOLDER_PROCESSED}/${exp_name}"
bag_dir="${exp_processed_dir}/bag"
frames_dir="${exp_processed_dir}/frames"
mp4_dir="${exp_processed_dir}/mp4"

if [[ ! -d "$exp_processed_dir" ]]; then
    echo "Experiment directory '$exp_processed_dir' not found."
    exit 1
fi

if [[ ! -d "$bag_dir" ]]; then
    echo "Bag directory '$bag_dir' not found."
    exit 1
fi

if [[ ! -d "$frames_dir" ]]; then
    echo "Frames directory '$frames_dir' not found. Run main_extractFrames.sh first."
    exit 1
fi

mkdir -p "$mp4_dir"

NVENC_CODEC=${NVENC_CODEC:-h264_nvenc}
NVENC_PRESET=${NVENC_PRESET:-p4}
NVENC_BITRATE=${NVENC_BITRATE:-12M}
NVENC_PROFILE=${NVENC_PROFILE:-main}
FPS_SAMPLE_LIMIT=${FPS_SAMPLE_LIMIT:-1000}

if command -v nvidia-smi &>/dev/null; then
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    [[ -n "$gpu_name" ]] && echo "Detected GPU: $gpu_name"
else
    echo "Warning: 'nvidia-smi' not found; unable to confirm GPU visibility." >&2
fi

encoder_listing=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)
if [[ -z "$encoder_listing" ]] || ! grep -q "$NVENC_CODEC" <<<"$encoder_listing"; then
    echo "FFmpeg encoder '$NVENC_CODEC' not available. Ensure FFmpeg is built with NVENC support or adjust NVENC_CODEC."
    exit 1
fi

echo "Confirmed FFmpeg NVENC encoder '$NVENC_CODEC' is available."

shopt -s nullglob
bag_files=("$bag_dir"/*.bag)
shopt -u nullglob

if (( ${#bag_files[@]} == 0 )); then
    echo "No .bag files found in $bag_dir."
    exit 0
fi

normalize_stem() {
    local stem=$1
    if [[ $stem =~ ^([A-Za-z0-9]+)_\1$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$stem"
    fi
}

format_duration() {
    local seconds=$1
    (( seconds < 0 )) && seconds=0
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    printf '%02d:%02d:%02d' "$hours" "$minutes" "$secs"
}

print_progress() {
    local done=$1 total=$2 start=$3
    local now elapsed remaining avg eta
    now=$(date +%s)
    elapsed=$((now - start))
    local elapsed_str eta_str
    elapsed_str=$(format_duration "$elapsed")
    if (( done > 0 )); then
        remaining=$((total - done))
        avg=$((elapsed / done))
        eta=$((avg * remaining))
        eta_str=$(format_duration "$eta")
    else
        eta_str="--:--:--"
    fi
    local bar_len=30
    local filled=$(( total > 0 ? done * bar_len / total : 0 ))
    (( filled < 0 )) && filled=0
    (( filled > bar_len )) && filled=bar_len
    local empty=$((bar_len - filled))
    local bar pad
    printf -v bar '%*s' "$filled" ''
    bar=${bar// /#}
    printf -v pad '%*s' "$empty" ''
    pad=${pad// /-}
    bar+=$pad
    printf 'Progress [%s] %d/%d | elapsed %s | ETA %s\n' "$bar" "$done" "$total" "$elapsed_str" "$eta_str"
}

detect_fps() {
    local frame_dir=$1
    local fps=30
    local sample_limit=${FPS_SAMPLE_LIMIT:-1000}

    local meta
    if meta=$(find "$frame_dir" -maxdepth 1 -type f -name '*meta*.json' | head -n1); then
        if command -v jq &>/dev/null; then
            local key val
            for key in fps frame_rate frameRate rate; do
                val=$(jq -r ".${key}?" "$meta" 2>/dev/null)
                if [[ $val =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    if awk -v v="$val" 'BEGIN{exit !(v>0)}'; then
                        if awk -v v="$val" 'BEGIN{exit !(v>=1)}'; then
                            fps=$val
                        else
                            fps=$(awk -v interval="$val" 'BEGIN{printf "%.2f", 1/interval}')
                        fi
                        echo "$fps"
                        return
                    fi
                fi
            done
        fi
    fi

    local -a png_files=()
    shopt -s nullglob
    for file in "$frame_dir"/*.png; do
        png_files+=("$file")
        if (( sample_limit > 0 && ${#png_files[@]} >= sample_limit )); then
            break
        fi
    done
    shopt -u nullglob

    if (( ${#png_files[@]} > 1 )); then
        local -a stamps=()
        local stamp file
        for file in "${png_files[@]}"; do
            stamp=$(basename "$file" | grep -o -E '[0-9]+(\.[0-9]+)?' | tail -n1 || true)
            [[ -n $stamp ]] && stamps+=("$stamp")
        done
        if (( ${#stamps[@]} > 1 )); then
            local -a deltas_ms=()
            local prev=${stamps[0]}
            local ts delta_ms
            for ts in "${stamps[@]:1}"; do
                delta_ms=$(awk -v a="$ts" -v b="$prev" 'BEGIN{print a-b}')
                if awk -v d="$delta_ms" 'BEGIN{exit !(d>0)}'; then
                    deltas_ms+=("$delta_ms")
                fi
                prev=$ts
            done
            if (( ${#deltas_ms[@]} > 0 )); then
                local avg_seconds
                avg_seconds=$(printf '%s\n' "${deltas_ms[@]}" | awk '{sum+=$1} END { if(NR>0) printf "%.6f", (sum/NR)/1000 }')
                if [[ -n "$avg_seconds" ]] && awk -v a="$avg_seconds" 'BEGIN{exit !(a>0)}'; then
                    fps=$(awk -v a="$avg_seconds" 'BEGIN{printf "%.2f", 1/a}')
                fi
            fi
        fi
    fi

    printf '%s' "$fps"
}

processed_count=0
start_time=$(date +%s)
total_files=${#bag_files[@]}

for bagfile in "${bag_files[@]}"; do
    base=$(basename "$bagfile")
    stem="${base%.bag}"
    normalized_stem=$(normalize_stem "$stem")
    frame_dir="${frames_dir}/${normalized_stem}"
    video_path="${mp4_dir}/${normalized_stem}.mp4"
    complete_marker="${frame_dir}/complete.txt"

    if [[ -f "$video_path" ]]; then
        echo "Skipping ${base}: mp4 already exists."
        processed_count=$((processed_count + 1))
        print_progress "$processed_count" "$total_files" "$start_time"
        continue
    fi

    if [[ ! -f "$complete_marker" ]]; then
        echo "[WARN] Frames for ${base} are incomplete (missing complete.txt). Skipping."
        continue
    fi

    if [[ ! -d "$frame_dir" ]]; then
        echo "[WARN] Frame directory ${frame_dir} not found. Run extraction first." >&2
        continue
    fi

    shopt -s nullglob
    frame_candidates=("$frame_dir"/*.png)
    shopt -u nullglob
    if (( ${#frame_candidates[@]} == 0 )); then
        echo "[WARN] No PNG frames found in ${frame_dir}. Skipping ${base}." >&2
        continue
    fi

    echo "Processing ${base} using frames in ${frame_dir}"

    fps_value=$(detect_fps "$frame_dir")
    echo "Using fps=${fps_value} for ${stem}"

    ffmpeg -loglevel error -hwaccel cuda -hwaccel_output_format cuda \
        -framerate "$fps_value" -pattern_type glob -i "${frame_dir}/*.png" \
        -c:v "$NVENC_CODEC" -preset "$NVENC_PRESET" -profile:v "$NVENC_PROFILE" \
        -b:v "$NVENC_BITRATE" "$video_path" || {
            echo "[ERROR] FFmpeg failed for ${base}." >&2
            continue
        }

    processed_count=$((processed_count + 1))
    print_progress "$processed_count" "$total_files" "$start_time"
done

echo "Finished creating mp4 files in ${mp4_dir}."
