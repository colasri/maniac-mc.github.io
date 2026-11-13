#!/bin/bash
#
# MANIAC performance benchmark.
#
# Runs a fixed set of systems from the mc-topology submodule and reports,
# for each binary:
#   - setup time      : wall time of a run with nb_block 0 / nb_step 0
#                       (input parsing + initial full energy calculation)
#   - time per MC step: (full run - setup run) / (nb_block * nb_step)
#   - initial energy  : TotEng of the "Initial Energy Report", used as a
#                       correctness check between binaries (it is deterministic)
#
# Usage:
#   benchmarks/run-benchmark.sh [options] [label=]path/to/maniac ...
#
# Options:
#   --build-release   Build an optimized binary from the current sources
#                     (in benchmarks/.build/release, the main build is untouched)
#                     and add it to the comparison under the label "release".
#   --cases a,b,...   Only run these cases (default: all, see CASES below).
#   --repeats N       Number of repetitions per case and binary (default: 3).
#                     The median is reported.
#   --quick           5x fewer steps and 1 repeat, for a fast sanity check.
#   --out DIR         Where to write results (default: benchmarks/results).
#   --keep-runs       Keep the run directories (outputs, logs) in benchmarks/.work.
#                     By default they are deleted after a successful benchmark.
#   -h, --help        Show this help.
#
# With no binary given, build/maniac is used (label "current").
#
# Examples:
#   benchmarks/run-benchmark.sh
#   benchmarks/run-benchmark.sh --build-release
#   benchmarks/run-benchmark.sh before=/tmp/maniac-main after=build/maniac
#
# Requirements: bash, awk, sed, GNU date (for %N). gfortran + make + makedepf90
# for --build-release. The mc-topology submodule must be checked out:
#   git submodule update --init

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="$ROOT_DIR/benchmarks"
TOPO_DIR="$ROOT_DIR/mc-topology"

# ---------------------------------------------------------------------------
# Benchmark cases: name | folder (relative to mc-topology) | nb_block | nb_step | what it stresses
# The original input.maniac of each folder is used, only nb_block/nb_step are changed.
# ---------------------------------------------------------------------------
CASES=(
  "zif8-h2o|testcase-energy/ZIF8-H2O|10|200|rigid framework (2208 atoms) + 3 TIP4P waters, translation/rotation"
  "zif8-ch4o-gcmc|testcase-adsorption/ZIF8-CH4O|10|100|rigid framework + methanol, GCMC (insertion/deletion)"
  "h2o-gas|testcase-energy/H2O-gas|10|500|148 TIP4P waters, no framework, translation/rotation"
  "lj-gas|testcase-energy/LJ-gas|10|5000|52 LJ atoms, small system: per-step overhead and output"
)

usage() { sed -n '3,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
BUILD_RELEASE=false
ONLY_CASES=""
REPEATS=3
QUICK=false
OUT_DIR="$BENCH_DIR/results"
KEEP_RUNS=false
LABELS=()
BINARIES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-release) BUILD_RELEASE=true ;;
        --cases) ONLY_CASES="$2"; shift ;;
        --repeats) REPEATS="$2"; shift ;;
        --quick) QUICK=true ;;
        --out) OUT_DIR="$2"; shift ;;
        --keep-runs) KEEP_RUNS=true ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *)
            if [[ "$1" == *=* ]]; then
                LABELS+=("${1%%=*}"); BINARIES+=("${1#*=}")
            else
                LABELS+=("$(basename "$(dirname "$1")")-$(basename "$1")"); BINARIES+=("$1")
            fi
            ;;
    esac
    shift
done

if $QUICK; then REPEATS=1; fi

if [[ ! -f "$TOPO_DIR/testcase-energy/ZIF8-H2O/topology.data" ]]; then
    echo "ERROR: mc-topology submodule not found. Run: git submodule update --init" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Optional optimized build, done in a copy so build/ and include/ are untouched
# ---------------------------------------------------------------------------
if $BUILD_RELEASE; then
    REL_DIR="$BENCH_DIR/.build/release"
    echo "Building optimized binary in $REL_DIR ..."
    rm -rf "$REL_DIR"; mkdir -p "$REL_DIR"
    cp -r "$ROOT_DIR/src" "$ROOT_DIR/Makefile" "$REL_DIR/"
    VERSION=$(xargs < "$ROOT_DIR/version.txt")
    sed -e "s/@VERSION@/$VERSION/" "$REL_DIR/src/version_module.f90.in" > "$REL_DIR/src/version_module.f90"
    ( cd "$REL_DIR" && make depend > build.log 2>&1 \
        && make -j"$(nproc 2>/dev/null || echo 2)" FFLAGS="-O3 -march=native -Jinclude" >> build.log 2>&1 ) \
        || { echo "ERROR: release build failed, see $REL_DIR/build.log" >&2; exit 1; }
    LABELS+=("release"); BINARIES+=("$REL_DIR/build/maniac")
fi

