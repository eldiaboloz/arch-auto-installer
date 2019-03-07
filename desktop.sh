#!/usr/bin/env bash
# before chroot
# TODO: make UEFI setup
# generic desktop install with i3wm
set -e
#timedatectl set-ntp true

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
cat>/etc/pacman.d/mirrorlist << 'EOF'

#  main server
Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch
# local mirrors
Server = http://mirror.telepoint.bg/archlinux/$repo/os/$arch
Server = ftp://ftp.hosteurope.de/mirror/ftp.archlinux.org/$repo/os/$arch
EOF
fi

if [ "$AAI_SKIP_INIT" == "no" ]; then
   if [ "$(hostname)" == "archiso" ]; then
       # do not use host cache on arch iso
       pacstrap "$AAI_MNT" base base-devel
   else
       pacstrap -c "$AAI_MNT" base base-devel
   fi
fi

# sync host packages with target
rsync -a /var/cache/pacman/pkg/ "$AAI_MNT"/var/cache/pacman/pkg/

genfstab -U "$AAI_MNT" > "$AAI_MNT"/etc/fstab

# enable multilib
sed -i "/\[multilib\]/,/Include/"'s/^#//' "$AAI_MNT"/etc/pacman.conf

# set temp user pass here
NEW_PASSWORD=pass123
repopkgs=$(cat "${curp}/repo.txt" | grep  -v '^#\|^$' | tr '\n' ' ')
arch-chroot "$AAI_MNT" << EOF
set -o errexit
ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime
hwclock --systohc
# setup locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "bg_BG.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
echo "LC_COLLATE=C" >> /etc/locale.conf
echo "$AAI_HOSTNAME" > /etc/hostname
echo "127.0.1.1 ${AAI_HOSTNAME}.localdomain ${AAI_HOSTNAME}" >> /etc/hosts

# speedup AUR packages builds
sed -i 's,#MAKEFLAGS="-j2",MAKEFLAGS="-j\$(nproc)",g' /etc/makepkg.conf
sed -i "s,PKGEXT='.pkg.tar.xz',PKGEXT='.pkg.tar',g" /etc/makepkg.conf


# swap setup
echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.d/99-sysctl.conf
echo "fs.file-max=131072" >> /etc/sysctl.d/99-sysctl.conf
echo "vm.swappiness=20" >> /etc/sysctl.d/99-sysctl.conf

# disable swap for now
#fallocate -l 16G /swapfile
#chmod 600 /swapfile
#mkswap /swapfile

# pacman
pacman --noconfirm -S $repopkgs

if [ ! -d "/home/$AAI_USER" ]; then
useradd --create-home "$AAI_USER" --shell /usr/bin/zsh
groupadd sudo
usermod -aG video,audio,scanner,lp,sudo,docker $AAI_USER
fi

systemctl enable sshd.service
systemctl enable dhcpcd.service
systemctl enable bluetooth.service
systemctl enable cronie.service

mkdir -pv /work
chown $AAI_USER:$AAI_USER /work

# force sudo to use -A for the install
echo -ne '#!/usr/bin/env bash\necho '"$AAI_PASSWORD"'\n' > /usr/local/bin/spit_pass.sh && chmod +x /usr/local/bin/spit_pass.sh
echo -ne '#!/bin/bash\n SUDO_ASKPASS=/usr/local/bin/spit_pass.sh /usr/bin/sudo -A "\$@"\n' > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo

EOF

arch-chroot "$AAI_MNT" sh -c "echo \"$AAI_USER:$AAI_PASSWORD\" | chpasswd"

# sync trizen cache
[ -d "/home/$AAI_USER/.cache/trizen" ] && rsync -a /home/$AAI_USER/.cache/trizen "$AAI_MNT"/home/$AAI_USER/.cache

# setup sudoers file
cat>"$AAI_MNT"/etc/sudoers << EOF
root ALL=(ALL) ALL
 %sudo	ALL=(ALL) ALL
# start vpn without sudo password
$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start openvpn-client@swarm.service
$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start openvpn-client@work.service
$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start openvpn-client@home.service

# stop vpn without sudo password
$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop openvpn-client@swarm.service
$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop openvpn-client@work.service
$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop openvpn-client@home.service

$AAI_USER ALL=(ALL) NOPASSWD: /usr/bin/beep


Defaults insults
EOF

if [ "$AAI_INTEL_BL" == "yes" ]; then
cat> "$AAI_MNT"/etc/udev/rules.d/backlight.rules << EOF
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOF
fi

aurpkgs=$(cat "${curp}/aur.txt" | grep  -v '^#\|^$' | tr '\n' ' ')

# setup user enviroment
arch-chroot "$AAI_MNT" su -l $AAI_USER << EOF
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

# @TODO check which of these is required for ok fonts
trizen --noconfirm -S $aurpkgs

cd /work/dev/personal/i3wmonarch && ./bin/create_symlinks.sh && git submodule update --init --recursive
cd /work/dev/personal/i3wmonarch/github.com/nonpop/xkblayout-state && make
cd /work/dev/personal/i3wmonarch/github.com/powerline/fonts && ./install.sh

EOF

# ssh access
mkdir -pv "$AAI_MNT"/root/.ssh
chmod 0700 "$AAI_MNT"/root/.ssh
[ -f "$curp/root_authorized_keys"] && \
    cp "$curp/root_authorized_keys" "$AAI_MNT"/root/.ssh/authorized_keys

# TODO: $HOME/.cache seems to be owned by root
arch-chroot "$AAI_MNT" chown -Rc $AAI_USER:$AAI_USER /home/$AAI_USER

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
EOF

arch-chroot "$AAI_MNT" << EOF
grub-install --target=i386-pc "$AAI_DEVICE"
grub-mkconfig -o /boot/grub/grub.cfg
# set root password
NEW_PASSWORD="$AAI_ROOT_PASSWORD"
echo "root:\$NEW_PASSWORD" | chpasswd
echo "root pass in chroot is: \$NEW_PASSWORD"
EOF

# cleanup
rm -v "$AAI_MNT"/usr/local/bin/sudo
rm -v "$AAI_MNT"/usr/local/bin/spit_pass.sh
# revert sudo modification
sed -i 's#/usr/local/bin/sudo#/usr/bin/sudo#' "$AAI_MNT"/home/$AAI_USER/.config/trizen/trizen.conf

