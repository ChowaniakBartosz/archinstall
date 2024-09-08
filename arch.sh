#!/bin/bash

# Install dialog if not available
if ! command -v dialog &> /dev/null
then
    pacman -Sy --noconfirm dialog
fi

# Refresh keyrings
pacman -Sy --noconfirm archlinux-keyring

# Get all inputs upfront
USERNAME=$(dialog --stdout --inputbox "Enter the username:" 8 40)
if [ -z "$USERNAME" ]; then
    dialog --msgbox "No username provided. Exiting..." 10 30
    clear
    exit 1
fi

HOSTNAME=$(dialog --stdout --inputbox "Enter the hostname:" 8 40 "desktop")
if [ -z "$HOSTNAME" ]; then
    dialog --msgbox "No hostname provided. Exiting..." 10 30
    clear
    exit 1
fi

ROOT_PASSWORD=$(dialog --stdout --passwordbox "Enter the root password:" 8 40)
if [ -z "$ROOT_PASSWORD" ]; then
    dialog --msgbox "No root password provided. Exiting..." 10 30
    clear
    exit 1
fi

USER_PASSWORD=$(dialog --stdout --passwordbox "Enter the password for user $USERNAME:" 8 40)
if [ -z "$USER_PASSWORD" ]; then
    dialog --msgbox "No user password provided. Exiting..." 10 30
    clear
    exit 1
fi

# Disk selection using dialog
DISK=$(dialog --stdout --menu "Select the drive to install Arch Linux" 0 0 0 $(lsblk -d -n -o NAME,SIZE | awk '{print "/dev/" $1, $2}'))
if [ -z "$DISK" ]; then
    dialog --msgbox "No disk selected. Exiting..." 10 30
    clear
    exit 1
fi

# Ask for installation mode
INSTALL_MODE=$(dialog --stdout --menu "Select installation mode" 0 0 0 \
    1 "BIOS (MBR)" \
    2 "UEFI (GPT)")
if [ -z "$INSTALL_MODE" ]; then
    dialog --msgbox "No installation mode selected. Exiting..." 10 30
    clear
    exit 1
fi

# Ask for LVM sizes upfront
SWAP_SIZE=$(dialog --stdout --inputbox "Enter the swap size in GB:" 8 40 20)
if [ -z "$SWAP_SIZE" ]; then
    dialog --msgbox "No swap size provided. Exiting..." 10 30
    clear
    exit 1
fi

ROOT_SIZE=$(dialog --stdout --inputbox "Enter the root size in GB:" 8 40 60)
if [ -z "$ROOT_SIZE" ]; then
    dialog --msgbox "No root size provided. Exiting..." 10 30
    clear
    exit 1
fi

# Partition the selected disk based on installation mode
if [ "$INSTALL_MODE" -eq 1 ]; then
    # BIOS (MBR) mode
    dialog --infobox "Partitioning the disk in BIOS (MBR) mode: $DISK" 4 40
    parted -s "$DISK" mklabel msdos
    parted -s -a optimal "$DISK" mkpart primary fat16 0% 1024MiB
    parted -s "$DISK" set 1 boot on
    parted -s -a optimal "$DISK" mkpart primary ext4 1024MiB 100%
    parted -s "$DISK" set 2 lvm on
elif [ "$INSTALL_MODE" -eq 2 ]; then
    # UEFI (GPT) mode
    dialog --infobox "Partitioning the disk in UEFI (GPT) mode: $DISK" 4 40
    parted -s "$DISK" mklabel gpt
    parted -s -a optimal "$DISK" mkpart primary fat32 0% 1042MiB
    parted -s "$DISK" set 1 boot on
    parted -s -a optimal "$DISK" mkpart primary ext4 1024MiB 100%
    parted -s "$DISK" set 2 lvm on
fi

# Setup encryption and LVM
dialog --infobox "Setting up encryption and LVM" 4 40
cryptsetup luksFormat "${DISK}2"
cryptsetup luksOpen "${DISK}2" lvm-system

pvcreate /dev/mapper/lvm-system
vgcreate system /dev/mapper/lvm-system

# Create LVM volumes
dialog --infobox "Creating LVM volumes" 4 40
lvcreate --contiguous y --size "${SWAP_SIZE}G" system --name swap
lvcreate --contiguous y --size "${ROOT_SIZE}G" system --name root
lvcreate --contiguous y --extents +100%FREE system --name home

# Formatting partitions
dialog --infobox "Formatting partitions" 4 40
mkfs.fat -n BOOT "${DISK}1"
mkswap -L SWAP /dev/system/swap
mkfs.ext4 -L ROOT /dev/system/root
mkfs.ext4 -L HOME /dev/system/home

# Mounting partitions
dialog --infobox "Mounting partitions" 4 40
swapon /dev/system/swap
mount /dev/system/root /mnt
mkdir /mnt/boot /mnt/home
mount "${DISK}1" /mnt/boot
mount /dev/system/home /mnt/home

# Install base system
dialog --infobox "Installing base system" 4 40
pacstrap /mnt base base-devel linux linux-firmware linux-headers neovim

# Detect CPU and install appropriate microcode package
CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    dialog --infobox "Detected Intel CPU. Installing intel-ucode." 4 40
    arch-chroot /mnt pacman -S --noconfirm intel-ucode
elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    dialog --infobox "Detected AMD CPU. Installing amd-ucode." 4 40
    arch-chroot /mnt pacman -S --noconfirm amd-ucode
else
    dialog --msgbox "Unknown CPU vendor. No microcode installed." 10 30
fi

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt <<EOF
# Set timezone
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
hwclock --systohc

# Set locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/#pl_PL.UTF-8 UTF-8/pl_PL.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Configure keymap and font
echo "KEYMAP=pl" > /etc/vconsole.conf
echo "FONT=Lat2-Terminus16" >> /etc/vconsole.conf
echo "FONT_MAP=8859-2" >> /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
cat <<EOL > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.0.1 $HOSTNAME.localdomain $HOSTNAME
EOL

# Install and enable NetworkManager
pacman -S networkmanager --noconfirm
systemctl enable NetworkManager

# Set root password
echo "root:$ROOT_PASSWORD" | chpasswd

# Add new user
useradd -mG wheel $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Install and configure GRUB
pacman -S grub dosfstools mtools --noconfirm
if [ "$INSTALL_MODE" -eq 1 ]; then
    # BIOS (MBR) mode
    grub-install $DISK
elif [ "$INSTALL_MODE" -eq 2 ]; then
    # UEFI (GPT) mode
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
fi

blkid -s UUID -o value ${DISK}2 > /etc/default/grub
blkid -s UUID -o value /dev/system/swap >> /etc/default/grub

# Enable cryptodisk in GRUB and configure boot options
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=$(blkid -s UUID -o value ${DISK}2):lvm-system:allow-discards resume=UUID=$(blkid -s UUID -o value /dev/system/swap) quiet"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Install minimal KDE Plasma and essential packages
pacman -S xorg sddm plasma dolphin konsole ark kate --noconfirm

# Enable SDDM (display manager for KDE)
systemctl enable sddm

EOF

# Final message
dialog --msgbox "Arch Linux installation with minimal KDE Plasma is complete!" 10 30

# Clear dialog interface
clear
