#!/bin/bash
# Format two USB-attached drives as ext4 and merge them into a single
# mergerfs pool. No RAID: every file lives entirely on one physical disk,
# so either drive stays independently readable on any other PC — this is a
# deliberate trade-off for a home-backup appliance where "can I plug this
# drive into a random computer and just read the files" matters more than
# throughput or fault tolerance. See docs/architecture.md for the reasoning.
#
# Edit DISK1_DEV / DISK2_DEV below to match your two drives (check with
# `lsblk -o NAME,SIZE,TYPE,TRAN,MODEL` first).
set -e

DISK1_DEV=/dev/sda1
DISK2_DEV=/dev/sdb1

echo "=== Before ==="
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL

echo "=== Formatting (ext4) ==="
mkfs.ext4 -F -L BACKUP1 "$DISK1_DEV"
mkfs.ext4 -F -L BACKUP2 "$DISK2_DEV"

echo "=== Mount points ==="
mkdir -p /mnt/disk1 /mnt/disk2 /mnt/backup

UUID1=$(blkid -s UUID -o value "$DISK1_DEV")
UUID2=$(blkid -s UUID -o value "$DISK2_DEV")

# Remove any previous fstab lines for these UUIDs (safe to re-run), then append fresh ones.
sed -i "\#UUID=$UUID1#d; \#UUID=$UUID2#d; \#/mnt/backup#d" /etc/fstab

cat >> /etc/fstab <<EOF
UUID=$UUID1  /mnt/disk1  ext4  defaults,nofail,noatime  0  2
UUID=$UUID2  /mnt/disk2  ext4  defaults,nofail,noatime  0  2
EOF

mount -a

echo "=== Marker files (used by drive-backup.sh to detect a missing/failed disk) ==="
touch /mnt/disk1/.disk1-online
touch /mnt/disk2/.disk2-online

echo "=== Installing mergerfs ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y mergerfs 2>&1 | tail -10
mergerfs --version

echo "=== Setting up the mergerfs pool ==="
sed -i "\#/mnt/backup#d" /etc/fstab
cat >> /etc/fstab <<EOF
/mnt/disk1:/mnt/disk2  /mnt/backup  fuse.mergerfs  defaults,nofail,category.create=mfs,moveonenospc=true,minfreespace=10G,fsname=backuppool  0  0
EOF

mount /mnt/backup

echo "=== Result ==="
df -h /mnt/disk1 /mnt/disk2 /mnt/backup
echo "--- fstab ---"
cat /etc/fstab
echo "--- markers visible through the pool? ---"
ls -la /mnt/backup
