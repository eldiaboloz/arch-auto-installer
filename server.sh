#!/usr/bin/env bash

set -e

timedatectl set-ntp true

curp=$(dirname "$0")

# load .env
if [ -f "$curp/.env" ]; then
    source "$curp/.env"
else
    echo "File $curp/.env does not exist!"
    echo "Copy $curp/.env.example as $curp/.env and edit it first!"
    exit 1
fi

if [ "$AAI_FORMAT" -eq "1" ]; then
    # format target device
    (
    echo o # Create a new empty DOS partition table
    echo n # Add a new partition
    echo p # Primary partition
    echo 1 # Partition number
    echo   # First sector (Accept default: 1)
    echo   # Last sector (Accept default: varies)
    echo w # Write changes
    ) | fdisk $AAI_DEVICE

    mkfs.ext4 $AAI_PARTITION
fi

mountpoint -q "$AAI_MNT" || mount $AAI_PARTITION "$AAI_MNT"

if [ "$AAI_MIRROR" == "yes" ]; then
cp "$curp/mirrorlist" /etc/pacman.d/mirrorlist
fi

if [ "$AAI_SKIP_INIT" == "no" ]; then
   if [ "$(hostname)" == "archiso" ]; then
       # do not use host cache on arch iso
       pacstrap "$AAI_MNT" base base-devel
   else
       pacstrap -c "$AAI_MNT" base base-devel
   fi
fi

genfstab -U "$AAI_MNT" > "$AAI_MNT"/etc/fstab

repopkgs=$(cat "${curp}/repo-server.txt" | grep  -v '^#\|^$' | tr '\n' ' ')
arch-chroot "$AAI_MNT" << EOF
set -o errexit

# first update db
pacman -Sy

ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime
hwclock --systohc
# setup locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "LC_COLLATE=C" >> /etc/locale.conf
echo "$AAI_HOSTNAME" > /etc/hostname
echo "127.0.1.1 ${AAI_HOSTNAME}.localdomain ${AAI_HOSTNAME}" >> /etc/hosts

# sysctl customizations
echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.d/99-sysctl.conf
echo "fs.file-max=131072" >> /etc/sysctl.d/99-sysctl.conf
echo "net.bridge.bridge-nf-call-ip6tables=0" >> /etc/sysctl.d/99-sysctl.conf
echo "net.bridge.bridge-nf-call-iptables=0" >> /etc/sysctl.d/99-sysctl.conf
echo "net.bridge.bridge-nf-call-arptables=0" >> /etc/sysctl.d/99-sysctl.conf

# ensure br_netfilter module is loaded on boot so rules are applied correctly
echo "br_netfilter" > /etc/modules-load.d/br-netfilter.conf

# swap setup
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile

# pacman
pacman --noconfirm -S $repopkgs

if [ ! -d "/home/$AAI_USER" ]; then
useradd --create-home "$AAI_USER" --shell /usr/bin/zsh
groupadd sudo
usermod -aG video,audio,scanner,lp,sudo,docker $AAI_USER
fi

# ssh daemon
systemctl enable sshd.service

# dhcp client on all interfaaces
systemctl enable dhcpcd.service

# cron service
systemctl enable cronie.service

# ntp client using systemd
systemctl enable systemd-timesyncd.service

EOF

arch-chroot "$AAI_MNT" sh -c "echo \"$AAI_USER:$AAI_PASSWORD\" | chpasswd"

# setup sudoers file
cat>"$AAI_MNT"/etc/sudoers << EOF
root ALL=(ALL) ALL
%sudo ALL=(ALL) ALL
Defaults insults
EOF

# ssh access
mkdir -pv "$AAI_MNT"/root/.ssh
chmod 0700 "$AAI_MNT"/root/.ssh
[ -f "$curp/root_authorized_keys" ] && \
    cp "$curp/root_authorized_keys" "$AAI_MNT"/root/.ssh/authorized_keys

# bootloader - grub
arch-chroot "$AAI_MNT" mkinitcpio -p linux

# add options to restart / shutdown
cat >> "$AAI_MNT"/etc/grub.d/40_custom << 'EOF'
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.

menuentry "System shutdown" {
	echo "System shutting down..."
	halt
}

menuentry "System restart" {
	echo "System rebooting..."
	reboot
}

EOF
cat >> "$AAI_MNT"/etc/default/grub << 'EOF'
GRUB_DEFAULT=saved
GRUB_TIMEOUT=5
GRUB_SAVEDEFAULT="true"
GRUB_DISABLE_SUBMENU=y
GRUB_CMDLINE_LINUX_DEFAULT="quiet i915.modeset=0" 
EOF

arch-chroot "$AAI_MNT" << EOF
grub-install --target=i386-pc "$AAI_DEVICE"
grub-mkconfig -o /boot/grub/grub.cfg
echo "root:${AAI_ROOT_PASSWORD}" | chpasswd
EOF

