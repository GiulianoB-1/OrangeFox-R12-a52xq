#!/system/bin/sh

LOG=/tmp/of_sdcard_mount.log
FLAGS=/system/etc/twrp.flags

# Never let a failed SD mount prevent recovery from booting.
exec >>"$LOG" 2>&1

echo "=== OrangeFox a52xq unified SD mount helper v2 ==="
date 2>/dev/null || true

# Use the exact mount point OrangeFox registered for its MicroSD storage object.
# This is /external_sd in the earlier experimental recovery and /sdcard1 in the
# original recovery. Mounting anywhere else creates a second, unusable entry.
MNT=""
if [ -f "$FLAGS" ]; then
    MNT="$(awk '$0 !~ /^[[:space:]]*#/ && /display="MicroSD"/ { print $1; exit }' "$FLAGS" 2>/dev/null)"
fi
case "$MNT" in
    /*) ;;
    *) MNT=/sdcard1 ;;
esac

echo "OrangeFox MicroSD mount point: $MNT"
mkdir -p "$MNT"

is_mounted_at() {
    grep -q " $1 " /proc/mounts 2>/dev/null
}

find_sd_partition() {
    local sysdev name dtype removable part size

    # Prefer a real removable MMC device reported as an SD card.
    for sysdev in /sys/class/block/mmcblk*; do
        [ -e "$sysdev" ] || continue
        name="${sysdev##*/}"
        case "$name" in
            *p*|*boot*|*rpmb*) continue ;;
        esac

        dtype="$(cat "$sysdev/device/type" 2>/dev/null)"
        removable="$(cat "$sysdev/removable" 2>/dev/null)"
        echo "candidate=$name type=$dtype removable=$removable"

        if [ "$dtype" = "SD" ] || [ "$removable" = "1" ] || [ "$name" = "mmcblk0" ]; then
            for part in /sys/class/block/${name}p*; do
                [ -e "$part" ] || continue
                size="$(cat "$part/size" 2>/dev/null)"
                [ -n "$size" ] || size=0
                if [ "$size" -gt 0 ] 2>/dev/null; then
                    echo "/dev/block/${part##*/}"
                    return 0
                fi
            done

            [ -b "/dev/block/$name" ] && {
                echo "/dev/block/$name"
                return 0
            }
        fi
    done

    # Recovery-specific aliases, when present.
    for part in /tmp/of_sdcard1 /dev/block/mmcblk0p1; do
        [ -b "$part" ] && {
            echo "$part"
            return 0
        }
    done

    return 1
}

# Remove only the obsolete mount created by v1. Do not unmount OrangeFox's
# selected mount point if it is already correct.
for OLD in /sdcard1 /external_sd; do
    [ "$OLD" = "$MNT" ] && continue
    if is_mounted_at "$OLD"; then
        echo "Unmounting obsolete duplicate SD mount: $OLD"
        umount "$OLD" 2>/dev/null || umount -l "$OLD" 2>/dev/null || true
    fi
done

if is_mounted_at "$MNT"; then
    echo "$MNT is already mounted"
    mount | grep " $MNT " || true
    exit 0
fi

# Give ueventd/MMC a short time to create the partition node.
DEV=""
i=0
while [ "$i" -lt 20 ]; do
    DEV="$(find_sd_partition | tail -n 1)"
    [ -b "$DEV" ] && break
    DEV=""
    i=$((i + 1))
    sleep 0.2
done

if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    echo "No usable microSD block partition found"
    echo "Known MMC entries:"
    ls -l /dev/block/mmcblk* 2>/dev/null || true
    exit 0
fi

echo "Selected SD partition: $DEV"
ls -l "$DEV" 2>/dev/null || true

# Samsung's kernel registers one FAT/exFAT driver as 'sdfat'.
# It auto-detects FAT12/16/32 and exFAT internally.
if mount -t sdfat -o rw,fs=auto "$DEV" "$MNT"; then
    echo "Mounted with sdfat read-write"
elif mount -t sdfat -o ro,fs=auto "$DEV" "$MNT"; then
    echo "Mounted with sdfat read-only"
elif mount -t vfat -o rw "$DEV" "$MNT"; then
    echo "Mounted with vfat read-write"
elif mount -t vfat -o ro "$DEV" "$MNT"; then
    echo "Mounted with vfat read-only"
elif [ -x /system/bin/mount.ntfs ] && /system/bin/mount.ntfs "$DEV" "$MNT"; then
    echo "Mounted with NTFS helper"
elif mount -t ext4 -o rw "$DEV" "$MNT"; then
    echo "Mounted with ext4 read-write"
elif mount -t ext4 -o ro "$DEV" "$MNT"; then
    echo "Mounted with ext4 read-only"
else
    echo "All mount attempts failed"
    dmesg | tail -n 120
    exit 0
fi

mount | grep " $MNT " || true
ls -la "$MNT" 2>/dev/null | head -n 40 || true
exit 0
