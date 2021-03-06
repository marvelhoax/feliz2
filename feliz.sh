#!/bin/bash

# The Feliz2 installation scripts for Arch Linux
# Developed by Elizabeth Mills
# With acknowlegements to Carl Duff and Dylan Schacht
# Revision date: 22nd May 2017

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful, but
#      WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#            General Public License for more details.

# A copy of the GNU General Public License is available from the Feliz2
#        page at http://sourceforge.net/projects/feliz2/files
#        or https://github.com/angeltoast/feliz2, or write to:
#                 The Free Software Foundation, Inc.
#                  51 Franklin Street, Fifth Floor
#                    Boston, MA 02110-1301 USA

# Main module

# Include source files
#
source f-vars.sh     # Most variables and arrays are declared here
source f-set.sh      # Functions to set variables used during installation
source listgen.sh    # Menuing functions
source f-part1.sh    # Functions concerned with allocating partitions
source f-part2.sh    # Guided partitioning for BIOS & EFI systems
source f-run.sh      # Functions called during installation

# ...............................................................................
#                                   Settings phase                              .
# ...............................................................................

StartTime=$(date +%s)
echo "${StartTime}" >> feliz.log

SetLanguage                            # Use appropriate language file

timedatectl set-ntp true

# Localisation
SetTimeZone                            # ZONE and SUBZONE eg: Europe/London
setlocale                              # CountryLocale eg: en_GB.UTF-8
getkeymap                              # Select keyboard layout eg: uk
SetHostname

Options                                # Added 22 May 2017

if [ $Scope != "Basic" ]; then         # If any extra apps have been added

  if [ -n "$DesktopEnvironment" ]; then
    ChooseDM
  fi

  UserName                             # Enter name of primary user

  # Check if running in Virtualbox, and offer to include guest utilities
  if (ls -l /dev/disk/by-id | grep "VBOX" &> /dev/null); then
    ConfirmVbox
  else
    IsInVbox=""
  fi

fi

if [ $fob != "Y" ]; then               # Not called if FelizOB system
  FinalCheck                           # Allow user to change any variables
fi

TestUEFI                               # Check if on UEFI system

CheckParts                             # Check partition table & offer options

if [ $AutoPart -eq 0 ]; then

  BuildPartitionLists                  # Prepare table of available partitions
  AllocateRoot                         # Allow user to select root partition

  if [ -n "${PartitionList}" ]; then   # If there are unallocated partitions
    AllocateSwap                       # Display display them for user to choose swap
  else                                 # If there is no partition for swap
    NoPartitions                       # Inform user and allow swapfile
  fi

  if [ -n "${PartitionList}" ]; then   # Check contents of PartitionList again
    MorePartitions                     # Allow user to allocate any remaining partitions
  fi

fi

SetKernel                              # Select kernel and device for Grub

if [ ${UEFI} -eq 1 ]; then             # If installing in EFI
  GrubDevice="EFI"                     # Set variable
elif [ ${AutoPart} -eq 0 ]; then       # If BIOS and not auto-artition
  SetGrubDevice                        # User chooses grub partition
fi

print_heading
TPecho "Preparations complete"
TPecho "Entering automatic installation phase"
Echo
PrintOne "sudo make me a sandwich && a cup of coffee"
Echo

# ...............................................................................
#          Installation phase - no further user intervention from here          .
# ...............................................................................

MountPartitions

ReflectorMirrorList

InstallKernel

TPecho "Preparing local services" ""

echo ${HostName} > /mnt/etc/hostname 2>> feliz.log
sed -i "/127.0.0.1/s/$/ ${HostName}/" /mnt/etc/hosts 2>> feliz.log
sed -i "/::1/s/$/ ${HostName}/" /mnt/etc/hosts 2>> feliz.log

