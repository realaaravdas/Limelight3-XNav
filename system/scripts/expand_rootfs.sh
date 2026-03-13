#!/bin/bash
# XNav Root Partition Expansion
# Expands the root partition and filesystem to fill the entire disk.
# Called by xnav-expand-rootfs.service on first boot.
#
# This is a safety-net for devices where the standard Raspberry Pi
# init_resize.sh did not run (e.g., eMMC flashing via rpiboot).

set -e

MARKER="/var/lib/xnav/.rootfs-expanded"

# Already expanded — nothing to do
if [ -f "$MARKER" ]; then
  echo "Root filesystem already expanded."
  exit 0
fi

echo "========================================="
echo "XNav Root Partition Expansion - $(date)"
echo "========================================="

# Determine root device and partition
ROOT_PART=$(findmnt -n -o SOURCE /)
if [ -z "$ROOT_PART" ]; then
  echo "ERROR: Could not determine root partition."
  exit 1
fi

echo "Root partition: $ROOT_PART"

# Extract disk device and partition number
# Handles /dev/mmcblk0p2, /dev/sda2, /dev/nvme0n1p2
if echo "$ROOT_PART" | grep -q "mmcblk\|nvme"; then
  ROOT_DEV=$(echo "$ROOT_PART" | sed 's/p[0-9]*$//')
  PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]*$')
else
  ROOT_DEV=$(echo "$ROOT_PART" | sed 's/[0-9]*$//')
  PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]*$')
fi

echo "Disk device:    $ROOT_DEV"
echo "Partition num:  $PART_NUM"

if [ -z "$ROOT_DEV" ] || [ -z "$PART_NUM" ]; then
  echo "ERROR: Could not parse disk device / partition number."
  exit 1
fi

# Check if there is free space after the last partition
DISK_SIZE=$(blockdev --getsize64 "$ROOT_DEV")
# Get end of root partition in bytes
PART_END_SECTOR=$(partx -g -o END -n "$PART_NUM" "$ROOT_DEV" | tr -d ' ')
SECTOR_SIZE=$(blockdev --getss "$ROOT_DEV")
PART_END_BYTES=$(( (PART_END_SECTOR + 1) * SECTOR_SIZE ))

FREE_BYTES=$(( DISK_SIZE - PART_END_BYTES ))
FREE_MB=$(( FREE_BYTES / 1024 / 1024 ))

echo "Disk size:      $((DISK_SIZE / 1024 / 1024)) MiB"
echo "Partition ends: $((PART_END_BYTES / 1024 / 1024)) MiB"
echo "Free space:     ${FREE_MB} MiB"

if [ "$FREE_MB" -lt 10 ]; then
  echo "Less than 10 MiB free after root partition — nothing to expand."
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
  exit 0
fi

echo "Expanding root partition to fill disk..."

# Use growpart (from cloud-guest-utils) if available, otherwise use parted
if command -v growpart &>/dev/null; then
  growpart "$ROOT_DEV" "$PART_NUM"
elif command -v parted &>/dev/null; then
  # Delete and recreate the partition to fill the disk
  echo "Yes" | parted ---pretend-input-tty "$ROOT_DEV" resizepart "$PART_NUM" 100%
elif command -v sfdisk &>/dev/null; then
  # Use sfdisk to resize
  echo ", +" | sfdisk -N "$PART_NUM" "$ROOT_DEV" --no-reread --force
  partprobe "$ROOT_DEV" 2>/dev/null || true
else
  echo "ERROR: No partition resize tool found (growpart, parted, or sfdisk)."
  exit 1
fi

# Resize the filesystem
echo "Resizing ext4 filesystem..."
resize2fs "$ROOT_PART"

# Mark as done
mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"

echo "========================================="
echo "Root partition expanded successfully!"
echo "New size: $(df -h "$ROOT_PART" | tail -1 | awk '{print $2}')"
echo "========================================="
