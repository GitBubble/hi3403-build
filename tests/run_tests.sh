#!/bin/bash
#=============================================================================
# tests/run_tests.sh — full validation of build.sh
#
# Each test runs against a FRESH tmpdir (TEST_ROOT) that symlinks build.sh,
# lib/, downloads/, pegasus/, docker/ from the real project, but has its
# OWN output/, .build-state/, logs/ — so reset_state actually resets and
# tests don't pollute each other.
#
# Phase 1: pure-shell commands (no Docker)
# Phase 2: per-function tests via mock docker
# Phase 3: sequencing scenarios
# Phase 4: edge cases
#=============================================================================

set +e   # tests handle their own pass/fail

REAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Set up an isolated test root ------------------------------------
TEST_ROOT="$(mktemp -d -t hi3403-tests.XXXXXX)"
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN" "$TEST_ROOT/lib" "$TEST_ROOT/docker" "$TEST_ROOT/downloads" "$TEST_ROOT/output"

ln -s "$REAL_ROOT/build.sh"             "$TEST_ROOT/build.sh"
ln -s "$REAL_ROOT/lib/common.sh"        "$TEST_ROOT/lib/common.sh"
ln -s "$REAL_ROOT/lib/checksums.txt"    "$TEST_ROOT/lib/checksums.txt"
ln -s "$REAL_ROOT/docker/Dockerfile"    "$TEST_ROOT/docker/Dockerfile"
# pegasus is needed for git rev-parse (state keys)
[ -d "$REAL_ROOT/pegasus" ] && ln -s "$REAL_ROOT/pegasus" "$TEST_ROOT/pegasus"

# Symlink each download into TEST_ROOT/downloads so we can swap individual
# files in-place during tests without touching the real files.
for f in "$REAL_ROOT/downloads/"*; do
    [ -e "$f" ] || continue
    ln -s "$f" "$TEST_ROOT/downloads/$(basename "$f")"
done

# Mock docker on PATH.
chmod +x "$REAL_ROOT/tests/mock_docker.sh"
ln -s "$REAL_ROOT/tests/mock_docker.sh" "$TEST_BIN/docker"
export PATH="$TEST_BIN:$PATH"
export MOCK_DOCKER_LOG="$TEST_ROOT/docker.log"
export OUTPUT_DIR="$TEST_ROOT/output"
: > "$MOCK_DOCKER_LOG"

# Counters
PASS=0; FAIL=0; FAILS=()

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
DIM='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'

# --- helpers ---------------------------------------------------------
banner() { printf "\n${BOLD}=== %s ===${NC}\n" "$*"; }
case_start() { printf "${DIM}[%02d]${NC} %-60s " "$1" "$2"; }
pass() { printf "${GREEN}PASS${NC}\n"; PASS=$((PASS + 1)); }
fail() { printf "${RED}FAIL${NC}  %s\n" "$1"; FAIL=$((FAIL + 1)); FAILS+=("$2: $1"); }

assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'" "$3"; }
assert_contains() {
    if printf '%s' "$2" | grep -q -- "$1"; then pass
    else fail "missing '$1'" "$3"; fi
}
assert_file()    { [ -f "$1" ] && pass || fail "missing file $1" "$2"; }
assert_no_file() { [ ! -e "$1" ] && pass || fail "should not exist: $1" "$2"; }

# Reset between tests: state markers + staging + output (downloads stay).
reset_state() {
    rm -rf "$TEST_ROOT/.build-state" "$TEST_ROOT/output/.staging" 2>/dev/null
    rm -rf "$TEST_ROOT/output/boot" "$TEST_ROOT/output/mpp" 2>/dev/null
    rm -f  "$TEST_ROOT/output/"*.img "$TEST_ROOT/output/"*.partial 2>/dev/null
    rm -rf "$TEST_ROOT/logs" 2>/dev/null
    : > "$MOCK_DOCKER_LOG"
}

# Count `docker run` invocations since last reset. Always one number, no error.
docker_run_count() {
    if [ -f "$MOCK_DOCKER_LOG" ]; then
        local n
        n=$(grep -c '^=== docker run ===$' "$MOCK_DOCKER_LOG" 2>/dev/null)
        printf '%s' "${n:-0}"
    else
        printf '0'
    fi
}

