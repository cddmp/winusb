#!/bin/bash

iso="$1"
device="$2"
requirements="sfdisk ntfslabel mkfs.ntfs grub-install rsync"

function is_mounted()
{
	local device=$1

	grep -qi "$device" /proc/mounts
	return $?
}

function check_requirements()
{
	local requirements="$1"
	local missing=0

	for tool in $requirements; do
		type "$tool" &> /dev/null
		if (( $? > 0 )); then
			echo "Couldn't find command ${tool}."
			missing=$((missing+1))
		fi
	done
	return $missing
}

function is_block_device
{
	local device="$1"

	[[ -b $device ]] && return 0
	return 1
}

function wipe_disk
{
	local device="$1"

	dd if=/dev/zero of="$device" count=10 bs=2M &> /dev/null
	sync
}

function prepare_disk
{
	local device="$1"
	local ntfs_uuid=""

	# Create msdos partition table
	echo '-,-,7,*;' | sfdisk -q $device &> /dev/null
	if (( $? > 0 )); then
		return 
	fi

	# Quick format as NTFS
	mkfs.ntfs -q -f "${device}1" &> /dev/null
	if (( $? > 0 )); then
		return
	fi

	# Read UUID
	ntfs_uuid=$(ntfslabel -v "${device}1" | grep -i "Serial number" | cut -d ":" -f 2)
	echo $ntfs_uuid
}

function install_grub
{
	local device="$1"
	local ntfs_uuid="$2"
	local dst="$3"

	grub-install -v --target=i386-pc --boot-directory="${dst}/boot" "$device"
	(( $? > 0 )) && return 1

	(
	echo 'echo "Booting Windows..."'
	echo 'insmod ntfs'
	echo 'insmod search_fs_uuid'
	echo 'search --no-floppy --fs-uid '$ntfs_uuid' --set root'
	echo 'ntldr /bootmgr'
	echo 'boot'
	) > "${dst}/boot/grub/grub.cfg"
	
	return 0
}

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 iso device"
	exit 1
fi

if ! check_requirements "$requirements"; then
	echo "Make sure all required tools are installed. Aborting."
	exit 1
fi

if ! is_block_device "$device" ; then
	echo "$device is not a block device. Aborting."
	exit 1
fi

if is_mounted "$device"; then
	echo "$device is currently mounted. Please umount $device and run the tool again. Aborting for now."
	exit 1
fi

while true; do
	clear
	echo "WARNING: This tool will wipe any data on ${device}. Are you sure you want to continue? (yes/no)"
	read line
	[[ $line == "yes" ]] && break
	[[ $line == "no" ]] && exit 0
done
clear

# Let's go...
echo "Running..."

echo "Wiping partition table..."
wipe_disk "$device"
if (( $? > 0 )); then
	echo "Couldn't wipe disk. Aborting."
	exit 1
fi

echo "Creating msdos partition table with one NTFS partition..."
ntfs_uuid=$(prepare_disk "$device")
if [ -z $ntfs_uuid ]; then
	echo "Something went wrong while preparing the disk. Aborting."
	exit 1
fi

echo "Copying files from Windows ISO to ${device}1..."
src=$(mktemp -d)
dst=$(mktemp -d)
mount -o loop "$iso" "$src" &> /dev/null
mount "${device}1" "$dst" &> /dev/null
if (( $? > 0 )); then
	echo "An error happened while trying to mount "${device}1". Aborting"
	exit 1
fi
rsync -a --info=progress2 "${src}/" "${dst}/" 
if (( $? > 0 )); then
	echo "An error happened while trying to copy files. Aborting."
	exit 1
fi
umount "$src"

echo "Installing grub on ${device}. This might take a very long time..."
install_grub "$device" "$ntfs_uuid" "$dst"
if (( $? > 0 )); then
	echo "An error happened while trying to install grub. Aborting."
	exit 1
fi
sync

echo "Cleaning up..."
umount "$dst"
rm -rf "$src"
rm -rf "$dst"

echo "Done."

