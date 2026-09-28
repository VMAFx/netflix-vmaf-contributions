#!/usr/bin/env bash
# Retest kit for the 2026-09-28 Netflix/vmaf review pass (see README.md).
# Linux, native: needs git, meson, ninja, nasm, gcc (or clang), python3, taskset.
#
#   ./run.sh setup              clone Netflix/vmaf and create one worktree per ref
#   ./run.sh build [tree...]    build libvmaf + checkasm in each tree (default: all)
#   ./run.sh check [tree...]    meson test + checkasm (stock and widened inputs), 20 seeds
#   ./run.sh bench [tree...]    interleaved checkasm --bench on one pinned core
#   ./run.sh dwt2               Netflix/vmaf#1564 residual: SIMD vs scalar before/after patches/dwt2-tail-bound.diff
#   ./run.sh all                setup, build, check, bench, dwt2
#
# Environment: WORK (default ./work), CORE (bench core, default 2), SEEDS (default 20),
#              RUNS (bench repetitions, default 6), CC/CXX (compiler), BENCH_PATTERNS.
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/work}"
CORE="${CORE:-2}"
SEEDS="${SEEDS:-20}"
RUNS="${RUNS:-6}"
REPO="$WORK/vmaf"
OUT="$WORK/results"
UPSTREAM=https://github.com/Netflix/vmaf.git
CONTRIB=https://github.com/VMAFx/netflix-vmaf-contributions.git
# tree name -> PR number (or "master"). PRs use GitHub's test merge with master
# (refs/pull/N/merge), which is what upstream CI builds; a PR without a merge ref
# (conflicting) falls back to its head. #1609's head predates checkasm, so only the
# merge ref has a checkasm tree to test.
TREES="master:master
pr1584:1584 pr1585:1585 pr1586:1586 pr1609:1609
pr1602:1602 pr1600:1600 pr1601:1601 pr1599:1599
pr1603:1603 pr1604:1604 pr1620:1620 pr1621:1621"
BENCH_PATTERNS="${BENCH_PATTERNS:-adm_decouple_* adm_cm_* i4_adm_cm_* adm_csf_den_* vif_statistic_*}"

log() { printf '== %s\n' "$*" >&2; }
tree_names() { printf '%s\n' $TREES | cut -d: -f1; }
tree_ref() { printf '%s\n' $TREES | awk -F: -v t="$1" '$1==t{print $2}'; }
sel() { if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else tree_names; fi; }

cmd_setup() {
  mkdir -p "$WORK" "$OUT"
  if [ ! -d "$REPO/.git" ]; then
    git clone -q "$UPSTREAM" "$REPO"
  fi
  git -C "$REPO" fetch -q origin master
  for t in $(tree_names); do
    ref=$(tree_ref "$t")
    if [ "$ref" = master ]; then
      rev=origin/master
    elif git -C "$REPO" fetch -q origin "+refs/pull/$ref/merge:refs/remotes/pr/$ref" 2>/dev/null; then
      rev=refs/remotes/pr/$ref
    else
      log "$t: no merge ref (conflicting?); using the PR head"
      git -C "$REPO" fetch -q origin "+refs/pull/$ref/head:refs/remotes/pr/$ref"
      rev=refs/remotes/pr/$ref
    fi
    if [ -d "$WORK/$t" ]; then
      git -C "$WORK/$t" checkout -q --detach "$rev"
    else
      git -C "$REPO" worktree add -q --detach "$WORK/$t" "$rev"
    fi
    log "$t -> $(git -C "$WORK/$t" rev-parse --short=9 HEAD) $(git -C "$WORK/$t" log -1 --format=%s | cut -c1-60)"
  done
  # Widened-input copies for the anematode PRs and master (see widen()).
  for t in master pr1584 pr1585 pr1586 pr1609; do
    if [ -d "$WORK/$t" ]; then widen "$t"; fi
  done
}

