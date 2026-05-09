#!/bin/bash
# Mock docker for sandbox testing of build.sh.
#
# Recognizes the three docker invocations build.sh issues:
#   docker images <name> --format ...   -> echo "." (image exists)
#   docker build -t <name> <path>       -> exit 0
#   docker run [...flags...] <img> bash -c "<script>"
#                                        -> inspect <script>, fabricate the
#                                           per-step staging outputs, then exit 0
#
# Records every call to $MOCK_DOCKER_LOG so tests can assert that a step
# either invoked docker or skipped.
#
# Required env: MOCK_DOCKER_LOG, OUTPUT_DIR.

set -e

: "${MOCK_DOCKER_LOG:?MOCK_DOCKER_LOG must be set}"
: "${OUTPUT_DIR:?OUTPUT_DIR must be set}"

verb="${1:-}"
shift || true

# --- record the call -------------------------------------------------
{
    echo "=== docker $verb ==="
    printf '%s\n' "$@"
    echo
} >> "$MOCK_DOCKER_LOG"

case "$verb" in
    images)
        # build.sh: `docker images "$DOCKER_IMAGE" --format '.' 2>/dev/null | grep -q .`
        # Echo a single "." so grep -q succeeds — pretend image exists.
        echo .
        exit 0
        ;;

    build)
        # build.sh: `docker build -t "$DOCKER_IMAGE" "$(dirname "$DOCKERFILE")"`
        exit 0
        ;;

    run)
        # The trailing args of `docker run` end with: <image> bash -c <script>.
        # We grab the last arg as the script.
        script=""
        for a in "$@"; do script="$a"; done

        # Fabricate per-step outputs based on staging dir mentioned in script.
        # Each block matches one of the docker_run "..." sections in build.sh.

        if echo "$script" | grep -q '/workspace/output/.staging/kernel_image'; then
            mkdir -p "$OUTPUT_DIR/.staging/kernel_image"
            printf 'FAKE_KERNEL\n' > "$OUTPUT_DIR/.staging/kernel_image/Image.gz"
        fi

        if echo "$script" | grep -q '/workspace/output/.staging/dtbs'; then
            mkdir -p "$OUTPUT_DIR/.staging/dtbs"
            : > "$OUTPUT_DIR/.staging/dtbs/ss928v100-demb-emmc.dtb"
            : > "$OUTPUT_DIR/.staging/dtbs/ss928v100-demb-flash.dtb"
        fi

        if echo "$script" | grep -q '/workspace/output/.staging/uboot'; then
            mkdir -p "$OUTPUT_DIR/.staging/uboot"
            printf 'FAKE_UBOOT\n' > "$OUTPUT_DIR/.staging/uboot/u-boot.bin"
        fi

        if echo "$script" | grep -q '/workspace/output/.staging/atf'; then
            mkdir -p "$OUTPUT_DIR/.staging/atf"
            printf 'FAKE_BL31\n' > "$OUTPUT_DIR/.staging/atf/bl31.bin"
        fi

        if echo "$script" | grep -q '/workspace/output/.staging/mpp_ko'; then
            mkdir -p "$OUTPUT_DIR/.staging/mpp_ko" "$OUTPUT_DIR/.staging/mpp_lib"
            for m in sys_ssp sys_config sys_link mm_proc base_proc \
                     drv_pcie drv_eth drv_uart; do
                : > "$OUTPUT_DIR/.staging/mpp_ko/${m}.ko"
            done
            : > "$OUTPUT_DIR/.staging/mpp_ko/load_ss928v100_ubuntu"
            for l in libsys.so libmpi.so libvenc.so libvdec.so libvi.so \
                     libvo.so libaio.so libisp.so; do
                : > "$OUTPUT_DIR/.staging/mpp_lib/$l"
            done
        fi

        # extract_and_patch — no staging output; just succeed.
        if echo "$script" | grep -q "Patches applied"; then
            :
        fi

        # package_image: writes <img>.partial then renames atomically. Fake it.
        partial=$(echo "$script" | grep -oE '/workspace/output/[^ ]+\.partial' | head -1 || true)
        if [ -n "$partial" ]; then
            host_partial="$OUTPUT_DIR/${partial##*/output/}"
            host_final="${host_partial%.partial}"
            # Tiny "image" so test artifacts stay small.
            dd if=/dev/zero of="$host_partial" bs=1 count=1024 status=none 2>/dev/null || \
                printf '%0.s\0' {1..1024} > "$host_partial"
            mv "$host_partial" "$host_final"
        fi

        # rootfs/integrate steps run inside container only — succeed silently.
        exit 0
        ;;

    *)
        # Unknown verb (e.g. interactive `docker run -it`) — succeed.
        exit 0
        ;;
esac
