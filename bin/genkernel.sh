#!/usr/bin/env bash

# Prevent tainting variables via environment
# See: https://gist.github.com/duxsco/fad211d5828e09d0391f018834f955c9
unset BOOT_ENTRY BOOT_LUKS_DEVICE CLEAR_CCACHE CONTINUE CRYPTOMOUNT EFI_MOUNTPOINT EFI_UUID GRUB_CONFIG GRUB_LOCAL_CONFIG GRUB_SSH_CONFIG KERNEL_VERSION NUMBER_REGEX UMOUNT_BOOT UUID_BOOT_FILESYSTEM UUID_BOOT_LUKS_DEVICE

KERNEL_VERSION="$(readlink /usr/src/linux | sed 's/linux-//')"

######################
# luksOpen and mount #
######################

if  [[ -b /dev/md/boot3141592653md ]]; then
    BOOT_LUKS_DEVICE="/dev/md/boot3141592653md"
elif [[ -b /dev/disk/by-partlabel/boot3141592653part ]]; then
    BOOT_LUKS_DEVICE="/dev/disk/by-partlabel/boot3141592653part"
else
    echo 'Failed to find "/boot" LUKS device! Aborting...' >&2
    exit 1
fi

UUID_BOOT_LUKS_DEVICE="$(cryptsetup luksUUID "${BOOT_LUKS_DEVICE}" | tr -d '-')"

if [[ ! -b $(find /dev/disk/by-id -name "dm-uuid-*${UUID_BOOT_LUKS_DEVICE}*") ]]; then
    cryptsetup luksOpen --key-file /key/mnt/key/key "${BOOT_LUKS_DEVICE}" boot3141592653temp
fi

if [[ ! -b $(find /dev/disk/by-id -name "dm-uuid-*${UUID_BOOT_LUKS_DEVICE}*") ]]; then
    echo 'Failed to luksOpen "/boot" device! Aborting...' >&2
    exit 1
fi

if ! mountpoint --quiet /boot; then
    if ! mount /boot || ! mountpoint --quiet /boot; then
        echo 'Failed to mount "/boot"! Aborting...' >&2
        exit 1
    fi

    UMOUNT_BOOT="true"
fi

###################
# ccache clearing #
###################

echo ""
read -r -p "Do you want to clear ccache's cache (y/n)?
See \"Is it safe?\" at https://ccache.dev/. Your answer: " CLEAR_CCACHE
echo ""

if [[ ${CLEAR_CCACHE} =~ ^[yY]$ ]]; then
    echo "Clearing ccache's cache..."
    ccache --clear
    echo ""
elif ! [[ ${CLEAR_CCACHE} =~ ^[nN]$ ]]; then
    echo "No valid response given! Aborting..."
    exit 1
fi

######################
# default boot entry #
######################

if [[ -f /etc/gentoo-installation/grub_default_boot_option.conf ]]; then
    BOOT_ENTRY="$(</etc/gentoo-installation/grub_default_boot_option.conf)"
else
    read -r -p "Available boot options:
  0) Remote LUKS unlock via initramfs+dropbear
  1) Local LUKS unlock via TTY/IPMI
  2) SystemRescueCD
  3) Enforce manual selection upon each boot

Please, select your option [0-3]: " BOOT_ENTRY
    echo ""
fi

NUMBER_REGEX='^[0-3]$'
if ! [[ ${BOOT_ENTRY} =~ ${NUMBER_REGEX} ]]; then
    if [[ -f /etc/gentoo-installation/grub_default_boot_option.conf ]]; then
        echo -e "\"/etc/gentoo-installation/grub_default_boot_option.conf\" misconfigured! Aborting...\n"
    else
        echo -e "Invalid choice! Aborting...\n"
    fi
    exit 1
fi

###############
# local setup #
###############

genkernel --initramfs-overlay="/key" --menuconfig all

################
# remote setup #
################

echo ""
read -r -p "Do you want to continue (y/N)? " CONTINUE
echo ""

if ! [[ ${CONTINUE} =~ ^[yY]$ ]]; then
    echo "You didn't approve with \"y\". Exiting..."
    exit 0
fi

# "--menuconfig" is not used, because config
# generated by first genkernel execution in /etc/kernels is reused.
# "--initramfs-overlay" is not used, because generated "*-ssh*" files
# must be stored on a non-encrypted partition.
genkernel --initramfs-filename="initramfs-%%KV%%-ssh.img" --kernel-filename="vmlinuz-%%KV%%-ssh" --systemmap-filename="System.map-%%KV%%-ssh" --ssh all

