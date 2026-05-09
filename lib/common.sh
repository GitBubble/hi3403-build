#!/bin/bash
#=============================================================================
# Common helpers for build.sh
#   - Colorized logging w/ timestamps + tee to logs/build-<ts>.log
#   - Per-step state markers under .build-state/  (skip on rerun)
#   - SHA-256 + size verification of downloads against lib/checksums.txt
#   - Atomic output staging
# Sourced by build.sh — do not run directly.
#=============================================================================

# Guard against double-sourcing.
if [ "${HI3403_COMMON_SH_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
HI3403_COMMON_SH_LOADED=1

# === Paths ===========================================================
# SCRIPT_DIR must be set by the caller before sourcing this file.
: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing lib/common.sh}"

LIB_DIR="$SCRIPT_DIR/lib"
LOG_DIR="$SCRIPT_DIR/logs"
STATE_DIR="$SCRIPT_DIR/.build-state"
CHECKSUM_FILE="$LIB_DIR/checksums.txt"

# State dir is needed for marker reads even on read-only commands; logs
# dir is created lazily in init_logfile() so --no-log doesn't leave an
# empty logs/ behind.
mkdir -p "$STATE_DIR"

# === Colors ==========================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'
DONE_MARK="${GREEN}\xe2\x9c\x93${NC}"
FAIL_MARK="${RED}\xe2\x9c\x97${NC}"
SKIP_MARK="${GRAY}\xe2\x88\x98${NC}"
INFO_MARK="${CYAN}\xe2\x86\x92${NC}"

# === Logging ==========================================================
# Initializes a tee'd log file. Call once near the top of main().
# Honors $HI3403_NO_LOG=1 to disable.
init_logfile() {
    [ "${HI3403_NO_LOG:-0}" = "1" ] && return 0
    mkdir -p "$LOG_DIR"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="$LOG_DIR/build-$ts.log"
    # Symlink "latest" for convenience (best-effort).
    ln -snf "build-$ts.log" "$LOG_DIR/latest.log" 2>/dev/null || true
    # Redirect stdout & stderr through tee.
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Build log: $LOG_FILE"
}

log()  { printf "${BLUE}[%s]${NC} %b\n" "$(date +%H:%M:%S)" "$1"; }
ok()   { printf "  ${DONE_MARK} %b\n" "$1"; }
warn() { printf "  ${YELLOW}\xe2\x9a\xa0${NC} %b\n" "$1"; }
err()  { printf "  ${FAIL_MARK} %b\n" "$1"; }
info() { printf "  ${INFO_MARK} %b\n" "$1"; }
skip() { printf "  ${SKIP_MARK} %b\n" "$1"; }

# === State tracking ==================================================
# Each step is keyed by name; a marker file under .build-state/ records
# completion + a content hash of the inputs so that a meaningful change
# invalidates the marker.
#
# Usage:
#   step_begin "uboot" "$key"      # $key = "" if you don't care about inputs
#   ... do work ...
#   step_end   "uboot" "$key"
#
# To force a rerun: --force on the CLI sets HI3403_FORCE=1 (handled by build.sh).

state_marker() { printf '%s/%s.done' "$STATE_DIR" "$1"; }

step_should_skip() {
    local name="$1" key="${2:-}"
    [ "${HI3403_FORCE:-0}" = "1" ] && return 1
    local marker; marker="$(state_marker "$name")"
    [ -f "$marker" ] || return 1
    # Compare stored key with current key. Empty key = always-rerun-disabled.
    local stored; stored="$(cat "$marker" 2>/dev/null || true)"
    [ "$stored" = "$key" ]
}

step_begin() {
    local name="$1"
    SECONDS_AT_STEP_START=$SECONDS
    log "[$name] starting"
}

step_end() {
    local name="$1" key="${2:-}"
    local marker; marker="$(state_marker "$name")"
    printf '%s' "$key" > "$marker"
    local elapsed=$(( SECONDS - SECONDS_AT_STEP_START ))
    ok "[$name] done in ${elapsed}s"
}

step_clear() {
    local name="$1"
    rm -f "$(state_marker "$name")"
}

