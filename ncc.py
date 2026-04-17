#!/usr/bin/env python3
"""Compute voxel-wise Pearson NCC between two NIfTI volumes.

Handles grid mismatch by nearest-neighbor resampling of the second image
(the 'base') onto the first image's grid via affine math. Prints a single
float to stdout.

Usage: ncc.py <resliced.nii.gz> <base.nii.gz>
"""
import sys
import numpy as np
import nibabel as nib
from nibabel.processing import resample_from_to


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: ncc.py moving_resliced.nii.gz base.nii.gz\n")
        sys.exit(2)
    mv = nib.load(sys.argv[1])
    bs = nib.load(sys.argv[2])
    mv_data = np.asanyarray(mv.dataobj).astype(np.float64)
    if mv.shape != bs.shape or not np.allclose(mv.affine, bs.affine, atol=1e-3):
        bs_r = resample_from_to(bs, mv, order=1, cval=0.0)
        bs_data = np.asanyarray(bs_r.dataobj).astype(np.float64)
    else:
        bs_data = np.asanyarray(bs.dataobj).astype(np.float64)
    if mv_data.ndim > 3:
        mv_data = mv_data[..., 0]
    if bs_data.ndim > 3:
        bs_data = bs_data[..., 0]
    mask = (mv_data != 0) & (bs_data != 0)
    a = mv_data[mask]; b = bs_data[mask]
    if a.size < 100:
        print("NaN"); return
    a = a - a.mean(); b = b - b.mean()
    denom = np.sqrt((a * a).sum() * (b * b).sum())
    if denom <= 0:
        print("NaN"); return
    print(f"{float((a * b).sum() / denom):.4f}")


if __name__ == "__main__":
    main()