##########
# config #
##########

GRUB_CONFIG="$(
    grub-mkconfig 2>/dev/null | \
    sed -n '/^### BEGIN \/etc\/grub.d\/10_linux ###$/,/^### END \/etc\/grub.d\/10_linux ###$/p' | \
    sed -n '/^submenu/,/^}$/p' | \
    sed '1d;$d' | \
    sed 's/^\t//' | \
    sed -e "s/\$menuentry_id_option/--unrestricted --id/" | \
    grep -v -e "^[[:space:]]*if" -e "^[[:space:]]*fi" -e "^[[:space:]]*load_video" -e "^[[:space:]]*insmod"
)"

UUID_BOOT_FILESYSTEM="$(sed -n 's#^UUID=\([^[:space:]]*\)[[:space:]]*/boot[[:space:]]*.*#\1#p' /etc/fstab)"
CRYPTOMOUNT="\tcryptomount -u ${UUID_BOOT_LUKS_DEVICE}\\
\tset root='cryptouuid/${UUID_BOOT_LUKS_DEVICE}'\\
\tsearch --no-floppy --fs-uuid --set=root --hint='cryptouuid/${UUID_BOOT_LUKS_DEVICE}' ${UUID_BOOT_FILESYSTEM}"

GRUB_LOCAL_CONFIG="$(
    sed -n "/^menuentry.*${KERNEL_VERSION}-x86_64'/,/^}$/p" <<<"${GRUB_CONFIG}" | \
    sed "s#^[[:space:]]*search[[:space:]]*.*#${CRYPTOMOUNT}#"
)"

grep -Po "^UUID=[0-9A-F]{4}-[0-9A-F]{4}[[:space:]]+/\Kefi[a-z](?=[[:space:]]+vfat[[:space:]]+)" /etc/fstab | while read -r EFI_MOUNTPOINT; do
    EFI_UUID="$(grep -Po "(?<=^UUID=)[0-9A-F]{4}-[0-9A-F]{4}(?=[[:space:]]+/${EFI_MOUNTPOINT}[[:space:]]+vfat[[:space:]]+)" /etc/fstab)"
    GRUB_SSH_CONFIG="$(
        sed -n "/^menuentry.*${KERNEL_VERSION}-x86_64-ssh'/,/^}$/p" <<<"${GRUB_CONFIG}" | \
        sed -e "s/^[[:space:]]*search[[:space:]]*\(.*\)/\tsearch --no-floppy --fs-uuid --set=root ${EFI_UUID}/" \
            -e "s|^\([[:space:]]*\)linux[[:space:]]\(.*\)$|\1linux \2 $(</etc/gentoo-installation/dosshd.conf)|" \
            -e 's/root_key=key//'
    )"

    if [[ ${BOOT_ENTRY} -ne 3 ]]; then
        echo -e "set default=${BOOT_ENTRY}\nset timeout=5\n" > "/boot/grub_${EFI_MOUNTPOINT}.cfg"
    elif [[ -f /boot/grub_${EFI_MOUNTPOINT}.cfg ]]; then
        rm -f "/boot/grub_${EFI_MOUNTPOINT}.cfg"
    fi

    cat <<EOF >> "/boot/grub_${EFI_MOUNTPOINT}.cfg"
${GRUB_SSH_CONFIG}

${GRUB_LOCAL_CONFIG}

$(grep -A999 "^menuentry" /etc/grub.d/40_custom)
EOF
done

if ls -1 /boot/*"${KERNEL_VERSION}"*.old >/dev/null 2>&1; then
    echo -e "\n\033[1;31mDelete these files if you don't want to keep them:\033[0m"
    ls -1 /boot/*"${KERNEL_VERSION}"*.old
fi

##########
# umount #
##########

if [[ -n ${UMOUNT_BOOT} ]]; then
    umount /boot
fi

if [[ ! -f /etc/gentoo-installation/grub_default_boot_option.conf ]]; then
    cat <<EOF

You can persist your choice you have to make in GRUB's boot menu
by storing your selection in the configuration file, e.g.:
echo ${BOOT_ENTRY} > /etc/gentoo-installation/grub_default_boot_option.conf
EOF
fi