state_list() {
    if [ ! -d "$STATE_DIR" ] || [ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
        info "No completed steps recorded."
        return 0
    fi
    log "Completed steps (under $STATE_DIR):"
    for f in "$STATE_DIR"/*.done; do
        [ -f "$f" ] || continue
        local name; name="$(basename "$f" .done)"
        local mtime; mtime="$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+unknown')"
        printf '  %s  %s\n' "$mtime" "$name"
    done
}

state_clear_all() {
    local count=0 fail=0
    if compgen -G "$STATE_DIR/*.done" >/dev/null; then
        for f in "$STATE_DIR"/*.done; do
            if rm -f "$f" 2>/dev/null && [ ! -e "$f" ]; then
                count=$((count + 1))
            else
                fail=$((fail + 1))
                err "Could not remove $f"
            fi
        done
    fi
    if [ $fail -gt 0 ]; then
        err "Cleared $count, failed $fail."
        return 1
    fi
    ok "Cleared $count step marker(s)."
}

# === Checksum verification ===========================================
# Verifies a single file against lib/checksums.txt. Returns 0 if ok,
# 1 if mismatched or missing.
verify_file() {
    local file="$1"
    local base; base="$(basename "$file")"
    local line
    line="$(awk -v f="$base" 'NF >= 4 && $1 !~ /^#/ && $2 == f { print; exit }' "$CHECKSUM_FILE" 2>/dev/null || true)"
    if [ -z "$line" ]; then
        warn "No checksum entry for $base — skipping verification"
        return 0
    fi
    local expected_sha expected_min_size actual_sha actual_size
    expected_sha="$(echo "$line"   | awk '{print $1}')"
    expected_min_size="$(echo "$line" | awk '{print $3}')"
    if [ ! -f "$file" ]; then
        err "Missing: $file"
        return 1
    fi
    # -L dereferences symlinks; the size we want is the target's, not the link's.
    actual_size="$(stat -L -c %s "$file" 2>/dev/null || stat -L -f %z "$file" 2>/dev/null || echo 0)"
    if [ "$actual_size" -lt "$expected_min_size" ]; then
        err "$base: size $actual_size < min $expected_min_size (likely 404 / partial download)"
        return 1
    fi
    actual_sha="$(_sha256 "$file")"
    if [ "$actual_sha" != "$expected_sha" ]; then
        err "$base: SHA-256 mismatch"
        err "  expected: $expected_sha"
        err "  actual:   $actual_sha"
        return 1
    fi
    return 0
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        err "Need sha256sum or shasum to verify downloads"
        return 1
    fi
}

# Download with curl, verify, retry up to 2 times. On final failure,
# delete the bad file so the next run can try fresh.
fetch_and_verify() {
    local file="$1" url="$2" attempts=0 max=2
    local dest="$DOWNLOADS_DIR/$file"
    while [ $attempts -lt $max ]; do
        if [ -f "$dest" ] && verify_file "$dest" >/dev/null 2>&1; then
            ok "verified: $file"
            return 0
        fi
        if [ -f "$dest" ]; then
            warn "$file fails verification — redownloading"
            rm -f "$dest"
        fi
        info "downloading $file"
        if ! curl -fL --retry 5 --connect-timeout 30 -o "$dest" "$url"; then
            err "curl failed for $url"
        fi
        attempts=$((attempts + 1))
        if verify_file "$dest"; then
            ok "verified: $file"
            return 0
        fi
        warn "verification failed (attempt $attempts/$max)"
        rm -f "$dest"
    done
    err "Failed to obtain valid $file after $max attempts"
    return 1
}

# Verify every entry in checksums.txt that exists on disk. Used by the
# "verify" command and as a pre-flight check before extract_and_patch.
verify_all_downloads() {
    local fail=0 total=0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        local f; f="$(echo "$line" | awk '{print $2}')"
        local p="$DOWNLOADS_DIR/$f"
        total=$((total + 1))
        if [ ! -f "$p" ]; then
            warn "missing: $f"
            fail=$((fail + 1))
            continue
        fi
        if verify_file "$p"; then
            ok "$f"
        else
            fail=$((fail + 1))
        fi
    done < "$CHECKSUM_FILE"
    if [ $fail -gt 0 ]; then
        err "$fail/$total downloads failed verification"
        return 1
    fi
    ok "All $total downloads verified"
    return 0
}

# === Atomic output staging ============================================
# Writes go through a per-step staging dir, then mv'd to the final path
# in one shot once the step succeeds. Use:
#   stage="$(stage_for kernel)"  # populates stage with files
#   commit_stage kernel "$OUTPUT_DIR/boot"
stage_for() {
    local name="$1"
    local d="$OUTPUT_DIR/.staging/$name"
    rm -rf "$d"
    mkdir -p "$d"
    printf '%s' "$d"
}

commit_stage() {
    local name="$1" target="$2"
    local src="$OUTPUT_DIR/.staging/$name"
    [ -d "$src" ] || { err "no stage for $name"; return 1; }
    mkdir -p "$target"
    # Move every produced file individually (overwrite destination).
    if compgen -G "$src/*" >/dev/null; then
        cp -af "$src"/. "$target"/
    fi
    rm -rf "$src"
}
