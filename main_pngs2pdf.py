#!/usr/bin/env python3

"""Generate a PDF with one PNG per page and captioned filenames."""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas
from openpyxl import Workbook

from experiment_utils import load_env_paths
from PIL import Image


DEFAULT_EXP_NAME = "SortAndPlaceNormal_SPNwithBT"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a PDF with each PNG on its own page and filename caption."
    )
    parser.add_argument(
        "-e",
        "--exp-name",
        default=DEFAULT_EXP_NAME,
        help="Experiment name used to locate env and processed folders.",
    )
    parser.add_argument(
        "--png-folder",
        type=Path,
        help=(
            "Optional override for the PNG folder. "
            "Defaults to DATA_FOLDER_PROCESSED/<exp_name>/png."
        ),
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        help="Destination PDF path. Defaults to processed/<exp>/finalpuzzle.pdf",
    )
    parser.add_argument(
        "--num-parts",
        type=int,
        default=4,
        help="Number of PDF/Excel splits to create (default: 5).",
    )
    return parser.parse_args()


def load_pngs(folder: Path) -> list[Path]:
    if not folder.is_dir():
        raise FileNotFoundError(f"PNG folder not found: {folder}")
    pngs = sorted(p for p in folder.glob("*.png") if "_0.png" not in p.name)
    if not pngs:
        raise FileNotFoundError(f"No PNG files found in {folder} (after filtering)")
    return pngs


def crop_image(image_path: Path) -> Image.Image:
    with Image.open(image_path) as img:
        return img.crop((340, 130, 560, 290)).copy()


def prepare_image(image_path: Path) -> Image.Image:
    return crop_image(image_path).rotate(180, expand=True)


def add_image_page(c: canvas.Canvas, image_path: Path, page_width: float, page_height: float) -> None:
    margin = 0.5 * inch
    caption_height = 0.4 * inch
    available_width = page_width - 2 * margin
    available_height = page_height - 2 * margin - caption_height

    processed = prepare_image(image_path)
    tmp_path = image_path.with_suffix(".cropped.png")
    processed.save(tmp_path)
    try:
        img_width, img_height = processed.size
        scale = min(available_width / img_width, available_height / img_height)
        draw_width = img_width * scale
        draw_height = img_height * scale
        x_pos = margin + (available_width - draw_width) / 2
        y_pos = margin + caption_height + (available_height - draw_height) / 2
        c.drawImage(
            str(tmp_path),
            x_pos,
            y_pos,
            width=draw_width,
            height=draw_height,
            preserveAspectRatio=False,
        )
    finally:
        tmp_path.unlink(missing_ok=True)

    caption_text = image_path.name
    caption_offset = 10  # points ~10px
    caption_y = y_pos + draw_height + caption_offset
    c.setFont("Helvetica", 36)
    c.drawCentredString(page_width / 2, caption_y, caption_text)
    c.showPage()


def resolve_paths(
    exp_name: str,
    png_folder_override: Path | None,
    output_override: Path | None,
) -> tuple[Path, Path, Path]:
    _, processed_folder = load_env_paths(exp_name)
    processed_path = Path(processed_folder)
    default_png_folder = processed_path / exp_name / "png"
    pdf_dir = processed_path / exp_name / "pdf"
    default_output = pdf_dir / "finalpuzzle.pdf"
    default_excel = pdf_dir / "finalpuzzle.xlsx"

    png_folder = png_folder_override or default_png_folder
    output_path = output_override or default_output
    excel_path = default_excel
    return png_folder, output_path, excel_path


def write_excel(excel_path: Path, png_paths: list[Path]) -> None:
    wb = Workbook()
    ws = wb.active
    ws.title = "Images"
    ws.append(["filename", "rotated", "wrong location", "missing"])
    for path in png_paths:
        ws.append([path.name, "", "", ""])
    wb.save(excel_path)


def chunk_paths(png_paths: list[Path], num_parts: int) -> list[list[Path]]:
    num_parts = max(1, num_parts)
    chunk_size = math.ceil(len(png_paths) / num_parts)
    return [png_paths[i:i + chunk_size] for i in range(0, len(png_paths), chunk_size)]


def part_suffix(index: int, total_parts: int) -> str:
    return f"_{index + 1:02d}of{total_parts:02d}" if total_parts > 1 else ""


def main() -> None:
    args = parse_args()
    png_folder, output_pdf, excel_path = resolve_paths(args.exp_name, args.png_folder, args.output)
    output_pdf.parent.mkdir(parents=True, exist_ok=True)
    png_paths = load_pngs(png_folder)

    parts = chunk_paths(png_paths, args.num_parts)
    created = []

    for idx, paths in enumerate(parts):
        if not paths:
            continue
        suffix = part_suffix(idx, len(parts))
        part_pdf = output_pdf.with_name(output_pdf.stem + suffix + output_pdf.suffix)
        part_excel = excel_path.with_name(excel_path.stem + suffix + excel_path.suffix)

        page_width, page_height = letter
        c = canvas.Canvas(str(part_pdf), pagesize=(page_width, page_height))
        for path in paths:
            add_image_page(c, path, page_width, page_height)
        c.save()

        write_excel(part_excel, paths)
        created.append((part_pdf, part_excel, len(paths)))

    for pdf_path, xlsx_path, count in created:
        print(f"Wrote {count} pages to {pdf_path} and spreadsheet to {xlsx_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # pylint: disable=broad-except
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