# Run TEST_ROOT/build.sh, capture stdout+stderr.
b() { HI3403_NO_LOG=1 "$TEST_ROOT/build.sh" "$@" 2>&1; }


#=============================================================================
banner "Phase 1 — pure-shell commands"
#=============================================================================

# 1.1 help variants
out="$(b --help)"
case_start 1 "--help shows usage"
assert_contains "Usage: ./build.sh" "$out" "1.1a"

out="$(b -h)"
case_start 2 "-h shows usage"
assert_contains "ubuntu_xfce_all" "$out" "1.1b"

out="$(b help)"
case_start 3 "help shows usage"
assert_contains "Examples:" "$out" "1.1c"

# 1.2 no args -> usage
out="$(b)"
case_start 4 "no args -> usage"
assert_contains "Usage: ./build.sh" "$out" "1.2"

# 1.3 unknown command
b badcommand >/dev/null 2>&1; rc=$?
case_start 5 "unknown command exits non-zero"
[ "$rc" -ne 0 ] && pass || fail "exit was $rc" "1.3"

# 1.4 verify (good) -> exit 0
out="$(b verify)"; rc=$?
case_start 6 "verify (all good) -> exit 0"
[ "$rc" -eq 0 ] && pass || fail "exit was $rc" "1.4a"
case_start 7 "verify reports all 5 verified"
assert_contains "All 5 downloads verified" "$out" "1.4b"

# 1.5 verify (corrupted): replace symlink with a real corrupted copy
saved="$(readlink "$TEST_ROOT/downloads/u-boot-2020.01.tar.gz")"
rm "$TEST_ROOT/downloads/u-boot-2020.01.tar.gz"
cp "$saved" "$TEST_ROOT/downloads/u-boot-2020.01.tar.gz"
echo CORRUPT >> "$TEST_ROOT/downloads/u-boot-2020.01.tar.gz"
out="$(b verify)"; rc=$?
case_start 8 "verify (corrupt sha) -> non-zero exit"
[ "$rc" -ne 0 ] && pass || fail "exit was $rc" "1.5a"
case_start 9 "verify reports SHA-256 mismatch"
assert_contains "SHA-256 mismatch" "$out" "1.5b"
# Restore symlink
rm "$TEST_ROOT/downloads/u-boot-2020.01.tar.gz"
ln -s "$saved" "$TEST_ROOT/downloads/u-boot-2020.01.tar.gz"

# 1.6 verify (missing file) — just remove the symlink
rm "$TEST_ROOT/downloads/v2.2.tar.gz"
out="$(b verify)"; rc=$?
case_start 10 "verify (missing) -> non-zero exit"
[ "$rc" -ne 0 ] && pass || fail "exit was $rc" "1.6a"
case_start 11 "verify reports missing"
assert_contains "missing: v2.2.tar.gz" "$out" "1.6b"
ln -s "$REAL_ROOT/downloads/v2.2.tar.gz" "$TEST_ROOT/downloads/v2.2.tar.gz"

# 1.7 verify (short file = 404 page)
saved="$(readlink "$TEST_ROOT/downloads/mbedtls-2.16.10.tar.gz")"
rm "$TEST_ROOT/downloads/mbedtls-2.16.10.tar.gz"
echo "<html>404</html>" > "$TEST_ROOT/downloads/mbedtls-2.16.10.tar.gz"
out="$(b verify)"; rc=$?
case_start 12 "verify (short = likely 404) -> non-zero"
[ "$rc" -ne 0 ] && pass || fail "exit was $rc" "1.7a"
case_start 13 "verify reports size below min"
assert_contains "size" "$out" "1.7b"
rm "$TEST_ROOT/downloads/mbedtls-2.16.10.tar.gz"
ln -s "$saved" "$TEST_ROOT/downloads/mbedtls-2.16.10.tar.gz"

