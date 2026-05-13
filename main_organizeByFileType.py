from __future__ import annotations

from experiment_utils import (
    copy_all_participant_files,
    load_env_paths,
    load_participant_ids,
    parse_args,
)

DEFAULT_EXP_NAME = "SortAndPlaceNormal_SPNwithBT"
OVERWRITE_EXISTING = False


def main() -> None:
    args = parse_args(DEFAULT_EXP_NAME)
    exp_name = args.exp_name

    raw_data_folder, processed_data_folder = load_env_paths(exp_name)
    participant_ids = load_participant_ids(exp_name)

    print(f"Raw data folder: {raw_data_folder}")
    print(f"Processed data folder: {processed_data_folder}")
    print(f"Loaded {len(participant_ids)} participant IDs for {exp_name}")

    overwrite = OVERWRITE_EXISTING
    if args.overwrite:
        overwrite = True

    copy_counts = copy_all_participant_files(
        participant_ids,
        raw_data_folder,
        processed_data_folder,
        exp_name,
        dry_run=args.dry_run,
        bag_behavior="copy",
        overwrite=overwrite,
    )

    total_files = sum(copy_counts.values())
    summary = (
        f"[DRY RUN] Planned {total_files} operations"
        if args.dry_run
        else f"Copied {total_files} files"
    )
    print(f"{summary} across {len(participant_ids)} participants")


if __name__ == "__main__":
    main()
