#!/usr/bin/env bash
# Benchmark harness for 3dAllineate.
# Records wall time, peak RSS, and voxel-wise NCC vs the base for each case.
#
# Usage: ./bench.sh [path/to/3dAllineate] [label]
#   default binary: ../src/3dAllineate
#   default label:  baseline
#
# Output: bench_results_<label>.tsv  and  bench_log_<label>.txt

set -u

BIN="${1:-../src/3dAllineate}"
LABEL="${2:-baseline}"
THREADS="${OMP_NUM_THREADS:-10}"
export OMP_NUM_THREADS="$THREADS"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

OUTDIR="./afni"
mkdir -p "$OUTDIR"

RESULTS="bench_results_${LABEL}.tsv"
LOG="bench_log_${LABEL}.txt"

: > "$LOG"
printf "name\twall_s\tpeak_mb\tncc\toutput\tbase\n" > "$RESULTS"

# run_case <name> <base> <input> <output> [extra 3dAllineate args...]
run_case () {
  local name="$1" base="$2" input="$3" out="$4"; shift 4
  local cmd=( "$BIN" -base "$base" -input "$input" -prefix "$out" "$@" )
  rm -f "$out"
  echo "=== $name ===" | tee -a "$LOG"
  echo "CMD: ${cmd[*]}" | tee -a "$LOG"
  local tstamp_file; tstamp_file="$(mktemp)"
  /usr/bin/time -lp "${cmd[@]}" >>"$LOG" 2>"$tstamp_file"
  cat "$tstamp_file" >> "$LOG"
  local wall peak_bytes peak_mb ncc
  wall="$(awk '/^real/ {print $2}' "$tstamp_file")"
  peak_bytes="$(awk '/maximum resident set size/ {print $1}' "$tstamp_file")"
  peak_mb="$(awk -v b="$peak_bytes" 'BEGIN{printf "%.1f", b/1024/1024}')"
  rm -f "$tstamp_file"
  ncc="$(python3 ./ncc.py "$out" "$base" 2>>"$LOG" || echo NaN)"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$name" "$wall" "$peak_mb" "$ncc" "$out" "$base" | tee -a "$RESULTS"
}

# Five cases, matching README.md block
run_case ls_2mm   ./MNI152_T1_2mm.nii.gz  ./T1_head_2mm.nii.gz  "$OUTDIR/wT1ls_2mm.nii.gz"  -cost ls
run_case ls_1mm   ./MNI152_T1_1mm.nii.gz  ./T1_head.nii.gz      "$OUTDIR/wT1ls.nii.gz"      -cost ls
run_case default  ./MNI152_T1_1mm.nii.gz  ./T1_head.nii.gz      "$OUTDIR/wT1.nii.gz"
run_case cmass    ./MNI152_T1_1mm.nii.gz  ./T1_head.nii.gz      "$OUTDIR/wT1cmas.nii.gz"    -cmass
run_case fmri_lpc ./T1_head.nii.gz        ./fmri.nii.gz         "$OUTDIR/fmri2t1.nii.gz"    -cmass -cost lpc -source_automask

echo
echo "Wrote $RESULTS"
echo "Full log in $LOG"