# 1.8 state empty
reset_state
out="$(b state)"
case_start 14 "state (empty) -> 'No completed steps recorded'"
assert_contains "No completed steps recorded" "$out" "1.8"

# 1.9 state populated
mkdir -p "$TEST_ROOT/.build-state"
echo "k1" > "$TEST_ROOT/.build-state/uboot.done"
echo "k2" > "$TEST_ROOT/.build-state/atf.done"
out="$(b state)"
case_start 15 "state lists uboot"
assert_contains "uboot" "$out" "1.9a"
case_start 16 "state lists atf"
assert_contains "atf" "$out" "1.9b"

# 1.10 clean-state
b clean-state >/dev/null 2>&1
out="$(b state)"
case_start 17 "clean-state then state -> empty"
assert_contains "No completed steps recorded" "$out" "1.10"

# 1.11 extra args ignored
out="$(b state -j 8)"; rc=$?
case_start 18 "state -j 8 (extra args ignored)"
[ "$rc" -eq 0 ] && pass || fail "exit was $rc" "1.11"

# 1.12 --no-log creates no log file
reset_state
b sources --no-log >/dev/null 2>&1
case_start 19 "--no-log: no logs/ created"
[ ! -d "$TEST_ROOT/logs" ] && pass || fail "logs/ exists" "1.12a"

# 1.12b without --no-log a log gets created
reset_state
HI3403_NO_LOG=0 "$TEST_ROOT/build.sh" sources >/dev/null 2>&1 || true
case_start 20 "logging produces logs/latest.log"
assert_file "$TEST_ROOT/logs/latest.log" "1.12b"


#=============================================================================
banner "Phase 2 — per-function tests via mock docker"
#=============================================================================

assert_marker() {
    [ -f "$TEST_ROOT/.build-state/$1.done" ] && pass || \
        fail "no marker .build-state/$1.done" "$2"
}

# 2.1 uboot
reset_state
b uboot >/dev/null 2>&1
case_start 21 "uboot first run produces u-boot.bin"
assert_file "$TEST_ROOT/output/boot/u-boot.bin" "2.1a"
case_start 22 "uboot first run records marker"
assert_marker uboot "2.1b"
case_start 23 "uboot first run invokes docker"
n="$(docker_run_count)"
[ "$n" -ge 1 ] && pass || fail "no docker run logged ($n)" "2.1c"

: > "$MOCK_DOCKER_LOG"
out="$(b uboot)"
case_start 24 "uboot rerun -> skip line"
assert_contains "uboot] already built" "$out" "2.1d"
case_start 25 "uboot rerun -> no docker call"
n="$(docker_run_count)"
[ "$n" -eq 0 ] && pass || fail "docker invoked $n times" "2.1e"

: > "$MOCK_DOCKER_LOG"
b uboot --force >/dev/null 2>&1
case_start 26 "uboot --force -> docker invoked"
n="$(docker_run_count)"
[ "$n" -ge 1 ] && pass || fail "no docker run with --force ($n)" "2.1f"

: > "$MOCK_DOCKER_LOG"
b uboot BOOT_MEDIA=spi >/dev/null 2>&1
case_start 27 "uboot BOOT_MEDIA=spi -> docker invoked (key changed)"
n="$(docker_run_count)"
[ "$n" -ge 1 ] && pass || fail "param change did not re-run ($n)" "2.1g"

# 2.2 atf
reset_state
b atf >/dev/null 2>&1
case_start 28 "atf first run produces bl31.bin"
assert_file "$TEST_ROOT/output/boot/bl31.bin" "2.2a"
: > "$MOCK_DOCKER_LOG"
out="$(b atf)"
case_start 29 "atf rerun -> skip"
assert_contains "atf] already built" "$out" "2.2b"
case_start 30 "atf rerun -> no docker call"
n="$(docker_run_count)"
[ "$n" -eq 0 ] && pass || fail "docker called $n times" "2.2c"

# 2.3 kernel-image
reset_state
b kernel-image >/dev/null 2>&1
case_start 31 "kernel-image -> Image.gz"
assert_file "$TEST_ROOT/output/boot/Image.gz" "2.3a"
case_start 32 "kernel-image marker recorded"
assert_marker kernel_image "2.3b"

