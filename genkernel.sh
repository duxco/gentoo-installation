#!/usr/bin/env bash

set -euo pipefail

UNMOUNT_BOOT="false"
KERNEL_VERSION="$(readlink /usr/src/linux | sed 's/linux-//')"

if ! mountpoint /boot >/dev/null 2>&1; then
    mount /boot
    UNMOUNT_BOOT="true"
fi

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

if [ -f "/etc/gentoo-installation/grub_default_boot_option.conf" ]; then
    BOOT_ENTRY="$(cat "/etc/gentoo-installation/grub_default_boot_option.conf")"
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
    if [ -f "/etc/gentoo-installation/grub_default_boot_option.conf" ]; then
        echo -e "\"/etc/gentoo-installation/grub_default_boot_option.conf\" misconfigured! Aborting...\n"
    else
        echo -e "Invalid choice! Aborting...\n"
    fi
    exit 1
fi

genkernel --initramfs-overlay="/key" --menuconfig all

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

GRUB_CONFIG="$(grub-mkconfig 2>/dev/null | sed -n '/^### BEGIN \/etc\/grub.d\/10_linux ###$/,/^### END \/etc\/grub.d\/10_linux ###$/p' | sed -n '/^submenu/,/^}$/p' | sed '1d;$d' | sed 's/^\t//' | sed -e "s/\$menuentry_id_option/--unrestricted --id/" | sed '/^[[:space:]]*else/,/^[[:space:]]*fi/d' | grep -v -e "^[[:space:]]*if" -e "^[[:space:]]*fi" -e "^[[:space:]]*load_video" -e "^[[:space:]]*insmod")"
GRUB_LOCAL_CONFIG="$(sed -n "/^menuentry.*${KERNEL_VERSION}-x86_64'/,/^}$/p" <<<"${GRUB_CONFIG}")"

grep -Po "^UUID=[0-9A-F]{4}-[0-9A-F]{4}[[:space:]]+/\Kefi[a-z](?=[[:space:]]+vfat[[:space:]]+)" /etc/fstab | while read -r I; do
    UUID="$(grep -Po "(?<=^UUID=)[0-9A-F]{4}-[0-9A-F]{4}(?=[[:space:]]+/${I}[[:space:]]+vfat[[:space:]]+)" /etc/fstab)"
    GRUB_SSH_CONFIG="$(sed -n "/^menuentry.*${KERNEL_VERSION}-x86_64-ssh'/,/^}$/p" <<<"${GRUB_CONFIG}" | grep -v -e "^[[:space:]]*cryptomount[[:space:]]" -e "^[[:space:]]*set[[:space:]]*root=" | sed -e "s/^[[:space:]]*search[[:space:]]*\(.*\)/\tsearch --no-floppy --fs-uuid --set=root ${UUID}/" -e "s|^\([[:space:]]*\)linux[[:space:]]\(.*\)$|\1linux \2 $(cat /etc/gentoo-installation/systemrescuecd_dosshd.conf)|" -e 's/root_key=key//' -e 's/swap_key=key//')"

    if [[ ${BOOT_ENTRY} -ne 3 ]]; then
        echo -e "set default=${BOOT_ENTRY}\nset timeout=5\n" > "/boot/grub_${I}.cfg"
    elif [ -f "/boot/grub_${I}.cfg" ]; then
        rm -f "/boot/grub_${I}.cfg"
    fi

    cat <<EOF >> "/boot/grub_${I}.cfg"
${GRUB_SSH_CONFIG}

${GRUB_LOCAL_CONFIG}

$(grep -A999 "^menuentry" /etc/grub.d/40_custom)
EOF
done

echo -e "\n\033[1;32mSign these files:\033[0m"
ls -1 /boot/{grub_efi[a-z].cfg,System.map-"${KERNEL_VERSION}"-x86_64{,-ssh},initramfs-"${KERNEL_VERSION}"-x86_64{,-ssh}.img,vmlinuz-"${KERNEL_VERSION}"-x86_64{,-ssh}}

if ls -1 /boot/*"${KERNEL_VERSION}"*.old >/dev/null 2>&1; then
    echo -e "\n\033[1;31mEither delete OR
sign old files to keep files for backup purposes while
preventing \"boot2efi.sh\" from throwing an alarm:\033[0m"
    ls -1 /boot/*"${KERNEL_VERSION}"*.old
fi

if [ "${UNMOUNT_BOOT}" == "true" ]; then
    umount /boot
fi

if [ ! -f "/etc/gentoo-installation/grub_default_boot_option.conf" ]; then
    cat <<EOF

You can persist your choice made in GRUB's boot menu
by storing your selection in the configuration file, e.g.:
echo ${BOOT_ENTRY} > /etc/gentoo-installation/grub_default_boot_option.conf
EOF
fi
