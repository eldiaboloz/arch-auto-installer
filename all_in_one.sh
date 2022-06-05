#!/usr/bin/env bash

set -e

curp=$(dirname "$0")

export http_proxy=http://10.40.30.80:3128/

# load .env
if [ -f "$curp/.env" ]; then
  source "$curp/.env"
else
  echo "File $curp/.env does not exist!"
  echo "Copy $curp/.env.example as $curp/.env and edit it first!"
  exit 1
fi

if [ "$AAI_FORMAT" -eq "1" ]; then
  parted "$AAI_DEVICE" --script -- mklabel msdos
  parted "$AAI_DEVICE" --script -- mkpart primary 0% 100%
  mkfs.ext4 -F "$AAI_PARTITION"
fi

mountpoint -q "$AAI_MNT" || mount $AAI_PARTITION "$AAI_MNT"

if [ "$AAI_MIRROR" == "yes" ]; then
  cp "$curp/mirrorlist" /etc/pacman.d/mirrorlist
fi

# fix for older archiso file - update database and keyring first
http_proxy=http://10.40.30.80:3128/ pacman -Syv --noconfirm archlinux-keyring

if [ "$AAI_SKIP_INIT" == "no" ]; then
  if [ "$(hostname)" == "archiso" ]; then
    # do not use host cache on arch iso
    http_proxy=http://10.40.30.80:3128/ pacstrap "$AAI_MNT" base base-devel
  else
    http_proxy=http://10.40.30.80:3128/ pacstrap -c "$AAI_MNT" base base-devel
  fi
fi

pkgs=()
cmds=()

case "${AAI_TYPE}" in
vm)
  while read -r pkg; do
    pkgs+=("${pkg}")
    # install and enable qemu-guest-agent.service
    cmds+=("systemctl enable qemu-guest-agent.service")
  done < <(cat "$curp"/pkgs/all.txt "$curp"/pkgs/vm.txt | sort | uniq)
  ;;
desktop)
  while read -r pkg; do
    pkgs+=("${pkg}")
  done < <(cat "$curp"/pkgs/all.txt "$curp"/pkgs/host.txt "$curp"/pkgs/desktop.txt | sort | uniq)
  ;;
server)
  while read -r pkg; do
    pkgs+=("${pkg}")
  done < <(cat "$curp"/pkgs/all.txt "$curp"/pkgs/host.txt "$curp"/pkgs/server.txt | sort | uniq)
  ;;
*)
  echo "Unknown machine type!!"
  exit 1
  ;;
esac

if [ "${AAI_DOCKER}" == "y" ]; then
  pkgs+=("docker" "docker-compose")
  cmds+=("usermod -aG docker \"${AAI_USER}\"")
  cmds+=("systemctl enable docker.service")
fi

if [ "${AAI_TIME_SYNC}" == "y" ]; then
  cmds+=("timedatectl set-ntp true")
  cmds+=("systemctl enable systemd-timesyncd.service")
  cmds+=("hwclock --systohc")
fi

if [ ! -z "${AAI_SWAPFILE}" ]; then
  cmds+=("fallocate -l \"${AAI_SWAPFILE}\" /swapfile")
  cmds+=("chmod 600 /swapfile")
  cmds+=("mkswap /swapfile")
fi

if [ "${AAI_LIBVIRT}" == "y" ]; then
  cmds+=("echo br_netfilter > /etc/modules-load.d/br-netfilter.conf")
  cmds+=("echo net.bridge.bridge-nf-call-ip6tables=0 >> /etc/sysctl.d/99-sysctl.conf")
  cmds+=("echo net.bridge.bridge-nf-call-iptables=0 >> /etc/sysctl.d/99-sysctl.conf")
  cmds+=("echo net.bridge.bridge-nf-call-arptables=0 >> /etc/sysctl.d/99-sysctl.conf")
  cmds+=("systemctl enable libvirtd.service")
  pkgs+=("libvirt")
  pkgs+=("qemu")
  pkgs+=("openbsd-netcat")
  pkgs+=("bridge-utils")
fi

if [ "${AAI_DHCP}" == "y" ]; then
  cmds+=("systemctl enable dhcpcd.service")
fi

genfstab -U "$AAI_MNT" >"$AAI_MNT"/etc/fstab

arch-chroot "$AAI_MNT" <<EOF
set -o errexit

export http_proxy=http://10.40.30.80:3128/

ln -sf /usr/share/zoneinfo/"${AAI_TIMEZONE}" /etc/localtime

# setup locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "bg_BG.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "LC_COLLATE=C" >> /etc/locale.conf
echo "$AAI_HOSTNAME" > /etc/hostname
echo "127.0.1.1 ${AAI_HOSTNAME}.localdomain ${AAI_HOSTNAME}" >> /etc/hosts

# sysctl customizations - truncate with first command
echo "fs.inotify.max_user_watches=524288" > /etc/sysctl.d/99-sysctl.conf
echo "fs.file-max=131072" >> /etc/sysctl.d/99-sysctl.conf

