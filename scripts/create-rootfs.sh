#!/bin/bash
# Run INSIDE Docker container
# Creates Ubuntu 22.04 ARM64 rootfs with XFCE desktop

set -e
ROOTFS=/workspace/rootfs
UBUNTU_BASE=/workspace/downloads/ubuntu-base-22.04.5-base-arm64.tar.gz

mkdir -p $ROOTFS
echo "Extracting Ubuntu base..."
tar -xzf $UBUNTU_BASE -C $ROOTFS

echo "Setting up chroot..."
mount -t proc /proc $ROOTFS/proc
mount -t sysfs /sys $ROOTFS/sys
mount -o bind /dev $ROOTFS/dev
mount -o bind /dev/pts $ROOTFS/dev/pts
cp /etc/resolv.conf $ROOTFS/etc/resolv.conf

echo "Installing packages in chroot..."
chroot $ROOTFS /bin/bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    systemd systemd-sysv udev dbus sudo nano vim \
    kmod net-tools ethtool htop \
    iputils-ping ssh network-manager \
    xfce4 xfce4-goodies lightdm \
    wget curl ca-certificates \
    resolvconf ifupdown rsyslog

# Create user
useradd -s /bin/bash -m -G adm,sudo hi
echo 'hi:hi' | chpasswd

# Hostname
echo 'hi3403' > /etc/hostname
echo '127.0.0.1 localhost' > /etc/hosts
echo '127.0.1.1 hi3403' >> /etc/hosts

# Enable services
systemctl enable NetworkManager
systemctl enable ssh

apt-get clean
rm -rf /var/lib/apt/lists/*
"

echo "Creating autostart service..."
cat > $ROOTFS/etc/init.d/topeet-start.sh << 'STARTEOF'
#!/bin/bash
if [ ! -f /var/lib/resize2fs_done ]; then
    resize2fs /dev/mmcblk0p3
    touch /var/lib/resize2fs_done
fi
cd /ko
bash load_ss928v100_ubuntu -i
sleep 2
sample_gfbg 0 0 0 &
sleep 3
startxfce4 &
while true; do
    sleep 300
    killall xfce4-screensaver 2>/dev/null
done
STARTEOF

chmod +x $ROOTFS/etc/init.d/topeet-start.sh

cat > $ROOTFS/usr/lib/systemd/system/topeet-start.service << 'SVCEOF'
[Unit]
Description=TOPEET Hi3403V100 Start Ubuntu Script
[Service]
Type=oneshot
ExecStart=/etc/init.d/topeet-start.sh
RemainAfterExit=true
[Install]
WantedBy=sysinit.target
SVCEOF

chroot $ROOTFS systemctl enable topeet-start.service

echo "Cleaning up chroot..."
umount $ROOTFS/dev/pts
umount $ROOTFS/dev
umount $ROOTFS/sys
umount $ROOTFS/proc

echo "Rootfs created at $ROOTFS"
du -sh $ROOTFS