# 2.4 dtb
reset_state
b dtb >/dev/null 2>&1
n="$(ls "$TEST_ROOT/output/boot/"*.dtb 2>/dev/null | wc -l | tr -d ' ')"
case_start 33 "dtb -> 2 .dtb files"
[ "$n" = "2" ] && pass || fail "got $n .dtb files" "2.4a"
case_start 34 "dtbs marker recorded"
assert_marker dtbs "2.4b"

# 2.5 kernel (combined)
reset_state
b kernel >/dev/null 2>&1
case_start 35 "kernel -> Image.gz + .dtb"
[ -f "$TEST_ROOT/output/boot/Image.gz" ] && \
    [ -f "$TEST_ROOT/output/boot/ss928v100-demb-emmc.dtb" ] && pass || \
    fail "missing files" "2.5a"
case_start 36 "kernel records both kernel_image + dtbs markers"
[ -f "$TEST_ROOT/.build-state/kernel_image.done" ] && \
    [ -f "$TEST_ROOT/.build-state/dtbs.done" ] && pass || \
    fail "missing one marker" "2.5b"

# 2.6 mpp
reset_state
b mpp >/dev/null 2>&1
ko_n="$(ls "$TEST_ROOT/output/mpp/ko/"*.ko 2>/dev/null | wc -l | tr -d ' ')"
lib_n="$(ls "$TEST_ROOT/output/mpp/lib/" 2>/dev/null | wc -l | tr -d ' ')"
case_start 37 "mpp -> 8 .ko modules"
[ "$ko_n" = "8" ] && pass || fail "got $ko_n .ko" "2.6a"
case_start 38 "mpp -> some libs"
[ "$lib_n" -ge 1 ] && pass || fail "got $lib_n libs" "2.6b"
case_start 39 "mpp marker recorded"
assert_marker mpp "2.6c"

# 2.7 boot combo
reset_state
b boot >/dev/null 2>&1
case_start 40 "boot -> u-boot.bin + bl31.bin + Image.gz"
[ -f "$TEST_ROOT/output/boot/u-boot.bin" ] && \
    [ -f "$TEST_ROOT/output/boot/bl31.bin" ] && \
    [ -f "$TEST_ROOT/output/boot/Image.gz" ] && pass || fail "missing one of 3" "2.7"

# 2.8 package
reset_state
b package >/dev/null 2>&1
case_start 41 "package -> .img file (atomic .partial -> .img)"
ls "$TEST_ROOT/output/"*.img >/dev/null 2>&1 && pass || fail "no .img produced" "2.8a"
case_start 42 "package -> no leftover .partial"
[ -z "$(ls "$TEST_ROOT/output/"*.partial 2>/dev/null)" ] && pass || fail ".partial leftover" "2.8b"


#=============================================================================
banner "Phase 3 — sequencing"
#=============================================================================

# 3.1 Forward: uboot -> atf -> kernel -> mpp
reset_state
b uboot   >/dev/null 2>&1
b atf     >/dev/null 2>&1
b kernel  >/dev/null 2>&1
b mpp     >/dev/null 2>&1
case_start 43 "forward sequence: 4 markers"
[ -f "$TEST_ROOT/.build-state/uboot.done" ] && \
    [ -f "$TEST_ROOT/.build-state/atf.done" ] && \
    [ -f "$TEST_ROOT/.build-state/kernel_image.done" ] && \
    [ -f "$TEST_ROOT/.build-state/mpp.done" ] && pass || fail "missing markers" "3.1"

# 3.2 Reverse: mpp -> kernel -> atf -> uboot
reset_state
b mpp     >/dev/null 2>&1
b kernel  >/dev/null 2>&1
b atf     >/dev/null 2>&1
b uboot   >/dev/null 2>&1
case_start 44 "reverse sequence: artifacts intact"
[ -f "$TEST_ROOT/output/mpp/ko/sys_ssp.ko" ] && \
    [ -f "$TEST_ROOT/output/boot/Image.gz" ] && \
    [ -f "$TEST_ROOT/output/boot/bl31.bin" ] && \
    [ -f "$TEST_ROOT/output/boot/u-boot.bin" ] && pass || fail "missing artifact" "3.2"

