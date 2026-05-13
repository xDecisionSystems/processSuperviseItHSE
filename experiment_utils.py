from __future__ import annotations

import argparse
import shutil
from pathlib import Path
from typing import Iterable


class ProgressBar:
    def __init__(self, total: int, width: int = 30) -> None:
        self.total = max(total, 1)
        self.width = width
        self.current = 0

    def update(self, label: str | None = None) -> None:
        self.current += 1
        filled = int(self.width * self.current / self.total)
        bar = "#" * filled + "-" * (self.width - filled)
        suffix = f"{self.current}/{self.total}"
        if label:
            suffix += f" ({label})"
        print(f"\r[{bar}] {suffix}", end="", flush=True)

    def finish(self) -> None:
        print()

FILE_RULES = {
    ".csv": {"subfolder": "csv", "action": "copy", "phase": "standard"},
    ".png": {"subfolder": "png", "action": "copy", "phase": "standard"},
    ".bag": {"subfolder": "bag", "action": "link", "phase": "bag"},
}


def parse_env_file(path: Path) -> dict[str, str]:
    env_data: dict[str, str] = {}
    if not path.exists():
        raise FileNotFoundError(f"Missing env file: {path}")

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"')
        env_data[key] = value
    return env_data


def load_env_paths(exp_name: str) -> tuple[str, str]:
    env_path = Path("env") / f"{exp_name}.env"
    env_data = parse_env_file(env_path)

    try:
        raw_folder = env_data["DATA_FOLDER_RAW"]
        processed_folder = env_data["DATA_FOLDER_PROCESSED"]
    except KeyError as exc:
        raise KeyError(
            f"Required variable {exc.args[0]} missing in {env_path}"
        ) from exc

    return raw_folder, processed_folder


def load_participant_ids(exp_name: str) -> list[str]:
    participants_path = Path("participants") / f"{exp_name}.csv"
    if not participants_path.exists():
        raise FileNotFoundError(f"Missing participants file: {participants_path}")

    participant_ids: list[str] = []
    for line in participants_path.read_text().splitlines():
        participant_id = line.strip()
        if participant_id:
            participant_ids.append(participant_id)
    return participant_ids


def parse_args(default_exp_name: str) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Organize participant data files."
    )
    parser.add_argument(
        "-e",
        "--exp-name",
        default=default_exp_name,
        help="Experiment name for locating .env and participant files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned operations without copying/linking files.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace existing files in processed folders (default: skip existing).",
    )
    return parser.parse_args()


def ensure_processed_structure(
    processed_root: Path | str, *, dry_run: bool = False
) -> dict[str, Path]:
    processed_path = Path(processed_root)
    if not dry_run:
        processed_path.mkdir(parents=True, exist_ok=True)

    destination_dirs: dict[str, Path] = {}
    subfolders = {rule["subfolder"] for rule in FILE_RULES.values()}
    for subfolder in subfolders:
        folder = processed_path / subfolder
        if not dry_run:
            folder.mkdir(parents=True, exist_ok=True)
        destination_dirs[subfolder] = folder
    return destination_dirs


def _copy_file(source_path: Path, destination_path: Path) -> None:
    shutil.copy2(source_path, destination_path)


def _link_file(source_path: Path, destination_path: Path) -> None:
    destination_path.symlink_to(source_path.resolve())


def copy_participant_files(
    participant_id: str,
    raw_root: Path,
    destination_dirs: dict[str, Path],
    *,
    dry_run: bool = False,
    phase: str = "standard",
    bag_action_override: str | None = None,
    overwrite: bool = False,
) -> int:
    participant_folder = raw_root / participant_id
    if not participant_folder.is_dir():
        raise FileNotFoundError(f"Participant folder not found: {participant_folder}")

    copies_made = 0
    for source_path in participant_folder.iterdir():
        if not source_path.is_file():
            continue
        extension = source_path.suffix.lower()
        rule = FILE_RULES.get(extension)
        if rule is None:
            continue

        if rule.get("phase", "standard") != phase:
            continue

        destination_dir = destination_dirs[rule["subfolder"]]
        destination_filename = source_path.name
        destination_path = destination_dir / destination_filename

        action = rule["action"]
        if rule["subfolder"] == "bag" and bag_action_override is not None:
            action = bag_action_override
        exists = destination_path.exists() or destination_path.is_symlink()

        if dry_run:
            print(
                f"[DRY RUN] {action.upper()} {source_path} -> {destination_path}"
            )
        else:
            if exists and not overwrite:
                continue

            if exists:
                destination_path.unlink()

            if action == "copy":
                _copy_file(source_path, destination_path)
            elif action == "link":
                _link_file(source_path, destination_path)
            else:
                raise ValueError(
                    f"Unknown action '{action}' for extension {extension}"
                )
        copies_made += 1
    return copies_made


def copy_all_participant_files(
    participant_ids: Iterable[str],
    raw_root: Path | str,
    processed_root: Path | str,
    exp_name: str,
    *,
    dry_run: bool = False,
    bag_behavior: str = "link",
    overwrite: bool = False,
) -> dict[str, int]:
    raw_base = Path(raw_root)
    processed_base = Path(processed_root)

    raw_path = raw_base / exp_name
    if not raw_path.is_dir():
        raise FileNotFoundError(
            f"Raw experiment folder not found: {raw_path}"
        )

    processed_path = processed_base / exp_name
    destination_dirs = ensure_processed_structure(processed_path, dry_run=dry_run)

    def run_phase(phase_label: str) -> dict[str, int]:
        progress = None
        if not dry_run:
            progress = ProgressBar(len(participant_ids))

        counts: dict[str, int] = {}
        for participant_id in participant_ids:
            participant_folder = raw_path / participant_id
            if not participant_folder.is_dir():
                print(f"[WARN] Missing folder for participant {participant_id}")
                counts[participant_id] = 0
            else:
                counts[participant_id] = copy_participant_files(
                    participant_id,
                    raw_path,
                    destination_dirs,
                    dry_run=dry_run,
                    phase=phase_label,
                    bag_action_override=(
                        bag_behavior if phase_label == "bag" else None
                    ),
                    overwrite=overwrite,
                )

            if progress is not None:
                progress.update(f"{participant_id} ({phase_label})")

        if progress is not None:
            progress.finish()
        return counts

    standard_counts = run_phase("standard")
    bag_counts = run_phase("bag")

    combined_counts: dict[str, int] = {}
    for participant_id in participant_ids:
        combined_counts[participant_id] = (
            standard_counts.get(participant_id, 0)
            + bag_counts.get(participant_id, 0)
        )

    return combined_counts