# pacman
# workaround for conflict between iptables -> iptables-nft
http_proxy=http://10.40.30.80:3128/ pacman -S iptables-nft --noconfirm --ask 4
http_proxy=http://10.40.30.80:3128/ pacman --noconfirm -S $(echo ${pkgs[*]// /|})

if [ ! -d "/home/$AAI_USER" ]; then
useradd --create-home "$AAI_USER" --shell /usr/bin/zsh
groupadd sudo
usermod -aG video,audio,scanner,lp,sudo $AAI_USER
fi

# ssh daemon
systemctl enable sshd.service

# cron service
systemctl enable cronie.service

EOF

for cmd in "${cmds[@]}"; do
  arch-chroot "$AAI_MNT" <<EOF
  set -o errexit
  ${cmd}
EOF
done

arch-chroot "$AAI_MNT" <<EOF
echo "${AAI_USER}:${AAI_PASSWORD}" | chpasswd
EOF

# setup sudoers file
cat >"$AAI_MNT"/etc/sudoers <<EOF
root ALL=(ALL) ALL
%sudo ALL=(ALL) ALL
Defaults insults
EOF

# desktop machine - setup trizen and install aur pacakges
if [ "${AAI_TYPE}" == "desktop" ]; then
  arch-chroot "$AAI_MNT" <<EOF
  set -o errexit

# force sudo to use -A for the install
echo -ne '#!/usr/bin/env bash\necho '"${AAI_PASSWORD}"'\n' > /usr/local/bin/spit_pass.sh && chmod +x /usr/local/bin/spit_pass.sh
echo -ne '#!/bin/bash\n SUDO_ASKPASS=/usr/local/bin/spit_pass.sh /usr/bin/sudo -A "\$@"\n' > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo

EOF
  # sync trizen cache
  [ -d "/home/${AAI_USER}/.cache/trizen" ] && rsync -a /home/${AAI_USER}/.cache/trizen "${AAI_MNT}"/home/${AAI_USER}/.cache

  arch-chroot "${AAI_MNT}" "mkdir -pv /work && chown ${AAI_USER}:${AAI_USER} /work"

  #setup user enviroment
  arch-chroot "${AAI_MNT}" su -l "${AAI_USER}" <<EOF
set -o errexit

mkdir -pv /work/dev/personal
[ ! -d /work/dev/personal/i3wmonarch ] && git clone https://github.com/eldiaboloz/i3wmonarch.git /work/dev/personal/i3wmonarch
[ ! -d /work/dev/trizen ] && git clone https://aur.archlinux.org/trizen.git /work/dev/trizen
alias sudo="sudo -A"
cd /work/dev/trizen && makepkg --noconfirm -si
# dummy call so config is created
trizen --help > /dev/null
# persist trizen cache
sed -i 's#/tmp/trizen-$AAI_USER#\$ENV{HOME}/.cache/trizen#' \$HOME/.config/trizen/trizen.conf
# use modifed sudo command
sed -i 's#/usr/bin/sudo#/usr/local/bin/sudo#' \$HOME/.config/trizen/trizen.conf

# install aur packages
trizen --noconfirm -S ttf-font-icons skypeforlinux-stable-bin jetbrains-toolbox

cd /work/dev/personal/i3wmonarch && git submodule update --init --recursive && ./scripts/i3wm/create_symlinks.sh
cd /work/dev/personal/i3wmonarch/github.com/nonpop/xkblayout-state && make
cd /work/dev/personal/i3wmonarch/github.com/powerline/fonts && ./install.sh

EOF
fi

# ssh access
mkdir -pv "$AAI_MNT"/root/.ssh
chmod 0700 "$AAI_MNT"/root/.ssh
[ -f "$curp/root_authorized_keys" ] &&
  cp "$curp/root_authorized_keys" "$AAI_MNT"/root/.ssh/authorized_keys

if [ "$AAI_INTEL_BL" == "yes" ]; then
  cat >"$AAI_MNT"/etc/udev/rules.d/backlight.rules <<EOF
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOF
fi

# @TODO: setup trizen

# bootloader - grub
arch-chroot "$AAI_MNT" mkinitcpio -p linux

# add options to restart / shutdown
cat >>"$AAI_MNT"/etc/grub.d/40_custom <<'EOF'
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
cat >>"$AAI_MNT"/etc/default/grub <<'EOF'
GRUB_DEFAULT=saved
GRUB_TIMEOUT=5
GRUB_SAVEDEFAULT="true"
GRUB_DISABLE_SUBMENU=y
GRUB_CMDLINE_LINUX_DEFAULT="quiet i915.modeset=0"
EOF

arch-chroot "$AAI_MNT" <<EOF
grub-install --target=i386-pc "$AAI_DEVICE"
grub-mkconfig -o /boot/grub/grub.cfg
echo "root:${AAI_ROOT_PASSWORD}" | chpasswd
EOF