# Widen checkasm inputs: ADM int32 bands to +-2^20 (stock +-8000 never reaches the
# abs >= 32768 path) and VIF 8-bit to flat 32x32 blocks with sparse +-1/+-2 noise
# (stock uniform noise never reaches sigma1_sq < 2*65536). Creates tree "<t>-w".
widen() {
  local t="$1" w="$WORK/$1-w"
  rm -rf "$w"
  git -C "$REPO" worktree prune
  git -C "$REPO" worktree add -q --detach "$w" "$(git -C "$WORK/$t" rev-parse HEAD)"
  local f="$w/libvmaf/test/checkasm/check_adm.c" v="$w/libvmaf/test/checkasm/check_vif.c"
  [ -f "$f" ] || {
    log "$t has no checkasm tree; skipping widen"
    rm -rf "$w"
    git -C "$REPO" worktree prune
    return 0
  }
  awk 'BEGIN{inf=0} /static void fill_band_i32/ {inf=1}
       inf && /% 16001\) - 8000/ { sub(/% 16001\) - 8000/, "% 2097153) - 1048576"); inf=0 } {print}' "$f" >"$f.new" && mv "$f.new" "$f"
  awk '
    /ref\[r \* s.buf.stride \+ c\] = \(uint8_t\) checkasm_rand_uint32\(\);/ && !r8 {
      print "                { const unsigned blk = ((r / 32) * 7 + (c / 32) * 13) & 0xff; const uint32_t rv = checkasm_rand_uint32();"
      print "                  ref[r * s.buf.stride + c] = (uint8_t) (blk + ((rv & 63) == 0 ? ((rv >> 6) & 1 ? 1 : -1) : 0)); }"
      r8=1; next }
    /dis\[r \* s.buf.stride \+ c\] = \(uint8_t\) checkasm_rand_uint32\(\);/ && !d8 {
      print "                { const unsigned blk = ((r / 32) * 7 + (c / 32) * 13 + 3) & 0xff; const uint32_t rv = checkasm_rand_uint32();"
      print "                  dis[r * s.buf.stride + c] = (uint8_t) (blk + ((rv & 31) == 0 ? ((rv >> 5) & 1 ? 2 : -2) : 0)); }"
      d8=1; next }
    {print}' "$v" >"$v.new" && mv "$v.new" "$v"
  grep -q 2097153 "$f" && log "$t-w: widened ADM bands" || log "$t-w: ADM pattern not found (check_adm.c changed?)"
  grep -q "blk" "$v" && log "$t-w: flat VIF blocks" || log "$t-w: VIF pattern not found (check_vif.c changed?)"
}

build_one() {
  local t="$1" d="$WORK/$1"
  [ -d "$d" ] || {
    log "no tree $t (run setup)"
    return 1
  }
  (cd "$d/libvmaf" &&
    { [ -d build ] || meson setup build --buildtype release -Denable_checkasm=true -Denable_float=true -Denable_docs=false >"$OUT/$t.setup.log" 2>&1; } &&
    ninja -C build >"$OUT/$t.build.log" 2>&1) &&
    log "$t built ($(grep -c 'warning:' "$OUT/$t.build.log" || true) warnings)" ||
    {
      log "$t BUILD FAILED, see $OUT/$t.build.log"
      return 1
    }
}

cmd_build() {
  mkdir -p "$OUT"
  local all=$(sel "$@")
  for t in $all; do
    build_one "$t" || true
    [ -d "$WORK/$t-w" ] && build_one "$t-w" || true
  done
}

cmd_check() {
  mkdir -p "$OUT"
  {
    echo "# check $(date -u +%FT%TZ) on $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
    grep -m1 -o 'avx512[a-z_]*' /proc/cpuinfo | head -1 | sed 's/^/# first avx512 flag: /' || echo "# no avx512 flags"
  } >"$OUT/check.txt"
  for t in $(sel "$@"); do
    for tt in "$t" "$t-w"; do
      local d="$WORK/$tt/libvmaf/build"
      [ -x "$d/test/checkasm/checkasm" ] || continue
      if [ "$tt" = "$t" ]; then
        (cd "$WORK/$tt/libvmaf" && meson test -C build --print-errorlogs >"$OUT/$tt.mesontest.log" 2>&1) &&
          echo "$tt meson test: ok" >>"$OUT/check.txt" || echo "$tt meson test: FAIL ($OUT/$tt.mesontest.log)" >>"$OUT/check.txt"
      fi
      local fails=0 s=1
      while [ "$s" -le "$SEEDS" ]; do
        "$d/test/checkasm/checkasm" "$s" >"$OUT/$tt.casm.$s.log" 2>&1 || fails=$((fails + 1))
        s=$((s + 1))
      done
      echo "$tt checkasm: $fails of $SEEDS seeds failing" >>"$OUT/check.txt"
    done
  done
  cat "$OUT/check.txt"
}