# 3.3 Random interleave
reset_state
b kernel-image >/dev/null 2>&1
b uboot        >/dev/null 2>&1
b dtb          >/dev/null 2>&1
b atf          >/dev/null 2>&1
b mpp          >/dev/null 2>&1
case_start 45 "interleaved sequence: every output present"
[ -f "$TEST_ROOT/output/boot/Image.gz" ] && \
    [ -f "$TEST_ROOT/output/boot/u-boot.bin" ] && \
    [ -f "$TEST_ROOT/output/boot/ss928v100-demb-emmc.dtb" ] && \
    [ -f "$TEST_ROOT/output/boot/bl31.bin" ] && \
    [ -f "$TEST_ROOT/output/mpp/ko/sys_ssp.ko" ] && pass || fail "missing artifact" "3.3"

# 3.4 boot twice — second invokes docker zero times
reset_state
b boot >/dev/null 2>&1
: > "$MOCK_DOCKER_LOG"
b boot >/dev/null 2>&1
case_start 46 "boot rerun -> all 3 skip (zero docker run calls)"
n="$(docker_run_count)"
[ "$n" -eq 0 ] && pass || fail "expected 0 docker run, got $n" "3.4"

# 3.5 individual then boot — only missing parts re-run
reset_state
b uboot >/dev/null 2>&1
: > "$MOCK_DOCKER_LOG"
b boot >/dev/null 2>&1
n="$(docker_run_count)"
case_start 47 "uboot then boot: docker invoked for atf+kernel+dtb (3)"
[ "$n" -eq 3 ] && pass || fail "expected 3 docker run, got $n" "3.5"

# 3.6 BOOT_MEDIA mid-flight
reset_state
b uboot   >/dev/null 2>&1
b kernel  >/dev/null 2>&1
b atf     >/dev/null 2>&1
b mpp     >/dev/null 2>&1
: > "$MOCK_DOCKER_LOG"
b uboot   BOOT_MEDIA=spi >/dev/null 2>&1
b kernel  BOOT_MEDIA=spi >/dev/null 2>&1
b atf     BOOT_MEDIA=spi >/dev/null 2>&1
b mpp     BOOT_MEDIA=spi >/dev/null 2>&1
n="$(docker_run_count)"
case_start 48 "BOOT_MEDIA change re-runs uboot+kernel(+dtb), skips atf+mpp"
[ "$n" -eq 3 ] && pass || fail "expected 3 docker run, got $n" "3.6"

# 3.7 verify between build steps
reset_state
b uboot  >/dev/null 2>&1
b verify >/dev/null 2>&1
b atf    >/dev/null 2>&1
case_start 49 "verify between steps: both markers present"
[ -f "$TEST_ROOT/.build-state/uboot.done" ] && \
    [ -f "$TEST_ROOT/.build-state/atf.done" ] && pass || \
    fail "missing markers" "3.7"

# 3.8 clean-state mid-flight forces re-run
reset_state
b uboot >/dev/null 2>&1
b clean-state >/dev/null 2>&1
: > "$MOCK_DOCKER_LOG"
b uboot >/dev/null 2>&1
n="$(docker_run_count)"
case_start 50 "clean-state forces uboot re-run"
[ "$n" -ge 1 ] && pass || fail "no docker call after clean-state ($n)" "3.8"


#=============================================================================
banner "Phase 4 — edge cases"
#=============================================================================

# 4.1 --no-log respected on a build cmd
reset_state
b uboot --no-log >/dev/null 2>&1
case_start 51 "--no-log respected on build cmd (no logs/ dir)"
[ ! -d "$TEST_ROOT/logs" ] && pass || fail "logs/ created despite --no-log" "4.1"

# 4.2 marker present but artifact missing -> rebuild
reset_state
b uboot >/dev/null 2>&1
rm -f "$TEST_ROOT/output/boot/u-boot.bin"
: > "$MOCK_DOCKER_LOG"
b uboot >/dev/null 2>&1
n="$(docker_run_count)"
case_start 52 "marker present but artifact missing -> rebuild"
[ "$n" -ge 1 ] && pass || fail "did not rebuild missing artifact ($n)" "4.2"

