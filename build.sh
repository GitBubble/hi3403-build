#!/bin/bash
#=============================================================================
# Hi3403V100 Ubuntu Image Build Script
# Usage: ./build.sh <command> [options]
#
# Commands:
#   ubuntu_lite       - Build Ubuntu 22.04 lite (no desktop) rootfs
#   ubuntu_xfce       - Build Ubuntu 22.04 XFCE desktop rootfs
#   ubuntu_lite_all   - Full build: uboot + kernel + atf + mpp + ubuntu_lite
#   ubuntu_xfce_all   - Full build: uboot + kernel + atf + mpp + ubuntu_xfce
#   all               - Full build (same as ubuntu_xfce_all)
#
#   boot              - Build all boot components (uboot + atf + kernel + dtbs)
#   uboot             - Build U-Boot only
#   atf               - Build ARM Trusted Firmware only
#   kernel            - Build Linux kernel Image + DTBs
#   kernel-image      - Build Linux kernel Image only (no DTBs)
#   dtb|dtbs          - Build device tree blobs only
#   mpp               - Build MPP kernel modules only
#
#   rootfs            - Build rootfs only (default: xfce)
#   integrate         - Integrate MPP into existing rootfs
#   package           - Package rootfs into ext4 image
#   clean             - Clean all build artifacts
#   shell             - Enter Docker build shell
#
#   verify            - Verify SHA-256 of all source tarballs
#   state             - Show which build steps have been completed
#   clean-state       - Clear all step-completion markers (no file deletion)
#
# Options:
#   -j N              - Parallel jobs (default: nproc)
#   --force           - Re-run steps even if they're marked completed
#   --no-log          - Don't tee output to logs/build-<ts>.log
#   --dry-run         - Show commands without executing
#=============================================================================

set -e

# === Configuration ====================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_IMAGE="hi3403-builder:latest"
DOCKERFILE="$SCRIPT_DIR/docker/Dockerfile"
PEGASUS_DIR="$SCRIPT_DIR/pegasus"
DOWNLOADS_DIR="$SCRIPT_DIR/downloads"
OUTPUT_DIR="$SCRIPT_DIR/output"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

# Shared helpers: logging, state tracking, checksum verification.
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Build settings
BOOT_MEDIA="${BOOT_MEDIA:-emmc}"
CHIP="${CHIP:-ss928v100}"
LLVM="${LLVM:-0}"
OSDRV_CROSS="${OSDRV_CROSS:-aarch64-linux-gnu}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
ROOTFS_TYPE="${ROOTFS_TYPE:-xfce}"

usage() {
    # Lines 3..(next #=== line); strip leading "# "; drop the closing #=== line.
    sed -n '3,/^#==*$/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'
    echo ""
    echo "Examples:"
    echo "  ./build.sh ubuntu_xfce_all          # Full build with XFCE desktop"
    echo "  ./build.sh ubuntu_lite_all          # Full build, no desktop"
    echo "  ./build.sh kernel                   # Build kernel only"
    echo "  ./build.sh rootfs ROOTFS_TYPE=lite  # Lite rootfs only"
    echo "  ./build.sh all -j 4                 # Full build with 4 jobs"
    echo "  ./build.sh kernel --force           # Re-run a completed step"
    echo "  ./build.sh verify                   # Verify pinned tarball checksums"
    exit 0
}

require_file() { [ -f "$1" ] && return 0; err "Missing: $1"; exit 1; }
require_dir()  { [ -d "$1" ] && return 0; err "Missing: $1"; exit 1; }

# === Docker ===========================================================
docker_build() {
    if docker images "$DOCKER_IMAGE" --format '.' 2>/dev/null | grep -q .; then
        ok "Docker image exists: $DOCKER_IMAGE"
    else
        log "Building Docker image..."
        require_file "$DOCKERFILE"
        docker build -t "$DOCKER_IMAGE" "$(dirname "$DOCKERFILE")"
        ok "Docker image built"
    fi
}

docker_run() {
    docker run --rm \
        -v "$PEGASUS_DIR":/workspace/pegasus \
        -v "$DOWNLOADS_DIR":/workspace/downloads \
        -v "$OUTPUT_DIR":/workspace/output \
        -v "$SCRIPTS_DIR":/workspace/scripts \
        -e JOBS="$JOBS" \
        "$DOCKER_IMAGE" bash -c "$*"
}

