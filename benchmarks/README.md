# MANIAC benchmark

`run-benchmark.sh` measures how fast MANIAC runs on a few fixed systems from
the `mc-topology` submodule. It can compare several binaries side by side, for
example before and after a change, or a debug build against an optimized one.

## Quick start

```bash
git submodule update --init          # once, provides the test systems
./build.sh                           # builds build/maniac (debug flags)

benchmarks/run-benchmark.sh                    # benchmark build/maniac
benchmarks/run-benchmark.sh --build-release    # + an optimized build (-O3 -march=native)
benchmarks/run-benchmark.sh --quick            # 5x shorter, 1 repeat, for a sanity check
```

To compare two versions of the code, build each one and pass both binaries.
The first binary is the reference for the speedup column:

```bash
benchmarks/run-benchmark.sh before=/path/to/old/maniac after=build/maniac
```

Other options: `--cases zif8-h2o,h2o-gas`, `--repeats 5`, `--out DIR`,
`--keep-runs`, `--help`.

## What is measured

For each case and binary, two runs are made, each repeated `--repeats` times
(the median is reported):

| Column | Meaning |
| --- | --- |
| `setup (s)` | Wall time of a run with `nb_block 0` / `nb_step 0`: reading the inputs and computing the initial full energy. For the ZIF‑8 cases this is far from negligible. |
| `MC (ms/step)` | `(full run − setup run) / (nb_block × nb_step)`. This is the cost of the Monte Carlo loop itself, including output written at the end of each block. |
| `spread` | `(max − min) / median` of the MC time over the repeats. A large spread means the comparison needs more repeats. |
| `speedup` | MC time per step of the first binary divided by this binary's. |
| `initial TotEng` | Initial total energy (kcal/mol), which is deterministic. It must agree between binaries to a relative 10⁻⁶. Otherwise the line is flagged `ENERGY DIFFERS` and the script exits with status 1. |

The results are also written as CSV in `benchmarks/results/`, so runs can be
compared over time. Run directories, with MANIAC's own outputs and logs, go
to `benchmarks/.work/`. They are deleted after a successful run unless
`--keep-runs` is given, and kept when something fails. All of these are
git-ignored.

## Cases

| Case | System | Stresses |
| --- | --- | --- |
| `zif8-h2o` | ZIF‑8 (2208 rigid atoms) + 3 TIP4P waters, translation/rotation | host–guest pair loop, Ewald updates |
| `zif8-ch4o-gcmc` | ZIF‑8 + methanol, with insertion/deletion | GCMC moves (full molecule energies, Fourier save/restore) |
| `h2o-gas` | 148 TIP4P waters, no framework | guest–guest pair loop with many molecules |
| `lj-gas` | 52 LJ atoms | per-step overhead and per-block output |

Each case uses the original `input.maniac` from `mc-topology`, with only
`nb_block` and `nb_step` replaced. The run lengths are set in the `CASES` array
at the top of the script.

## Caveats

- **Randomness.** A `seed` in the input currently has no effect (see
  `REVIEW.md`, potential bug #4), so every run follows a different trajectory.
  This matters mostly for `zif8-ch4o-gcmc`, where the number of molecules, and
  therefore the cost per step, changes from run to run. Use more repeats for
  that case, or compare it only once the seed is honoured.
- **Steps counted.** The time per step is divided by `nb_block × nb_step`. The
  current main loop runs one extra block (potential bug #3), so the absolute
  values are about 10% high. Comparisons between binaries are not affected as
  long as both have the same loop.
- **Small cases are noisy.** `lj-gas` takes well under a second, so its
  numbers are dominated by timer resolution and file I/O.
- Wall-clock timing is sensitive to other load on the machine. For decisions,
  run on an idle machine with `--repeats 5` or more.
