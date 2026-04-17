## About

Sample data for the AFNI [3dAllineate](https://afni.nimh.nih.gov/pub/dist/doc/program_help/3dAllineate.html) tool for regression testing and optimization.

```bash
export OMP_NUM_THREADS=10
3dAllineate -base ./MNI152_T1_2mm.nii.gz  -input ./T1_head_2mm.nii.gz -prefix ./afni/wT1ls_2mm.nii.gz  -cost ls
3dAllineate -base ./MNI152_T1_1mm.nii.gz  -input ./T1_head.nii.gz -prefix ./afni/wT1ls.nii.gz  -cost ls
3dAllineate -base ./MNI152_T1_1mm.nii.gz  -input ./T1_head.nii.gz  -prefix ./afni/wT1.nii.gz
3dAllineate -base ./MNI152_T1_1mm.nii.gz  -input ./T1_head.nii.gz  -prefix ./afni/wT1cmas.nii.gz -cmass
3dAllineate -base ./T1_head.nii.gz  -input ./fmri.nii.gz  -prefix ./afni/fmri2t1.nii.gz -cmass  -cost lpc -source_automask
```

## Benchmarks

Run `./bench.sh [binary] [label]` to measure wall time, peak RSS, and voxel-wise NCC (Pearson correlation between the resliced output and the base, over jointly non-zero voxels) for every case above. Results land in `bench_results_<label>.tsv`; a full `/usr/bin/time -l` log in `bench_log_<label>.txt`.

Reproduce the baseline (default binary: `../src/3dAllineate`):

```bash
cd examples
./bench.sh ../src/3dAllineate baseline_O2
```

Compare a modified build:

```bash
./bench.sh ../src/3dAllineate dscoarse   # after building with -DALLIN_DOWNSAMPLE_COARSE
```

### Rationale for the downsampling optimization

The baseline 3dAllineate sparsely samples the full-resolution volume during the coarse registration phase (`stup.npt_match = ntask/15`). An alternative strategy is to create a downsampled volume for the coarse pass only, then hand the coarse transform back to the full-resolution fine pass. The benefits of this approach are:

1. **Blurring cost collapses.** `FIR_blur_volume_3d` at σ=7.77 mm FWHM on a 256³ full-res volume is a separable convolution, ~16M voxels × kernel diameter ~20 voxels × 3 axes. On a 2×-downsampled 128³ with the same world-space σ but a voxel-space σ half as large, it's 2M voxels × ~10-tap kernel × 3 axes → roughly 16× less work. At 4×, ~256× less work. The refinement stages each re-smooth at a new radius, so this saving multiplies.
2. **Cost-evaluation inner loop gets cache-friendly.**
   - Target-side access is the dominant cost. Every evaluation interpolates `ajims` at `npt_match` warped coordinates. A 2× pyramid makes the target volume 8× smaller — a realistic MRI target goes from hundreds of MB down to a size that may live in L2/L3. Each warped-index fetch becomes a cache hit instead of a miss.
   - Base-side access is already sequential-ish because of `qsort_int_mostly`. A smaller base volume just means fewer cache lines total.
   - The `npt_match = ntask/15` heuristic over-samples at full res precisely because the working set is giant. At pyramid level-2 (8× fewer voxels), you could sample 1/3 of voxels and still beat the current coarse pass on speed — with better coverage.
3. **Natural fit for the existing "refinement stages" loop.** The three-stage refinement loop at [3dAllineate.c:5633-5711](../src/3dAllineate.c#L5633-L5711) (`stup.smooth_radius_*= 0.7777`, `stup.npt_match *= 1.5` per stage) is already conceptually a coarse-to-fine scheme — it's just done at constant resolution. A proper pyramid would map stages to resolution levels (e.g., 4× → 2× → 1×), which is both more principled and faster.
4. **Accuracy risk is small and well-understood.** Anti-aliased decimation (Gaussian blur, then stride-2 decimation) is the textbook approach — it's exactly what FLIRT, ANTs, and elastix do. The coarse pass's only job is to produce a decent initial transform for the full-res fine pass. Even a slightly less accurate coarse solution costs only a few extra fine-pass iterations.
5. **Implementation scope is modest.**
   - A pyramid builder (Gaussian pre-filter + stride-2 decimation) that adjusts `dx/dy/dz` metadata. AFNI does not ship a 3D equivalent of its 2D `mri_resize`, so a small helper `GA_downsample2x` was added in [mri_genalign_util.c](../src/mri_genalign_util.c) next to the existing `GA_smooth`.
   - In the coarse-pass block around [3dAllineate.c:5436](../src/3dAllineate.c#L5436): build `im_bset_ds`, `im_targ_ds`, `im_wset_ds` once; pass them to `mri_genalign_scalar_setup` instead of the full-res versions.
   - At the coarse→fine handoff at [3dAllineate.c:5817-5825](../src/3dAllineate.c#L5817-L5825): restore `im_bset`, `im_wset`, `im_targ` to the full-res versions and clear `didtwo` so the fine pass re-initializes from the originals. Transform parameters are in world coordinates, so they transfer across resolutions without any conversion.

### Baseline vs `-DALLIN_DOWNSAMPLE_COARSE`

Apple M-series, gcc-15, Makefile.macos_13_ARM_clang, `-O2`, OMP_NUM_THREADS=10.

| case       | cost | grid | wall (s) base | wall (s) ds | speedup | peak (MB) base | peak (MB) ds | NCC base | NCC ds  | Δ NCC    |
|------------|------|------|--------------:|------------:|--------:|---------------:|-------------:|---------:|--------:|---------:|
| ls_2mm     | ls   | 2 mm |           9.6 |         9.1 |   1.06× |           85.0 |         77.5 |   0.9002 |  0.9000 |  −0.0002 |
| ls_1mm     | ls   | 1 mm |          34.1 |        23.4 |   1.46× |          574.8 |        558.4 |   0.8613 |  0.8614 |  +0.0001 |
| default    | lpa  | 1 mm |         107.6 |        48.6 | **2.21×** |        617.5 |        565.5 |   0.8567 |  0.8535 |  −0.0032 |
| cmass      | lpa  | 1 mm |         114.2 |        52.5 | **2.17×** |        614.4 |        563.6 |   0.8565 |  0.8563 |  −0.0002 |
| fmri_lpc   | lpc  | xmod |          12.8 |        11.1 |   1.16× |          464.8 |        469.8 |   0.4366 |  0.4399 |  +0.0033 |

All Δ NCC well within the acceptance gates defined below. The big wins are on the 1 mm `lpa`/`cmass` cases where the coarse pass dominated; the 2 mm cases are already bottlenecked on the fine pass, so the coarse speedup is a small fraction of total wall time.

`fmri_lpc` is cross-modal (EPI → T1); its low absolute NCC is expected — it's tracked as a regression signal, not an accuracy target.

### Build

Optimized build matching the AFNI Linux default (`-O2`). On Apple ARM (macOS 13+, Homebrew gcc-15):

**Baseline (unmodified behavior, proven code path):**

```bash
cd src
cp Makefile.macos_13_ARM_clang Makefile    # or: ln -sf Makefile.macos_13_ARM_clang Makefile
rm -f 3dAllineate.o 3dAllineate
make -j 3dAllineate
```

**Optimized (enables the surgical coarse-pass downsampling):**

```bash
cd src
cp Makefile.macos_13_ARM_clang Makefile
rm -f 3dAllineate.o 3dAllineate
make -j CEXTRA="-m64 -Wall -Wno-deprecated-declarations -Wcomment -Wformat \
 -DUSE_TRACING -DHAVE_XDBE -DDONT_USE_MCW_MALLOC -DALLIN_DOWNSAMPLE_COARSE" 3dAllineate
```

The `-DALLIN_DOWNSAMPLE_COARSE` macro toggles three `#ifdef`-guarded blocks in [src/3dAllineate.c](../src/3dAllineate.c); when the macro is undefined the original code path compiles unchanged, byte-for-byte. To confirm the flag was picked up, either run with `-verb` and look for the line

```
++ ALLIN_DOWNSAMPLE_COARSE: coarse pass on 2x-decimated grid (...)
```

or inspect the compile command — the flag should appear in the invocation that produces `3dAllineate.o`. After a rebuild, A/B the two binaries with `./bench.sh`:

```bash
cd examples
./bench.sh ../src/3dAllineate baseline_O2   # with baseline binary
./bench.sh ../src/3dAllineate dscoarse      # with optimized binary
diff bench_results_baseline_O2.tsv bench_results_dscoarse.tsv
```