# === Source Setup =====================================================
# Step key embeds the Pegasus HEAD + checksums.txt content so a vendor
# bump or pinned-version change re-runs setup automatically.
setup_sources_key() {
    local pegasus_head="none"
    [ -d "$PEGASUS_DIR/.git" ] && pegasus_head="$(git -C "$PEGASUS_DIR" rev-parse HEAD 2>/dev/null || echo none)"
    local cks_hash; cks_hash="$(_sha256 "$CHECKSUM_FILE" 2>/dev/null || echo nosum)"
    printf 'pegasus=%s checksums=%s' "$pegasus_head" "$cks_hash"
}

setup_sources() {
    local key; key="$(setup_sources_key)"
    if step_should_skip "setup_sources" "$key"; then
        skip "[setup_sources] up to date — pegasus + downloads already verified"
        return 0
    fi
    step_begin "setup_sources"
    mkdir -p "$DOWNLOADS_DIR"

    # Pegasus repo
    if [ ! -d "$PEGASUS_DIR/.git" ]; then
        info "Cloning pegasus..."
        git clone https://gitee.com/HiSpark/pegasus.git "$PEGASUS_DIR"
        ( cd "$PEGASUS_DIR" && git submodule init && git submodule update platform/ss928v100_gcc )
    else
        ok "Pegasus repo exists"
    fi

    # Verify or fetch every entry in lib/checksums.txt.
    info "Verifying source tarballs against $CHECKSUM_FILE"
    local f url min_size
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        # Fields: sha256  filename  min_size  url
        f="$(echo "$line"        | awk '{print $2}')"
        min_size="$(echo "$line" | awk '{print $3}')"
        url="$(echo "$line"      | awk '{print $4}')"
        : "$min_size"  # shellcheck: keep declared
        fetch_and_verify "$f" "$url"
    done < "$CHECKSUM_FILE"

    SDK="$PEGASUS_DIR/platform/ss928v100_gcc"
    OS="$SDK/open_source"

    step_end "setup_sources" "$key"
}

# === Extract & Patch ==================================================
extract_and_patch() {
    SDK="$PEGASUS_DIR/platform/ss928v100_gcc"
    OS="$SDK/open_source"
    PATCHES="$PEGASUS_DIR/vendor/topeet/patch"

    local key="pegasus=$(git -C "$PEGASUS_DIR" rev-parse HEAD 2>/dev/null || echo none)"
    if step_should_skip "extract_and_patch" "$key"; then
        skip "[extract_and_patch] sources already extracted at this pegasus rev"
        return 0
    fi
    step_begin "extract_and_patch"

    docker_run "
        SDK=/workspace/pegasus/platform/ss928v100_gcc
        OS=\$SDK/open_source
        PATCHES=/workspace/pegasus/vendor/topeet/patch

        # Extract tarballs (if not already done)
        for d in linux mbedtls trusted-firmware-a u-boot; do
            if [ ! -f \$OS/\$d/Makefile ] && [ ! -f \$OS/\$d/Kconfig ]; then
                echo 'Extracting' \$d '...'
                case \$d in
                    linux)   tar -xf /workspace/downloads/linux-6.6.86.tar.xz -C \$OS/linux --strip-components=1 ;;
                    mbedtls) tar -xf /workspace/downloads/mbedtls-2.16.10.tar.gz -C \$OS/mbedtls --strip-components=1 ;;
                    trusted-firmware-a) tar -xf /workspace/downloads/v2.2.tar.gz -C \$OS/trusted-firmware-a --strip-components=1 ;;
                    u-boot)  tar -xzf /workspace/downloads/u-boot-2020.01.tar.gz -C \$OS/u-boot --strip-components=1 ;;
                esac
            fi
        done

        # Kernel symlink for MPP build
        ln -sf . \$OS/linux/linux-6.6.y 2>/dev/null || true

        # Apply HiSilicon BSP patches
        [ -f \$OS/linux/linux-6.6.86.patch ] && cd \$OS/linux && patch -p1 -s < linux-6.6.86.patch || true
        [ -f \$OS/u-boot/u-boot-2020.01.patch ] && cd \$OS/u-boot && patch -p1 -s < u-boot-2020.01.patch || true
        [ -f \$OS/trusted-firmware-a/trusted-firmware-a-2.2.patch ] && cd \$OS/trusted-firmware-a && patch -p1 -s < trusted-firmware-a-2.2.patch || true
        [ -f \$OS/mbedtls/vendor_mbedtls-2.16.10.patch ] && cd \$OS/mbedtls && patch -p1 -s < vendor_mbedtls-2.16.10.patch || true

        # Apply Topeet vendor patches
        cd \$OS/linux && patch -p1 -s < \$PATCHES/SDK/topeet_ss928v100_linux6.6.86.patch || true
        cd \$OS/u-boot && patch -p1 -s < \$PATCHES/SDK/topeet_ss928v100_uboot.patch || true
        cd \$SDK && patch -p1 -s < \$PATCHES/SDK/topeet_ss928v100.patch || true
        cd \$SDK/smp && patch -p1 -s < \$PATCHES/MPP/topeet_mpp.patch || true

        echo 'Patches applied'
    "
    step_end "extract_and_patch" "$key"
}

