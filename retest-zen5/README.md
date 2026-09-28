# Zen 5 retest kit (Netflix/vmaf review pass, 2026-09-28)

This kit re-runs the correctness and benchmark evidence behind the 2026-09-28
Netflix/vmaf posts on a Zen 5 host. That evidence came from an AVX2-only
i9-12900K and from GitHub's EPYC 7763 (Zen 3) checkasm runners, so **no AVX-512
kernel was ever executed**. Zen 5 has full-width AVX-512, so this is the first
run of those paths.

## Quick start

```sh
git clone -b retest/zen5 --single-branch https://github.com/VMAFx/netflix-vmaf-contributions.git zen5
cd zen5/retest-zen5
sudo apt install git meson ninja-build nasm gcc g++ python3 util-linux   # or the distro equivalent
CORE=2 ./run.sh all          # results in ./work/results/
```

`run.sh setup` clones Netflix/vmaf and creates one git worktree per reference.
PRs are checked out at GitHub's test merge with master (`refs/pull/N/merge`,
falling back to the head when a PR conflicts), which is what upstream CI builds.
That matters for #1609, whose head predates the checkasm integration. anematode's
PRs are included this way even though we can't comment on them. The subcommands (`build`,
`check`, `bench`, `dwt2`) can be re-run individually and take tree names, e.g.
`./run.sh bench master pr1609`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `WORK` | `./work` | clone, worktrees, results |
| `CORE` | `2` | core `checkasm --bench` pins to; pick one core on one CCD |
| `SEEDS` | `20` | checkasm seeds per tree in `check` |
| `RUNS` | `6` | interleaved bench repetitions (min and median are reported) |
| `BENCH_PATTERNS` | ADM and VIF kernels | checkasm `-f` patterns |

## What to look at

| Item | Where it was claimed | What Zen 5 adds | Output |
| --- | --- | --- | --- |
| #1609 `vpblendvb` in `adm_decouple*` | #1622 (3–9% on Zen 3) | Zen 5 numbers vs master; AVX-512 correctness | `bench.txt`, `check.txt` for `pr1609`, `pr1609-w` |
| #1586 `vpabsd` in `i4_adm_cm_avx2` | #1623 (4.6–7.0% on Zen 3) | same | `bench.txt` (`i4_adm_cm_*`) |
| #1585 VIF gather loop | #1624 | AMD is not affected by GDS, so this is a plain throughput number; the widened VIF inputs reach `accum_num_non_log` | `bench.txt` (`vif_statistic_*`), `check.txt` `pr1585-w` |
| #1584 ADM decouple | our 2026-09-21 review | widened ADM bands reach `abs >= 32768` | `check.txt` `pr1584-w` |
| #1602 (`a0c54d6`) `adm_cm` centre tap + AVX2 cube shift | #1602, #1610 | **AVX-512 kernels were built but never run**; `test_adm_cm_large_coeffs` and checkasm now exercise them | `check.txt` `pr1602`, `pr1602.mesontest.log` |
| #1601 16-bit scale-0 dwt2 UB | #1601 | its AVX-512 claims were unverified | `check.txt` `pr1601` |
| #1564 residual dwt2 cutoffs | our #1564 comment | `adm_dwt2_16_avx512` and `adm_dwt2_8_avx512` were never run; 8-bit at width 66 (`half_w` 33, 1 mod 32) should now show SIMD ≠ scalar on master and equal after `patches/dwt2-tail-bound.diff` | `dwt2.txt` |
| #1599, #1600, #1603, #1604, #1620, #1621 | their PR bodies | sanity: full `meson test` on Zen 5 | `check.txt` |

The `-w` trees are copies with widened checkasm inputs:

- ADM int32 bands run to ±2^20 instead of ±8000.
- VIF 8-bit uses flat 32x32 blocks with sparse ±1/±2 noise instead of uniform noise.

Stock checkasm never reaches the interesting SIMD branches, so a green upstream
badge says nothing about them.

## Afterwards

- **#1564:** if the 8-bit 66x34 row differs between the default dispatch and `--cpumask -1` on master and matches with the patch, the AVX-512 half of the comment is confirmed. The patch can then go upstream as a PR once it has a checkasm case (coordinate with #1603, which edits the same test) and credits dsummer.
- **#1622, #1623, #1624:** add Zen 5 numbers as follow-up comments on those issues. We cannot post on the PRs themselves.
- **#1602, #1601:** if the AVX-512 kernels pass, say so in a short comment and drop the "no AVX-512 host" caveat.
- **`patches/speed-temporal-clamp.diff`:** `speed_temporal` ignores its own `speed_max_val`. Verified by CLI only; it needs a test before it goes upstream.

Line numbers in the posts refer to upstream master `86da14d03`. If master has
moved, re-check them before quoting.
