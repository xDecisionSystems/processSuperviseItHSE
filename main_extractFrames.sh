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

if ! command -v rs-convert &>/dev/null; then
    echo "rs-convert is required but not found in PATH."
    exit 1
fi

exp_processed_dir="${DATA_FOLDER_PROCESSED}/${exp_name}"
bag_dir="${exp_processed_dir}/bag"
frames_dir="${exp_processed_dir}/frames"

if [[ ! -d "$exp_processed_dir" ]]; then
    echo "Experiment directory '$exp_processed_dir' not found."
    exit 1
fi

if [[ ! -d "$bag_dir" ]]; then
    echo "Bag directory '$bag_dir' not found."
    exit 1
fi

mkdir -p "$frames_dir"

MAX_EXTRACT_JOBS=${MAX_EXTRACT_JOBS:-8}
if ! [[ "$MAX_EXTRACT_JOBS" =~ ^[0-9]+$ ]] || (( MAX_EXTRACT_JOBS < 1 )); then
    echo "MAX_EXTRACT_JOBS must be a positive integer."
    exit 1
fi

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
    local bar
    printf -v bar '%*s' "$filled" ''
    bar=${bar// /#}
    local pad
    printf -v pad '%*s' "$empty" ''
    pad=${pad// /-}
    bar+=$pad
    printf 'Progress [%s] %d/%d | elapsed %s | ETA %s\n' "$bar" "$done" "$total" "$elapsed_str" "$eta_str"
}

total_files=${#bag_files[@]}
processed_count=0
start_time=$(date +%s)

declare -a running_pids=()
declare -A pid_to_label

wait_for_pid() {
    local pid=$1
    local status label
    if [[ -z "$pid" ]]; then
        return
    fi
    if wait "$pid"; then
        status=0
    else
        status=$?
    fi
    label=${pid_to_label["$pid"]}
    unset pid_to_label["$pid"]
    if (( ${#running_pids[@]} > 0 )); then
        running_pids=("${running_pids[@]:1}")
    else
        running_pids=()
    fi

    if (( status == 0 )); then
        processed_count=$((processed_count + 1))
        print_progress "$processed_count" "$total_files" "$start_time"
    else
        echo "[ERROR] rs-convert failed for ${label}" >&2
    fi
}

wait_for_capacity() {
    while (( ${#running_pids[@]} >= MAX_EXTRACT_JOBS )); do
        wait_for_pid "${running_pids[0]}"
    done
}

for bagfile in "${bag_files[@]}"; do
    base=$(basename "$bagfile")
    stem="${base%.bag}"
    normalized_stem=$(normalize_stem "$stem")
    frame_dir="${frames_dir}/${normalized_stem}"
    complete_marker="${frame_dir}/complete.txt"

    if [[ -f "$complete_marker" ]]; then
        echo "Skipping ${base}: completion marker found in ${frame_dir}."
        processed_count=$((processed_count + 1))
        print_progress "$processed_count" "$total_files" "$start_time"
        continue
    fi

    mkdir -p "$frame_dir"
    rm -f "$complete_marker"
    echo "Extracting frames for ${base} -> ${frame_dir}"

    (
        if rs-convert -c -i "$bagfile" -p "$frame_dir"/ 2>&1; then
            shopt -s nullglob
            new_frames=("$frame_dir"/*.png)
            shopt -u nullglob
            if (( ${#new_frames[@]} == 0 )); then
                echo "[WARN] No PNG frames found in ${frame_dir} after extraction." >&2
                exit 1
            fi
            date -Is > "$complete_marker"
            exit 0
        else
            printf '[ERROR] rs-convert failed for %s\n' "$bagfile" >&2
            exit 1
        fi
    ) &
    pid=$!
    running_pids+=("$pid")
    pid_to_label["$pid"]="$base"
    wait_for_capacity
done

while (( ${#running_pids[@]} > 0 )); do
    wait_for_pid "${running_pids[0]}"
done

echo "Finished extracting frames into ${frames_dir}."
