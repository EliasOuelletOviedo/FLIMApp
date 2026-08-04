"""
cellpose_segment.py

Run Cellpose segmentation on a single grayscale image and write back a
per-pixel integer label mask (0 = background, 1..N = one region each).

Invoked as a subprocess by FLIMApp's Julia side (run_cellpose_segmentation!,
src/roi_popup.jl) -- not meant to be imported or run interactively. Talking
over two small binary files (not PNG/TIFF/npy) means neither language needs
an image-format library: a (n_cols, n_rows) int64 header followed by the
pixel data in Julia's native column-major ("Fortran") order, so both sides
read/write the array with no reshaping logic beyond the single transpose
needed for Cellpose's own (row, col) convention.

Usage:
    python cellpose_segment.py <input.bin> <output.bin> <pretrained_model> <diameter>

<diameter> of 0 lets Cellpose auto-estimate the typical object size from the
image itself.

Written against Cellpose 4.x's CellposeModel(pretrained_model=...).eval(img,
diameter=...) API (confirmed via CellposeModel.__init__/.eval signatures on
a real 4.2.1.1 install: MODEL_NAMES = ['cpsam_v2', 'cpdino', 'cpdino-vitb',
'cpsam'), *not* the older 2.x/3.x `model_type="cyto3"`/`channels=[0, 0]`
convention -- that model family (cyto/cyto2/cyto3/nuclei) no longer exists
in 4.x's MODEL_NAMES. If you're on an older Cellpose install, `channels`
and `model_type` (not `pretrained_model`) are the ones you'll need instead;
the error below will show the exact exception from `model.eval(...)`.
"""
import sys
import traceback

import numpy as np


def read_image(path):
    """Read (n_cols, n_rows) float64 header+data, Fortran order (see module docstring)."""
    with open(path, "rb") as f:
        n_cols, n_rows = np.fromfile(f, dtype=np.int64, count=2)
        data = np.fromfile(f, dtype=np.float64, count=int(n_cols) * int(n_rows))
    return data.reshape((int(n_cols), int(n_rows)), order="F")


def write_masks(path, masks_xy):
    """Write (n_cols, n_rows) int32 header+data, Fortran order (see module docstring)."""
    n_cols, n_rows = masks_xy.shape
    with open(path, "wb") as f:
        np.array([n_cols, n_rows], dtype=np.int64).tofile(f)
        np.asfortranarray(masks_xy.astype(np.int32)).tofile(f)


def main():
    if len(sys.argv) != 5:
        print(
            "usage: cellpose_segment.py <input.bin> <output.bin> <model_type> <diameter>",
            file=sys.stderr,
        )
        return 2

    input_path, output_path, pretrained_model, diameter_str = sys.argv[1:]
    diameter = float(diameter_str)
    diameter = None if diameter <= 0 else diameter

    try:
        from cellpose import models
    except ImportError as e:
        print(f"Cellpose is not installed in this Python environment: {e}", file=sys.stderr)
        return 3

    image_xy = read_image(input_path)   # (n_cols, n_rows) -- FLIMApp's own (x, y) convention
    image_hw = image_xy.T               # Cellpose expects (height, width)

    try:
        model = models.CellposeModel(pretrained_model=pretrained_model)
        # No `channels=` here: 4.x's SAM-based models auto-detect/don't use
        # the older per-channel cyto convention (channels still exists as a
        # kwarg but defaults to None -- forcing the old [0, 0] risks a
        # value it no longer expects rather than a missing one).
        result = model.eval(image_hw, diameter=diameter)
        masks_hw = result[0]
    except Exception:
        print("Cellpose segmentation failed:", file=sys.stderr)
        traceback.print_exc()
        return 4

    write_masks(output_path, masks_hw.T)   # back to (n_cols, n_rows) for Julia
    n_objects = int(masks_hw.max())
    print(f"Cellpose found {n_objects} object(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