# Default binary
if [[ ${#BINARIES[@]} -eq 0 ]] || { $BUILD_RELEASE && [[ ${#BINARIES[@]} -eq 1 ]]; }; then
    LABELS=("current" "${LABELS[@]}"); BINARIES=("$ROOT_DIR/build/maniac" "${BINARIES[@]}")
fi

for i in "${!BINARIES[@]}"; do
    BINARIES[$i]="$(cd "$(dirname "${BINARIES[$i]}")" && pwd)/$(basename "${BINARIES[$i]}")"
    [[ -x "${BINARIES[$i]}" ]] || { echo "ERROR: not an executable: ${BINARIES[$i]}" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
now() { date +%s.%N; }

median() { # median of the arguments
    printf '%s\n' "$@" | sort -g | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

spread() { # (max - min) / median, in percent
    printf '%s\n' "$@" | sort -g | awk '{a[NR]=$1} END {
        m = (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2
        printf "%.0f%%", (m > 0 ? (a[NR]-a[1]) / m * 100 : 0)}'
}

# run_maniac <binary> <case folder> <nb_block> <nb_step> <work dir>  -> prints elapsed seconds
run_maniac() {
    local bin=$1 dir=$2 nb=$3 ns=$4 work=$5
    mkdir -p "$work"
    sed -e "s/^nb_block.*/nb_block $nb/" -e "s/^nb_step.*/nb_step $ns/" \
        "$dir/input.maniac" > "$work/input.maniac"
    local t0 t1
    t0=$(now)
    if ! "$bin" -i "$work/input.maniac" -d "$dir/topology.data" -p "$dir/parameters.inc" \
            -o "$work/outputs/" > "$work/stdout.log" 2>&1; then
        echo "ERROR: run failed, see $work/stdout.log" >&2
        return 1
    fi
    t1=$(now)
    awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.4f", b - a}'
}

initial_energy() { # TotEng from the initial energy report
    awk '/Initial Energy Report/ {f=1} f && $2 ~ /^0$/ {print $3; exit}' "$1"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
WORK_ROOT="$BENCH_DIR/.work/$STAMP"
mkdir -p "$OUT_DIR" "$WORK_ROOT"
CSV="$OUT_DIR/benchmark-$STAMP.csv"
echo "case,label,binary,nb_block,nb_step,repeats,setup_s,mc_ms_per_step,mc_spread,initial_energy" > "$CSV"

echo
echo "MANIAC benchmark  ($(date '+%Y-%m-%d %H:%M'), host $(uname -n), repeats=$REPEATS$($QUICK && echo ', quick'))"
for i in "${!BINARIES[@]}"; do echo "  ${LABELS[$i]}: ${BINARIES[$i]}"; done
echo

printf '%-16s %-12s %10s %14s %8s %10s %20s\n' "case" "binary" "setup (s)" "MC (ms/step)" "spread" "speedup" "initial TotEng"
printf '%-16s %-12s %10s %14s %8s %10s %20s\n' "----" "------" "---------" "------------" "------" "-------" "--------------"

STATUS=0
for entry in "${CASES[@]}"; do
    IFS='|' read -r name rel nb ns _desc <<< "$entry"
    if [[ -n "$ONLY_CASES" && ",$ONLY_CASES," != *",$name,"* ]]; then continue; fi
    $QUICK && ns=$(( ns / 5 > 0 ? ns / 5 : 1 ))
    dir="$TOPO_DIR/$rel"
    steps=$(( nb * ns ))
    ref_step=""; ref_energy=""

    for i in "${!BINARIES[@]}"; do
        label=${LABELS[$i]}; bin=${BINARIES[$i]}
        setups=(); mcs=()
        for r in $(seq 1 "$REPEATS"); do
            w="$WORK_ROOT/$name/$label/$r"
            ts=$(run_maniac "$bin" "$dir" 0 0 "$w/setup") || { STATUS=1; continue 2; }
            tf=$(run_maniac "$bin" "$dir" "$nb" "$ns" "$w/full") || { STATUS=1; continue 2; }
            setups+=("$ts")
            mcs+=("$(awk -v f="$tf" -v s="$ts" -v n="$steps" 'BEGIN {printf "%.6f", (f - s) * 1000 / n}')")
        done
        setup_med=$(median "${setups[@]}")
        mc_med=$(median "${mcs[@]}")
        mc_spread=$(spread "${mcs[@]}")
        energy=$(initial_energy "$WORK_ROOT/$name/$label/1/setup/stdout.log")

        if [[ -z "$ref_step" ]]; then
            ref_step=$mc_med; ref_energy=$energy; speedup="1.00x"; flag=""
        else
            speedup=$(awk -v a="$ref_step" -v b="$mc_med" 'BEGIN {printf (b > 0 ? "%.2fx" : "n/a"), a / b}')
            # Correctness: initial energy must agree with the first binary (relative 1e-6)
            flag=$(awk -v a="$ref_energy" -v b="$energy" 'BEGIN {
                d = a - b; if (d < 0) d = -d; s = (a < 0 ? -a : a); if (s < 1) s = 1
                if (d / s > 1e-6) print "  <-- ENERGY DIFFERS"}')
            [[ -n "$flag" ]] && STATUS=1
        fi

        printf '%-16s %-12s %10.2f %14.3f %8s %10s %20s%s\n' "$name" "$label" "$setup_med" "$mc_med" "$mc_spread" "$speedup" "$energy" "$flag"
        echo "$name,$label,$bin,$nb,$ns,$REPEATS,$setup_med,$mc_med,$mc_spread,$energy" >> "$CSV"
    done
done

echo
echo "Results written to $CSV"
if [[ $STATUS -eq 0 ]] && ! $KEEP_RUNS; then
    rm -rf "$WORK_ROOT"
    rmdir "$BENCH_DIR/.work" 2>/dev/null || true
else
    echo "Run directories kept in $WORK_ROOT"
fi
echo "Note: 'speedup' compares MC time per step with the first binary listed."
exit $STATUS