cmd_bench() {
  mkdir -p "$OUT"
  local trees=$(sel "$@") raw
  raw=$(mktemp)
  for pat in $BENCH_PATTERNS; do
    local i=0
    while [ "$i" -lt "$RUNS" ]; do
      for t in $trees; do
        local b="$WORK/$t/libvmaf/build/test/checkasm/checkasm"
        [ -x "$b" ] || continue
        "$b" --affinity="$CORE" --bench -f "$pat" 2>/dev/null |
          awk -v t="$t" '/_(c|avx2|avx512|avx512icl):/ {gsub(":","",$1); print t, $1, $2}' >>"$raw"
      done
      i=$((i + 1))
    done
  done
  sort -k2,2 -k1,1 "$raw" | awk '
    { k=$2" "$1; v[k]=v[k]" "$3 }
    END { for (k in v) { m=split(substr(v[k],2),a," ");
            for (x=1;x<=m;x++) for (y=x+1;y<=m;y++) if (a[y]+0<a[x]+0) {t=a[x];a[x]=a[y];a[y]=t}
            med=(m%2)?a[(m+1)/2]:(a[m/2]+a[m/2+1])/2; printf "%-48s min=%10.1f med=%10.1f n=%d\n", k, a[1], med, m } }' |
    sort >"$OUT/bench.txt"
  rm -f "$raw"
  {
    echo "# bench core=$CORE runs=$RUNS cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
    cat "$OUT/bench.txt"
  } >"$OUT/bench.with-header.txt"
  cat "$OUT/bench.with-header.txt"
}

cmd_dwt2() {
  mkdir -p "$OUT"
  local base="$WORK/master" fix="$WORK/dwt2fix" clips="$WORK/clips"
  [ -d "$fix" ] || git -C "$REPO" worktree add -q --detach "$fix" "$(git -C "$base" rev-parse HEAD)"
  (cd "$fix" && git apply "$KIT/patches/dwt2-tail-bound.diff" 2>/dev/null || git apply --check -R "$KIT/patches/dwt2-tail-bound.diff")
  build_one master
  build_one dwt2fix
  mkdir -p "$clips"
  for spec in "66 34" "130 72"; do
    set -- $spec
    for b in 8 10; do
      python3 "$KIT/gen.py" "$1" "$2" 3 "$b" 420 1 "$clips/r${1}_$b.yuv"
      python3 "$KIT/gen.py" "$1" "$2" 3 "$b" 420 2 "$clips/d${1}_$b.yuv" 3
    done
  done
  : >"$OUT/dwt2.txt"
  for t in master dwt2fix; do
    local v="$WORK/$t/libvmaf/build/tools/vmaf"
    for spec in "66 34" "130 72"; do
      set -- $spec
      for b in 8 10; do
        for mask in default scalar; do
          local m=""
          [ "$mask" = scalar ] && m="--cpumask -1"
          "$v" -r "$clips/r${1}_$b.yuv" -d "$clips/d${1}_$b.yuv" -w "$1" -h "$2" -p 420 -b "$b" -n \
            --feature adm $m --json -o "$OUT/dwt2.$t.${1}x${2}.$b.$mask.json" -q >/dev/null 2>&1 || true
          python3 - "$OUT/dwt2.$t.${1}x${2}.$b.$mask.json" "$t ${1}x${2} ${b}bit $mask" >>"$OUT/dwt2.txt" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(sys.argv[2], [round(f["metrics"]["integer_adm2"], 6) for f in d["frames"]])
except Exception as e:
    print(sys.argv[2], "run failed:", e)
PY
        done
      done
    done
  done
  cat "$OUT/dwt2.txt"
}

case "${1:-}" in
  setup)
    shift
    cmd_setup "$@"
    ;;
  build)
    shift
    cmd_build "$@"
    ;;
  check)
    shift
    cmd_check "$@"
    ;;
  bench)
    shift
    cmd_bench "$@"
    ;;
  dwt2)
    shift
    cmd_dwt2 "$@"
    ;;
  all)
    cmd_setup
    cmd_build
    cmd_check
    cmd_bench
    cmd_dwt2
    ;;
  *)
    sed -n '2,15p' "$0"
    exit 2
    ;;
esac