# === Build Targets ====================================================
# All build steps share a key prefix that captures pegasus rev + relevant
# build params; if anything in the key changes we re-run the step.
_pegasus_rev() { git -C "$PEGASUS_DIR" rev-parse HEAD 2>/dev/null || echo none; }

build_kernel_image() {
    local key="rev=$(_pegasus_rev) chip=$CHIP boot=$BOOT_MEDIA"
    if step_should_skip "kernel_image" "$key" && [ -f "$OUTPUT_DIR/boot/Image.gz" ]; then
        skip "[kernel_image] already built (Image.gz present)"
        return 0
    fi
    step_begin "kernel_image"
    stage_for kernel_image >/dev/null
    docker_run "
        cd /workspace/pegasus/platform/ss928v100_gcc/open_source/linux
        export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
        [ ! -f .config ] && make ss928v100_emmc_ubuntu_defconfig
        make -j\$JOBS Image.gz modules_prepare
        cp arch/arm64/boot/Image.gz /workspace/output/.staging/kernel_image/
    "
    commit_stage kernel_image "$OUTPUT_DIR/boot"
    require_file "$OUTPUT_DIR/boot/Image.gz"
    ok "Image.gz size: $(ls -lh "$OUTPUT_DIR/boot/Image.gz" | awk '{print $5}')"
    step_end "kernel_image" "$key"
}

