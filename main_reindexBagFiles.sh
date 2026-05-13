#!/usr/bin/env bash

set -euo pipefail

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

if ! command -v rosbag &>/dev/null; then
    echo "rosbag is required but not found in PATH."
    exit 1
fi

exp_processed_dir="${DATA_FOLDER_PROCESSED}/${exp_name}"
bag_dir="${exp_processed_dir}/bag"

if [[ ! -d "$exp_processed_dir" ]]; then
    echo "Experiment directory '$exp_processed_dir' not found."
    exit 1
fi

if [[ ! -d "$bag_dir" ]]; then
    echo "Bag directory '$bag_dir' not found."
    exit 1
fi

MAX_REINDEX_JOBS=${MAX_REINDEX_JOBS:-4}
if ! [[ "$MAX_REINDEX_JOBS" =~ ^[0-9]+$ ]] || (( MAX_REINDEX_JOBS < 1 )); then
    echo "MAX_REINDEX_JOBS must be a positive integer."
    exit 1
fi

shopt -s nullglob
bag_files=("$bag_dir"/*.bag)
shopt -u nullglob

if (( ${#bag_files[@]} == 0 )); then
    echo "No .bag files found in $bag_dir."
    exit 0
fi

ensure_writable_bag() {
    local bagfile=$1
    if [[ -L "$bagfile" ]]; then
        local target
        target=$(readlink -f "$bagfile")
        if [[ -z "$target" ]]; then
            echo "Unable to resolve target for symlink $bagfile"
            return 1
        fi
        echo "Bag $bagfile is a symlink. Replacing link with actual file before reindexing."
        rm -f "$bagfile"
        cp -p "$target" "$bagfile"
    fi
}

is_bag_indexed() {
    local bagfile=$1
    local info
    if info=$(rosbag info --yaml "$bagfile" 2>/dev/null); then
        if grep -qi '^indexed:[[:space:]]*true' <<<"$info"; then
            return 0
        fi
    fi
    return 1
}

reindex_single_bag() {
    local bagfile=$1
    ensure_writable_bag "$bagfile"
    echo "Reindexing $bagfile"
    if rosbag reindex "$bagfile"; then
        local orig_candidate="${bagfile%.bag}.orig.bag"
        if [[ -f "$orig_candidate" ]]; then
            echo "Removing temporary backup $orig_candidate to save space."
            rm -f "$orig_candidate"
        fi
    else
        echo "[ERROR] rosbag reindex failed for $bagfile" >&2
        return 1
    fi
}

run_reindex_jobs() {
    local bagfile
    local active_jobs=0
    local queued=0
    local skipped=0

    echo "Starting reindex for ${#bag_files[@]} bag file(s) with up to $MAX_REINDEX_JOBS concurrent job(s)."

    for bagfile in "${bag_files[@]}"; do
        if is_bag_indexed "$bagfile"; then
            echo "Skipping $bagfile: already indexed."
            skipped=$((skipped + 1))
            continue
        fi

        (
            set -euo pipefail
            reindex_single_bag "$bagfile"
        ) &
        active_jobs=$((active_jobs + 1))
        queued=$((queued + 1))

        while (( active_jobs >= MAX_REINDEX_JOBS )); do
            if ! wait -n; then
                echo "[ERROR] A reindex job failed. Aborting." >&2
                exit 1
            fi
            active_jobs=$((active_jobs - 1))
        done
    done

    while (( active_jobs > 0 )); do
        if ! wait -n; then
            echo "[ERROR] A reindex job failed. Aborting." >&2
            exit 1
        fi
        active_jobs=$((active_jobs - 1))
    done

    echo "Reindex complete: $queued reindexed, $skipped skipped."
}

run_reindex_jobs