# 4.3 clean removes state markers + artifacts
reset_state
b uboot >/dev/null 2>&1
b clean </dev/null >/dev/null 2>&1
case_start 53 "clean removes u-boot.bin"
[ ! -f "$TEST_ROOT/output/boot/u-boot.bin" ] && pass || \
    fail "u-boot.bin still present" "4.3a"
case_start 54 "clean removes step markers"
[ ! -f "$TEST_ROOT/.build-state/uboot.done" ] && pass || \
    fail "marker still present" "4.3b"

# 4.4 multiple --force passes
reset_state
b uboot >/dev/null 2>&1            # 1
b uboot --force >/dev/null 2>&1    # +1
b uboot --force >/dev/null 2>&1    # +1
case_start 55 "3x uboot (1 normal + 2 force) -> 3 docker run calls"
n="$(docker_run_count)"
[ "$n" -eq 3 ] && pass || fail "got $n runs (expected 3)" "4.4"

# 4.5 unknown command + state still works
reset_state
b badcmd >/dev/null 2>&1
out="$(b state)"
case_start 56 "state still works after unknown command"
assert_contains "No completed steps" "$out" "4.5"

# 4.6 ROOTFS_TYPE/CHIP arg parsing — package uses the name
reset_state
b package ROOTFS_TYPE=lite CHIP=ss927v100 >/dev/null 2>&1
case_start 57 "package honors ROOTFS_TYPE+CHIP in img name"
ls "$TEST_ROOT/output/hi3403-ubuntu-lite-ss927v100.img" >/dev/null 2>&1 && pass || \
    fail "expected hi3403-ubuntu-lite-ss927v100.img" "4.6"

# 4.7 Help works after a successful build
b uboot >/dev/null 2>&1
out="$(b --help)"
case_start 58 "--help still works after a successful build"
assert_contains "Usage: ./build.sh" "$out" "4.7"

# 4.8 setup_sources skip path
reset_state
b sources >/dev/null 2>&1   # first run: verifies all
out="$(b sources)"
case_start 59 "sources rerun -> setup_sources skip line"
assert_contains "setup_sources] up to date" "$out" "4.8"

# 4.9 setup_sources --force re-runs
: > "$MOCK_DOCKER_LOG"
out="$(b sources --force)"
case_start 60 "sources --force re-runs setup_sources"
assert_contains "setup_sources] starting" "$out" "4.9"

# 4.10 extract_and_patch (via setup) is wrapped — second call skips
reset_state
b setup >/dev/null 2>&1
out="$(b setup)"
case_start 61 "setup rerun -> extract_and_patch skip line"
assert_contains "extract_and_patch" "$out" "4.10a"
# The skip path emits "...sources already extracted at this pegasus rev"
case_start 62 "setup rerun -> extract_and_patch shows skip mark"
if printf '%s' "$out" | grep -E 'extract_and_patch.*already extracted|sources already extracted' >/dev/null; then
    pass
else
    fail "no skip line for extract_and_patch" "4.10b"
fi


#=============================================================================
banner "Summary"
#=============================================================================

TOTAL=$((PASS + FAIL))
printf "  Total: ${BOLD}%d${NC}\n" "$TOTAL"
printf "  Pass:  ${GREEN}%d${NC}\n" "$PASS"
printf "  Fail:  ${RED}%d${NC}\n" "$FAIL"
printf "  Test root: %s\n" "$TEST_ROOT"

if [ $FAIL -gt 0 ]; then
    printf "\n${RED}Failures:${NC}\n"
    for f in "${FAILS[@]}"; do printf "  - %s\n" "$f"; done
fi

# Optional cleanup of the tmpdir (best-effort).
if [ "${KEEP_TEST_ROOT:-0}" = "0" ]; then
    rm -rf "$TEST_ROOT" 2>/dev/null || true
fi

[ $FAIL -eq 0 ]