# Set up locale, etc
  echo "${CountryLocale} UTF-8" > /mnt/etc/locale.gen 2>> feliz.log # eg: en_US.UTF-8 UTF-8
  arch_chroot "locale-gen"
  echo "LANG=${CountryLocale}" > /mnt/etc/locale.conf 2>> feliz.log # eg: LANG=en_US.UTF-8
  export "LANG=${CountryLocale}" 2>> feliz.log                      # eg: LANG=en_US.UTF-8
  arch_chroot "ln -sf /usr/share/zoneinfo/${ZONE}/${SUBZONE} /etc/localtime"
  arch_chroot "hwclock --systohc --utc"

# Networking
  if [ $Scope != "Basic" ]; then
    arch_chroot "systemctl enable dhcpcd.service"
    pacstrap /mnt networkmanager network-manager-applet rp-pppoe 2>> feliz.log
    arch_chroot "systemctl enable NetworkManager.service && systemctl enable NetworkManager-dispatcher.service"
  fi

# Grub
  TPecho "Installing Grub" ""
  if [ ${GrubDevice} = "EFI" ]; then               # Installing in UEFI environment
    pacstrap /mnt grub efibootmgr
    arch_chroot "grub-install --efi-directory=/boot --target=x86_64-efi --bootloader-id=boot"
    if [ ${IsInVbox} = "VirtualBox" ]; then        # If in Virtualbox
      mv /mnt/boot/EFI/boot/grubx64.efi /mnt/boot/EFI/boot/bootx64.efi
    fi
    arch_chroot "os-prober"
    arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
  elif [ ${GrubDevice} ]; then                     # Installing in BIOS environment
    pacstrap /mnt grub 2>> feliz.log
    arch_chroot "grub-install --target=i386-pc --recheck ${GrubDevice}"
    arch_chroot "os-prober"
    arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
  else                                             # No grub device selected
    echo "Not installing Grub" >> feliz.log
  fi

# Generate fstab and set up swapfile
  genfstab -p -U /mnt > /mnt/etc/fstab 2>> feliz.log
  if [ ${SwapFile} ]; then
    fallocate -l ${SwapFile} /mnt/swapfile 2>> feliz.log
    chmod 600 /mnt/swapfile 2>> feliz.log
    mkswap /mnt/swapfile 2>> feliz.log
    swapon /mnt/swapfile 2>> feliz.log
    echo "/swapfile none  swap  defaults  0 0" >> /mnt/etc/fstab 2>> feliz.log
  fi

# Set keyboard to selected language at next startup
  echo KEYMAP=${Countrykbd} > /mnt/etc/vconsole.conf 2>> feliz.log

# Extra processes for desktop installation
  if [ $Scope != "Basic" ]; then

    AddCodecs # Various bits

    if [ ${IsInVbox} = "VirtualBox" ]; then                  # If in Virtualbox
      TPecho "Installing virtualbox guest modules"
      case $Kernel in
      1) pacstrap /mnt dkms linux-lts-headers 2>> feliz.log # LTS kernel
        pacstrap /mnt virtualbox-guest-dkms 2>> feliz.log
      ;;
      *) pacstrap /mnt dkms linux-headers 2>> feliz.log     # Latest kernel
        pacstrap /mnt virtualbox-guest-modules-arch 2>> feliz.log
      esac
      pacstrap /mnt virtualbox-guest-utils 2>> feliz.log
      arch-chroot /mnt systemctl enable vboxservice
    fi

    InstallLuxuries # Install DEs, WMs and DMs

    UserAdd

  fi

EndTime=$(date +%s)
Difference=$(( EndTime-StartTime ))
DIFFMIN=$(( Difference / 60 ))
DIFFSEC=$(( Difference % 60 ))

SetRootPassword

if [ $Scope != "Basic" ]; then
  SetUserPassword
fi

cp feliz.log ltsgroup.txt /mnt/etc # Copy installation log for reference
print_heading
Echo
PrintOne "Congratulations, installation is complete"
Echo
Restart     # Function with options to shutdown or reboot