build_dtbs() {
    local key="rev=$(_pegasus_rev) chip=$CHIP boot=$BOOT_MEDIA"
    if step_should_skip "dtbs" "$key" && compgen -G "$OUTPUT_DIR/boot/*.dtb" >/dev/null; then
        skip "[dtbs] already built ($(ls "$OUTPUT_DIR/boot/"*.dtb 2>/dev/null | wc -l) files)"
        return 0
    fi
    step_begin "dtbs"
    stage_for dtbs >/dev/null
    docker_run "
        cd /workspace/pegasus/platform/ss928v100_gcc/open_source/linux
        export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
        [ ! -f .config ] && make ss928v100_emmc_ubuntu_defconfig
        make -j\$JOBS dtbs
        cp arch/arm64/boot/dts/vendor/*.dtb /workspace/output/.staging/dtbs/
    "
    commit_stage dtbs "$OUTPUT_DIR/boot"
    ok "DTBs built: $(ls "$OUTPUT_DIR/boot/"*.dtb 2>/dev/null | wc -l) files"
    step_end "dtbs" "$key"
}

build_kernel() {
    build_kernel_image
    build_dtbs
}

build_uboot() {
    local key="rev=$(_pegasus_rev) chip=$CHIP boot=$BOOT_MEDIA"
    if step_should_skip "uboot" "$key" && [ -f "$OUTPUT_DIR/boot/u-boot.bin" ]; then
        skip "[uboot] already built (u-boot.bin present)"
        return 0
    fi
    step_begin "uboot"
    stage_for uboot >/dev/null
    docker_run "
        cd /workspace/pegasus/platform/ss928v100_gcc/open_source/u-boot
        export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
        make ss928v100_emmc_defconfig
        make -j\$JOBS
        cp u-boot.bin /workspace/output/.staging/uboot/
    "
    commit_stage uboot "$OUTPUT_DIR/boot"
    require_file "$OUTPUT_DIR/boot/u-boot.bin"
    ok "u-boot.bin size: $(ls -lh "$OUTPUT_DIR/boot/u-boot.bin" | awk '{print $5}')"
    step_end "uboot" "$key"
}

build_atf() {
    local key="rev=$(_pegasus_rev) chip=$CHIP"
    if step_should_skip "atf" "$key" && [ -f "$OUTPUT_DIR/boot/bl31.bin" ]; then
        skip "[atf] already built (bl31.bin present)"
        return 0
    fi
    step_begin "atf"
    stage_for atf >/dev/null
    docker_run "
        cd /workspace/pegasus/platform/ss928v100_gcc/open_source/trusted-firmware-a
        make CROSS_COMPILE=aarch64-linux-gnu- PLAT=ss928v100 DEBUG=0 bl31
        cp build/ss928v100/release/bl31.bin /workspace/output/.staging/atf/
    "
    commit_stage atf "$OUTPUT_DIR/boot"
    require_file "$OUTPUT_DIR/boot/bl31.bin"
    ok "bl31.bin size: $(ls -lh "$OUTPUT_DIR/boot/bl31.bin" | awk '{print $5}')"
    step_end "atf" "$key"
}

build_mpp() {
    local key="rev=$(_pegasus_rev) chip=$CHIP"
    local existing; existing=$(ls "$OUTPUT_DIR/mpp/ko/"*.ko 2>/dev/null | wc -l)
    if step_should_skip "mpp" "$key" && [ "$existing" -gt 0 ]; then
        skip "[mpp] already built ($existing modules)"
        return 0
    fi
    step_begin "mpp"
    stage_for mpp_ko  >/dev/null
    stage_for mpp_lib >/dev/null
    docker_run "
        cd /workspace/pegasus/platform/ss928v100_gcc/smp/a55_linux/interdrv
        export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
        make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS=aarch64-linux-gnu- CHIP=ss928v100

        cp -r /workspace/pegasus/platform/ss928v100_gcc/smp/a55_linux/mpp/out/ko/*  /workspace/output/.staging/mpp_ko/  2>/dev/null || true
        cp -r /workspace/pegasus/platform/ss928v100_gcc/smp/a55_linux/mpp/out/lib/* /workspace/output/.staging/mpp_lib/ 2>/dev/null || true
    "
    commit_stage mpp_ko  "$OUTPUT_DIR/mpp/ko"
    commit_stage mpp_lib "$OUTPUT_DIR/mpp/lib"
    local ko_count; ko_count=$(ls "$OUTPUT_DIR/mpp/ko/"*.ko 2>/dev/null | wc -l)
    [ "$ko_count" -gt 0 ] || { err "no kernel modules produced"; return 1; }
    ok "MPP built: $ko_count kernel modules"
    step_end "mpp" "$key"
}

build_rootfs() {
    # The rootfs lives inside the build container's /workspace/rootfs and
    # is rebuilt each invocation. We still record a completion marker so
    # `state` shows it ran; a follow-up `integrate`/`package` in the same
    # invocation reuses the in-container rootfs.
    local key="type=$ROOTFS_TYPE"
    step_begin "rootfs_$ROOTFS_TYPE"
    local pkg_extra=""
    [ "$ROOTFS_TYPE" = "xfce" ] && pkg_extra="xfce4 xfce4-goodies lightdm"

    docker_run "
        mkdir -p /workspace/rootfs
        echo 'Extracting Ubuntu base...'
        tar -xzf /workspace/downloads/ubuntu-base-22.04.5-base-arm64.tar.gz -C /workspace/rootfs

        mount -t proc /proc /workspace/rootfs/proc
        mount -t sysfs /sys /workspace/rootfs/sys
        mount -o bind /dev /workspace/rootfs/dev
        mount -o bind /dev/pts /workspace/rootfs/dev/pts
        cp /etc/resolv.conf /workspace/rootfs/etc/resolv.conf

        chroot /workspace/rootfs /bin/bash -c '
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends \
                systemd systemd-sysv udev dbus sudo nano vim \
                kmod net-tools ethtool htop \
                iputils-ping ssh network-manager \
                wget curl ca-certificates resolvconf \
                $pkg_extra

            useradd -s /bin/bash -m -G adm,sudo hi 2>/dev/null || true
            echo "hi:hi" | chpasswd
            echo hi3403 > /etc/hostname
            echo \"127.0.0.1 localhost\" > /etc/hosts
            echo \"127.0.1.1 hi3403\" >> /etc/hosts
            systemctl enable NetworkManager ssh 2>/dev/null || true
            apt-get clean && rm -rf /var/lib/apt/lists/*
        '

        # Autostart service
        cat > /workspace/rootfs/etc/init.d/topeet-start.sh << 'EOF'
#!/bin/bash
[ ! -f /var/lib/resize2fs_done ] && { resize2fs /dev/mmcblk0p3; touch /var/lib/resize2fs_done; }
cd /ko && bash load_ss928v100_ubuntu -i
sleep 2
sample_gfbg 0 0 0 &
sleep 3
startxfce4 &
while true; do sleep 300; killall xfce4-screensaver 2>/dev/null; done
EOF
        chmod +x /workspace/rootfs/etc/init.d/topeet-start.sh

        cat > /workspace/rootfs/usr/lib/systemd/system/topeet-start.service << 'EOF'
[Unit]
Description=TOPEET Hi3403V100 Start Script
[Service]
Type=oneshot
ExecStart=/etc/init.d/topeet-start.sh
RemainAfterExit=true
[Install]
WantedBy=sysinit.target
EOF

        chroot /workspace/rootfs systemctl enable topeet-start.service 2>/dev/null || true

        umount /workspace/rootfs/dev/pts 2>/dev/null || true
        umount /workspace/rootfs/dev 2>/dev/null || true
        umount /workspace/rootfs/sys 2>/dev/null || true
        umount /workspace/rootfs/proc 2>/dev/null || true

        du -sh /workspace/rootfs
    "
    ok "Rootfs created ($ROOTFS_TYPE)"
    step_end "rootfs_$ROOTFS_TYPE" "$key"
}

# === Integrate ========================================================
integrate_mpp() {
    # Same caveat as build_rootfs: the rootfs is in-container, so we just
    # always re-run on demand. Marker is recorded for visibility.
    local key="type=$ROOTFS_TYPE rev=$(_pegasus_rev)"
    step_begin "integrate_mpp"
    docker_run "
        ROOTFS=/workspace/rootfs
        # Kernel modules
        mkdir -p \$ROOTFS/ko
        cp /workspace/output/mpp/ko/*.ko \$ROOTFS/ko/ 2>/dev/null || true
        cp /workspace/output/mpp/ko/load_ss928v100_ubuntu \$ROOTFS/ko/

        # MPP libraries
        cp /workspace/output/mpp/lib/*.so* \$ROOTFS/usr/lib/ 2>/dev/null || true
        echo '/usr/lib' > \$ROOTFS/etc/ld.so.conf.d/mpp.conf

        echo 'MPP integration complete'
    "
    ok "MPP integrated into rootfs"
    step_end "integrate_mpp" "$key"
}

# === Package ==========================================================
package_image() {
    local img_name="hi3403-ubuntu-${ROOTFS_TYPE}-${CHIP}.img"
    local key="img=$img_name rev=$(_pegasus_rev)"
    # Always re-run packaging on demand (output is the final artifact and
    # cheap-ish), but write atomically so an aborted run can't leave a
    # truncated image in output/.
    step_begin "package_$ROOTFS_TYPE"
    docker_run "
        ROOTFS_SIZE=\$(du -sm /workspace/rootfs | cut -f1)
        IMG_SIZE=\$(( ROOTFS_SIZE * 120 / 100 ))
        [ \$IMG_SIZE -lt 2048 ] && IMG_SIZE=2048

        echo \"Rootfs size: \${ROOTFS_SIZE}MB, Image size: \${IMG_SIZE}MB\"
        # Write to a .partial file, then rename atomically once the copy
        # finishes so an interrupted run doesn't leave a corrupt image.
        dd if=/dev/zero of=/workspace/output/$img_name.partial bs=1M count=\$IMG_SIZE status=progress
        mkfs.ext4 -F -L hi3403_rootfs /workspace/output/$img_name.partial
        mkdir -p /mnt/rootfs
        mount /workspace/output/$img_name.partial /mnt/rootfs
        cp -a /workspace/rootfs/* /mnt/rootfs/
        sync
        umount /mnt/rootfs
        mv /workspace/output/$img_name.partial /workspace/output/$img_name
        ls -lh /workspace/output/$img_name
    "
    require_file "$OUTPUT_DIR/$img_name"
    ok "Image packaged: $OUTPUT_DIR/$img_name"
    step_end "package_$ROOTFS_TYPE" "$key"
}

# === Main =============================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -j) JOBS="$2"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            --force) export HI3403_FORCE=1; shift ;;
            --no-log) export HI3403_NO_LOG=1; shift ;;
            -h|--help) usage ;;
            ROOTFS_TYPE=*) ROOTFS_TYPE="${1#*=}"; shift ;;
            BOOT_MEDIA=*)  BOOT_MEDIA="${1#*=}"; shift ;;
            CHIP=*)        CHIP="${1#*=}"; shift ;;
            *) COMMAND="$1"; shift ;;
        esac
    done
}

main() {
    COMMAND=""
    DRY_RUN=0
    parse_args "$@"

    cd "$SCRIPT_DIR"
    mkdir -p "$OUTPUT_DIR"/{boot,rootfs,mpp/ko,mpp/lib,.staging} "$DOWNLOADS_DIR"

    # Tee output to logs/build-<ts>.log unless disabled. Skip for
    # read-only commands that produce minimal output.
    case "${COMMAND:-usage}" in
        help|--help|-h|state|verify|clean-state|usage|"") ;;
        *) init_logfile ;;
    esac

    case "${COMMAND:-usage}" in
        help|--help|-h|usage) usage ;;

        # Full builds
        ubuntu_xfce_all)
            ROOTFS_TYPE=xfce
            setup_sources
            docker_build
            extract_and_patch
            build_kernel && build_uboot && build_atf
            build_mpp
            build_rootfs
            integrate_mpp
            package_image
            ;;
        ubuntu_lite_all)
            ROOTFS_TYPE=lite
            setup_sources
            docker_build
            extract_and_patch
            build_kernel && build_uboot && build_atf
            build_mpp
            build_rootfs
            integrate_mpp
            package_image
            ;;
        all)
            ROOTFS_TYPE=xfce
            setup_sources; docker_build; extract_and_patch
            build_kernel && build_uboot && build_atf
            build_mpp; build_rootfs; integrate_mpp; package_image
            ;;

        # Individual components
        uboot)        docker_build; build_uboot ;;
        atf)          docker_build; build_atf ;;
        kernel)       docker_build; build_kernel ;;
        kernel-image) docker_build; build_kernel_image ;;
        dtb|dtbs)     docker_build; build_dtbs ;;
        mpp)          docker_build; build_mpp ;;
        boot)         docker_build; build_uboot && build_atf && build_kernel ;;

        # Rootfs variants
        ubuntu_xfce) ROOTFS_TYPE=xfce; docker_build; build_rootfs ;;
        ubuntu_lite) ROOTFS_TYPE=lite; docker_build; build_rootfs ;;
        rootfs) docker_build; build_rootfs ;;

        # Integration & packaging
        integrate) docker_build; integrate_mpp ;;
        package)  docker_build; package_image ;;

        # Setup only
        setup) setup_sources; docker_build; extract_and_patch ;;
        sources) setup_sources ;;

        # Docker
        shell) docker_build; docker run -it --rm \
            -v "$PEGASUS_DIR":/workspace/pegasus \
            -v "$DOWNLOADS_DIR":/workspace/downloads \
            -v "$OUTPUT_DIR":/workspace/output \
            "$DOCKER_IMAGE" bash ;;

        # Clean
        clean)
            log "Cleaning build artifacts..."
            rm -rf "$OUTPUT_DIR/boot"/* "$OUTPUT_DIR/mpp"/* "$OUTPUT_DIR/"*.img \
                   "$OUTPUT_DIR/.staging" "$STATE_DIR"/*.done
            docker run --rm -v "$PEGASUS_DIR":/workspace/pegasus "$DOCKER_IMAGE" bash -c "
                rm -rf /workspace/rootfs
                cd /workspace/pegasus/platform/ss928v100_gcc/open_source/linux && make mrproper 2>/dev/null || true
                cd /workspace/pegasus/platform/ss928v100_gcc/open_source/u-boot && make mrproper 2>/dev/null || true
            " 2>/dev/null || true
            ok "Cleaned (artifacts + staging + step markers)"
            ;;

        # Verification & state
        verify) verify_all_downloads ;;
        state)  state_list ;;
        clean-state) state_clear_all ;;

        *)
            echo "Unknown command: ${COMMAND:-none}"
            echo "Run './build.sh --help' for usage"
            exit 1
            ;;
    esac

    # Skip the artifact summary for read-only / informational commands.
    case "$COMMAND" in
        verify|state|clean-state|help|--help|-h) return 0 ;;
    esac

    echo ""
    log "Done! Output: $OUTPUT_DIR/"
    ls -lh "$OUTPUT_DIR/boot/" 2>/dev/null
    ls -lh "$OUTPUT_DIR/"*.img 2>/dev/null
}

main "$@"
