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

The model: <pretrained_model> if this Cellpose has it, else "cpsam" (4.x),
else "cyto3" (3.x); on the GPU when PyTorch sees one. Exit codes: 2 usage,
3 Cellpose/PyTorch not importable, 4 segmentation error, 5 no model loads
(the first use downloads the weights: internet needed).

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
    """
    Write (n_cols, n_rows) int32 header+data, Fortran order (see module docstring).
    `ravel(order="F")`: `tofile` always writes C order, whatever the array's
    memory layout — `asfortranarray(...).tofile` would scramble the mask.
    """
    n_cols, n_rows = masks_xy.shape
    with open(path, "wb") as f:
        np.array([n_cols, n_rows], dtype=np.int64).tofile(f)
        masks_xy.astype(np.int32).ravel(order="F").tofile(f)


def load_model(models, requested):
    """
    The requested model, else what this Cellpose version has: "cpsam" (4.x),
    then the classic "cyto3" (3.x, model_type=). Returns (model, name, kwargs
    for eval). Raises with every attempt's error if none loads.
    """
    gpu = False
    try:
        from cellpose import core
        gpu = bool(core.use_gpu())
    except Exception:
        pass
    errors = []
    attempts = [(requested, {"pretrained_model": requested}, {}),
                ("cpsam", {"pretrained_model": "cpsam"}, {}),
                ("cyto3", {"model_type": "cyto3"}, {"channels": [0, 0]})]
    seen = set()
    for name, kwargs, eval_kwargs in attempts:
        if name in seen:
            continue
        seen.add(name)
        try:
            return models.CellposeModel(gpu=gpu, **kwargs), name, eval_kwargs, gpu
        except Exception as e:
            errors.append(f"{name}: {type(e).__name__}: {e}")
    raise RuntimeError("no Cellpose model could be loaded -- " + " | ".join(errors))


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
        import cellpose
        from cellpose import models
    except Exception as e:   # ImportError, or a PyTorch DLL that fails to load (OSError on Windows)
        print(f"Cellpose (or PyTorch) cannot be imported by {sys.executable}: {type(e).__name__}: {e}", file=sys.stderr)
        traceback.print_exc()
        return 3
    version = getattr(cellpose, "__version__", None)
    if version is None:
        try:
            from importlib.metadata import version as _v
            version = _v("cellpose")
        except Exception:
            version = "?"

    image_xy = read_image(input_path)   # (n_cols, n_rows) -- FLIMApp's own (x, y) convention
    image_hw = image_xy.T               # Cellpose expects (height, width)

    try:
        model, name, eval_kwargs, gpu = load_model(models, pretrained_model)
    except Exception as e:
        print(f"Cellpose {version}: {e}", file=sys.stderr)
        return 5
    try:
        # No `channels=` for 4.x's SAM-based models (they don't use the old
        # per-channel convention); "cyto3" (3.x) gets the grayscale [0, 0].
        result = model.eval(image_hw, diameter=diameter, **eval_kwargs)
        masks_hw = result[0]
    except Exception:
        print(f"Cellpose {version} segmentation failed (model {name}, GPU {gpu}):", file=sys.stderr)
        traceback.print_exc()
        return 4

    write_masks(output_path, masks_hw.T)   # back to (n_cols, n_rows) for Julia
    n_objects = int(masks_hw.max())
    print(f"Cellpose {version}, model {name}, {'GPU' if gpu else 'CPU'}: found {n_objects} object(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
