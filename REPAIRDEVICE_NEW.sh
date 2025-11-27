#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# A collection of functions to repair and modify a Steam Deck installation.
# This makes a number of assumptions about the target device and will be
# destructive if you have modified the expected partition layout.
#

set -eu

die() { echo >&2 "!! $*"; exit 1; }
readvar() { IFS= read -r -d '' "$1" || true; }
select_disk() {
    # Exemplo de uso:
        #select_disk
        #echo "Selected disk: /dev/$DISK"
        #echo "Partition suffix: $DISK_SUFFIX"
    # Funções internas para listar discos
    list_nvme_disks() { ls /sys/block | grep '^nvme' 2>/dev/null; }
    list_sata_disks() { ls /sys/block | grep '^sd' 2>/dev/null; }

    # Passo 1: escolher tipo de dispositivo
    local device_type
    device_type=$(zenity --list --title="Select Device Type" \
                         --column="Type" "NVMe" "SATA" \
                         --height=200 --width=250)
    [[ -n "$device_type" ]] || { echo "No device type selected. Exiting."; exit 1; }

    # Passo 2: listar discos do tipo escolhido
    local disks=()
    if [[ "$device_type" == "NVMe" ]]; then
        disks=($(list_nvme_disks))
    elif [[ "$device_type" == "SATA" ]]; then
        disks=($(list_sata_disks))
    fi

    [[ ${#disks[@]} -gt 0 ]] || { echo "No disks of type $device_type found. Exiting."; exit 1; }

    # Passo 3: selecionar o disco
    local selected_disk
    selected_disk=$(zenity --list --title="Select Disk" --column="Disk" "${disks[@]}" \
                           --height=300 --width=300)
    [[ -n "$selected_disk" ]] || { echo "No disk selected. Exiting."; exit 1; }

    # Passo 4: definir variáveis globais
    DISK="/dev/$selected_disk"
    if [[ "$device_type" == "NVMe" ]]; then
        DISK_SUFFIX="p"
    else
        DISK_SUFFIX=""
    fi
}
DOPARTVERIFY=1

# If this exists, use the jupiter-biosupdate binary from this directory, and set JUPITER_BIOS_DIR to this directory when
# invoking it.  Used for including a newer bios payload than the base image.
VENDORED_BIOS_UPDATE=/home/deck/jupiter-bios
# If this exists, use the jupiter-controller-update binary from this directory, and set
# JUPITER_CONTROLLER_UPDATE_FIRMWARE_DIR to this directory when invoking it.  Used for including a newer controller
# payload than the base image.
VENDORED_CONTROLLER_UPDATE=/home/deck/jupiter-controller-fw

# Partition table, sfdisk format, %%DISKPART%% filled in
#
PART_SIZE_ESP="256"
PART_SIZE_EFI="64"
PART_SIZE_ROOT="5120" # This should match the size from the input disk build
PART_SIZE_VAR="256"
# FIXME make sure this is true
PART_SIZE_HOME="100" # For the stub .img file we're making this can be tiny, OS expands to fill physical disk on first
                     # boot.  We make sure to specify the inode ratio explicitly when formatting.

# Total size + 1MiB padding at beginning/end for GPT structures.
DISK_SIZE=$(( 2 + PART_SIZE_HOME + PART_SIZE_ESP + 2 * ( PART_SIZE_EFI + PART_SIZE_ROOT + PART_SIZE_VAR ) ))
# Alignment: Using general sizes like MiB and no explicit start offset points causes sfdisk to align to MiB boundaries
#            by default (e.g. first partition will start at 1MiB). See `man sfdisk`.

# Sector size: Most physical SSD/NVMe/etc use logical 512 sectors*. GPT partition tables aren't portable between varying
#              sector sizes, so this .img cannot be used directly on a 4k-logical-sector device (a quick search suggests
#              this is most likely with certain VM/cloud/network disks)
#

#              Since we use 1MiB alignment, it should be possible to fixup this partition table for other sector sizes
#              without physically moving any partitions at imaging time:
#
#                  dd if=output.img of=/target/disk
#
#                  # sfdisk will default to 512 for a local file, dumping the table correctly, then translate it to the
#                  # target device's sector size upon re-writing:
#
#                  sfdisk -d < output.img | sfdisk /target/disk
#
#              Alternatively, use `losetup --sector-size` to remount the image at a different size, and use the above
#              steps to regenerate the table.  If this comes up often in practice we could output a "partitions4096.gpt"
#              style file alongside the disk image that could be `dd`'d on top for weird VM setups.
#
#              *Note: logical sectors != physical sectors != optimal I/O alignment.  Logical sectors being the unit the
#               OS addresses the disk by, and what GPT tables use as their basic written-to-disk unit.  Most everything
#               is 512 or (rarely) 4096.

TARGET_SECTOR_SIZE=512 # Passed to `losetup` to emulate, affects the sector-offsets sfdisk ends up writing.
readvar PARTITION_TABLE <<END_PARTITION_TABLE
  label: gpt
  %%DISKPART%%1: name="esp",      size=         ${PART_SIZE_ESP}MiB,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  %%DISKPART%%2: name="efi-A",    size=         ${PART_SIZE_EFI}MiB,  type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  %%DISKPART%%3: name="efi-B",    size=         ${PART_SIZE_EFI}MiB,  type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  %%DISKPART%%4: name="rootfs-A", size=         ${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  %%DISKPART%%5: name="rootfs-B", size=         ${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  %%DISKPART%%6: name="var-A",    size=         ${PART_SIZE_VAR}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  %%DISKPART%%7: name="var-B",    size=         ${PART_SIZE_VAR}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  %%DISKPART%%8: name="home",     size=         ${PART_SIZE_HOME}MiB, type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
END_PARTITION_TABLE

# Partition numbers on ideal target device, by index
FS_ESP=1
FS_EFI_A=2
FS_EFI_B=3
FS_ROOT_A=4
FS_ROOT_B=5
FS_VAR_A=6
FS_VAR_B=7
FS_HOME=8

diskpart() { echo "$DISK$DISK_SUFFIX$1"; }

##
## Util colors and such
##

err() {
  echo >&2
  eerr "Imaging error occured, see above and restart process."
  sleep infinity
}
trap err ERR

_sh_c_colors=0
[[ -n $TERM && -t 1 && ${TERM,,} != dumb ]] && _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"
sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && echo -n $'\e['"${*:-0}m"; ); }

sh_quote() { echo "${@@Q}"; }
estat()    { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
emsg()     { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
ewarn()    { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
einfo()    { echo >&2 "$(sh_c 30 1)::$(sh_c) $*"; }
eerr()     { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
die() { local msg="$*"; [[ -n $msg ]] || msg="script terminated"; eerr "$msg"; exit 1; }
showcmd() { showcmd_unquoted "${@@Q}"; }
showcmd_unquoted() { echo >&2 "$(sh_c 30 1)+$(sh_c) $*"; }
cmd() { showcmd "$@"; "$@"; }

# Helper to format
fmt_ext4()  { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd sudo mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd sudo mkfs.vfat -n"$1" "$2"; }

##
## Prompt mechanics - currently using Zenity
##

# Give the user a choice between Proceed, or Cancel (which exits this script)
#  $1 Title
#  $2 Text
#
prompt_step()
{
  title="$1"
  msg="$2"
  unconditional="${3-}"
  if [[ ! ${unconditional-} && ${NOPROMPT:-} ]]; then
    echo -e "$msg"
    return 0
  fi
  zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg"
  [[ $? = 0 ]] || exit 1
}

prompt_reboot()
{
  local msg=$1
  local mode="reboot"
  [[ ${POWEROFF:-} ]] && mode="shutdown"

  prompt_step "Action Successful" "${msg}\n\nChoose Proceed to $mode the Steam Deck now, or Cancel to stay in the repair image." "${REBOOTPROMPT:-}"
  [[ $? = 0 ]] || exit 1
  if [[ ${POWEROFF:-} ]]; then
    cmd systemctl poweroff
  else
    cmd systemctl reboot
  fi
}

##
## Repair functions
##

# verify partition on target disk - at least make sure the type and partlabel match what we expect.
#   $1 device
#   $2 expected type
#   $3 expected partlabel
#
verifypart()
{
  [[ $DOPARTVERIFY = 1 ]] || return 0
  TYPE="$(blkid -o value -s TYPE "$1" )"
  PARTLABEL="$(blkid -o value -s PARTLABEL "$1" )"
  if [[ ! $TYPE = "$2" ]]; then
    eerr "Device $1 is type $TYPE but expected $2 - cannot proceed. You may try full recovery."
    sleep infinity ; exit 1
  fi

  if [[ ! $PARTLABEL = $3 ]] ; then 
    eerr "Device $1 has label $PARTLABEL but expected $3 - cannot proceed. You may try full recovery."
    sleep infinity ; exit 2
  fi
}

# Replace the device rootfs (btrfs version). Source must be frozen before calling.
#   $1 source device
#   $2 target device
#
imageroot()
{
  local srcroot="$1"
  local newroot="$2"
  # copy then randomize target UUID - careful here! Duplicating btrfs ids is a problem
  cmd dd if="$srcroot" of="$newroot" bs=128M status=progress oflag=sync
  cmd btrfstune -f -u "$newroot"
  cmd btrfs check "$newroot"
}

# Set up boot configuration in the target partition set
#   $1 partset name
finalize_part()
{
  estat "Finalizing install part $1"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- mkdir /efi/SteamOS
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- mkdir -p /esp/SteamOS/conf
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- steamos-partsets /efi/SteamOS/partsets
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- steamos-bootconf create --image "$1" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$1"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- grub-mkimage
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- update-grub
  # Galileo OS should have this embedded
   cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- bash -c "mkdir -pv /var/lib && echo main > /var/lib/steamos-branch"
}

##
## Main
##

onexit=()
exithandler() {
  for func in "${onexit[@]}"; do
    "$func"
  done
}
trap exithandler EXIT

# Check existence of target disk
#if [[ ! -e "$DISK" ]]; then
#  eerr "$DISK does not exist -- no nvme drive detected?"
#  sleep infinity
#  exit 1
#fi

# Reinstall a fresh SteamOS copy.
#
repair_steps(){
    
  if [[ $writePartitionTable = 1 ]]; then
    estat "Write known partition table"
    echo "$PARTITION_TABLE" | sfdisk "$DISK"

  elif [[ $writeOS = 1 || $writeHome = 1 ]]; then

    # verify some partition settings to make sure we are ok to proceed with partial repairs
    # in the case we just wrote the partition table, we know we are good and the partitions
    # are unlabelled anyway
    verifypart "$(diskpart $FS_ESP)" vfat esp
    verifypart "$(diskpart $FS_EFI_A)" vfat efi-A
    verifypart "$(diskpart $FS_EFI_B)" vfat efi-B
    verifypart "$(diskpart $FS_VAR_A)" ext4 var-A
    verifypart "$(diskpart $FS_VAR_B)" ext4 var-B
    verifypart "$(diskpart $FS_HOME)" ext4 home
  fi

  # clear the var partition (user data), but also if we are reinstalling the OS
  # a fresh system partition has problems with overlay otherwise
  if [[ $writeOS = 1 || $writeHome = 1 ]]; then
    estat "Creating var partitions"
    fmt_ext4  var  "$(diskpart $FS_VAR_A)"
    fmt_ext4  var  "$(diskpart $FS_VAR_B)"
  fi

  # Create boot partitions
  if [[ $writeOS = 1 ]]; then
    # Set up ESP/EFI boot partitions
    estat "Creating boot partitions"
    fmt_fat32 esp  "$(diskpart $FS_ESP)"
    fmt_fat32 efi  "$(diskpart $FS_EFI_A)"
    fmt_fat32 efi  "$(diskpart $FS_EFI_B)"
  fi

  if [[ $writeHome = 1 ]]; then
    estat "Creating home partition..."
    cmd sudo mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart $FS_HOME)"
    estat "Remove the reserved blocks on the home partition..."
    tune2fs -m 0 "$(diskpart $FS_HOME)"
  fi

  # Stage a BIOS update for next reboot if updating OS. OOBE images like this one don't auto-update the bios on boot.
  if [[ $writeOS = 1 ]]; then
    estat "Staging a BIOS update for next boot if necessary"
    # If we included a VENDORED_BIOS_UPDATE directory above, use the newer payload there and point JUPITER_BIOS_DIR to
    # it.  Directory should contain both a newer tool and newer firmware.
    biostool=/usr/bin/jupiter-biosupdate
    if [[ -n $VENDORED_BIOS_UPDATE && -d $VENDORED_BIOS_UPDATE ]]; then
      biostool="$VENDORED_BIOS_UPDATE"/jupiter-biosupdate
      export JUPITER_BIOS_DIR="$VENDORED_BIOS_UPDATE"
    fi

    # This is cursed, but, we want to stage the capsule in the onboard nvme, which we are booting next
    fix_esp() {
      if [[ -n $mounted_esp ]]; then
        cmd umount -l /esp
        cmd umount -l /boot/efi
        mounted_esp=
      fi
    }
    onexit+=(fix_esp)
    einfo "Mounting new ESP/EFI on /esp /boot/efi for BIOS staging"
    cmd mount "$(diskpart $FS_ESP)" /esp
    cmd mount "$(diskpart $FS_EFI_A)" /boot/efi
    mounted_esp=1

    if [[ ${FORCEBIOS:-} ]]; then
      "$biostool" --force || "$biostool"
    else
      "$biostool"
    fi

    fix_esp
  fi

  # Perform a controller update if updating OS.  OOBE images like this one don't auto-update controllers on boot.
  if [[ $writeOS = 1 ]]; then
    estat "Updating controller firmware if necessary"
    controller_tool="/usr/bin/jupiter-controller-update"
    # If we included a VENDORED_CONTROLLER_UPDATE directory above, use the newer payload and point
    # JUPITER_CONTROLLER_UPDATE_FIRMWARE_DIR to it.  Directory should contain both a newer tool and newer firmware.
    if [[ -n $VENDORED_CONTROLLER_UPDATE && -d $VENDORED_CONTROLLER_UPDATE ]]; then
      controller_tool="$VENDORED_CONTROLLER_UPDATE"/jupiter-controller-update
      export JUPITER_CONTROLLER_UPDATE_FIRMWARE_DIR="$VENDORED_CONTROLLER_UPDATE"
    fi

    # JUPITER_CONTROLLER_UPDATE_IN_OOBE=1 "$controller_tool"
  fi

  if [[ $writeOS = 1 ]]; then
    # Find rootfs
    rootdevice="$(findmnt -n -o source / )"
    if [[ -z $rootdevice || ! -e $rootdevice ]]; then
      eerr "Could not find USB installer root -- usb hub issue?"
      sleep infinity
      exit 1
    fi

    # Freeze our rootfs
    estat "Freezing rootfs"
    unfreeze() { fsfreeze -u /; }
    onexit+=(unfreeze)
    cmd fsfreeze -f /

    estat "Imaging OS partition A"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_A)"
  
    estat "Imaging OS partition B"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_B)"
    # install nvidia drivers in both partsets A and B
    has_rtx_gpu
  
    estat "Finalizing boot configurations"
    finalize_part A
    finalize_part B
    estat "Finalizing EFI system partition"
    cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable
  fi
}

# Verifica se existe alguma GPU NVIDIA RTX
has_rtx_gpu() {
    # lspci lista GPUs; grep procura NVIDIA; egrep procura RTX
    if lspci | grep -i nvidia | grep -Eiq 'rtx'; then
        echo ":: Enabling devmode so pacman can write to the rootfs"
        sudo steamos-devmode enable || true
        install_nvidia_drivers "A"
        install_nvidia_drivers "B"
        sudo steamos-devmode disable || true
        return 0  # RTX detectada
    else
        return 1  # nenhuma RTX detectada
    fi
}

install_nvidia_drivers() {
  # install nvidia drivers inside a partset (kept much of original logic)
  local part="$1"
  info "Installing Nvidia drivers inside partset $part"
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$part" -- bash -e <<'CHROOT_EOF' || true
set -euo pipefail

echo "[NVIDIA] Attempting to initialize keyring and refresh packages"

if command -v pacman-key >/dev/null 2>&1; then
  pacman-key --init 2>/dev/null || true
  pacman-key --populate archlinux 2>/dev/null || true
fi

# --- BLOCO SUBSTITUÍDO (pacman) ---
if command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm || true
  pacman -S --noconfirm nvidia-dkms nvidia-utils linux-headers lib32-nvidia-utils || true
fi
# --- FIM DO BLOCO ---

# blacklist nouveau
cat > /etc/modprobe.d/disable-nouveau.conf <<'DISABLE_NOUVEAU'
# Disable nouveau for proprietary Nvidia driver
blacklist nouveau
options nouveau modeset=0
DISABLE_NOUVEAU

# Ensure nvidia_drm.modeset=1 in grub
if [[ -f /etc/default/grub ]]; then
  if ! grep -q 'nvidia_drm.modeset=1' /etc/default/grub; then
    sed -i '1s/^/GRUB_CMDLINE_LINUX="nvidia_drm.modeset=1" \n/' /etc/default/grub || true
  fi
fi

if command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P || true
fi

cat > /etc/modprobe.d/nvidia-modeset.conf <<'NMOD'
options nvidia-drm modeset=1
NMOD

if command -v update-grub >/dev/null 2>&1; then
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

echo "[NVIDIA] Done"
CHROOT_EOF
}

# drop into the primary OS partset on the Deck
#
chroot_primary()
{
  partset=$( steamos-chroot --no-overlay --disk "$DISK" --partset "A" -- steamos-bootconf selected-image )

  estat "Dropping into a chroot on the $partset partition set."
  estat "You can make any needed changes here, and exit when done."

  # FIXME etc overlay dir might not exist on a fresh install and this will fail

  cmd steamos-chroot --disk "$DISK" --partset "$partset"
}

# return sanitize state (and echo the current percentage complete)
# 0 : ready to sanitize
# 1 : sanitize in progress (echo the current percentage)
# 2 : drive does not support sanitize
#
get_sanitize_progress() {
  # return sanitize state (and echo the current percentage complete)
    # 0 : ready to sanitize
    # 1 : sanitize in progress (echo the current percentage)
    # 2 : drive does not support sanitize
  #CALL
    #get_sanitize_progress "/dev/nvme0n1"
    #get_sanitize_progress "/dev/sda"
  # Verifica se o dispositivo existe
  if [ ! -b "$DISK" ]; then
    echo "Error: $DISK is not a block device."
    return 2
  fi

  # Tenta obter o status do NVMe
  local status
  status=$(nvme sanitize-log "$DISK" 2>/dev/null | grep "(SSTAT)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2

  # Verifica se está pronto para sanitizar
  if [[ $(( status % 8 )) -ne 2 ]]; then
    return 0
  fi

  # Obtem o progresso
  local progress
  progress=$(nvme sanitize-log "$DISK" 2>/dev/null | grep "(SPROG)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  echo "sanitize progress: $(( (progress * 100) / 65535 ))%"
  return 1

}

# call nvme sanitize, blockwise, and wait for it to complete.
#
sanitize_all() {
  if [ ! -b "$DISK" ]; then
    echo "Error: $DISK is not a block device."
    return 1
  fi

  echo "Detected disk: $DISK"

  if [[ "$DISK" =~ ^/dev/nvme ]]; then
    echo "Disk type: NVMe"
    # Checa progresso atual
    local sres=0
    get_sanitize_progress "$DISK" || sres=$?

    case $sres in
      0)
        echo "Starting NVMe sanitize..."
        nvme sanitize -a 2 "$DISK" || {
          echo "NVMe sanitize failed, trying NVMe secure format..."
          nvme format "$DISK" -n 1 -s 1 -r || echo "NVMe secure format failed!"
        }
        ;;
      1)
        echo "Sanitize already in progress for $DISK"
        return 0
        ;;
      2)
        echo "NVMe sanitize not supported, trying secure format..."
        nvme format "$DISK" -n 1 -s 1 -r || echo "NVMe secure format failed!"
        ;;
      *)
        echo "Unexpected sanitize-log result for $DISK"
        return $sres
        ;;
    esac

    # Espera término
    while ! get_sanitize_progress "$DISK"; do
      sleep 5
    done
    echo "... NVMe sanitize done."

  else
    echo "Disk type: SATA/SSD"
    # Primeiro tenta hdparm secure erase se suportado
    if command -v hdparm >/dev/null 2>&1; then
      # Verifica se suporta security erase
      if hdparm -I "$DISK" | grep -q 'supported'; then
        echo "Using hdparm security-erase..."
        # Desbloqueia se necessário
        sudo hdparm --user-master u --security-unlock NULL "$DISK" || true
        sudo hdparm --user-master u --security-erase NULL "$DISK"
        echo "... SATA secure erase done."
        return 0
      fi
    fi

    # Fallback: destrói todo o conteúdo com blkdiscard (rápido) ou dd (seguro)
    if command -v blkdiscard >/dev/null 2>&1; then
      echo "Using blkdiscard to wipe $DISK..."
      sudo blkdiscard "$DISK" -f
    else
      echo "Using dd to zero-fill $DISK (this may take a long time)..."
      sudo dd if=/dev/zero of="$DISK" bs=128M status=progress || true
    fi
    echo "... SATA/SSD sanitize done."
  fi
}


# print quick list of targets
#
help()
{
  readvar HELPMSG << EOD
This tool can be used to reinstall or repair your SteamOS installation on a Steam Deck.

Possible targets:
    all : permanently destroy all data on your Steam Deck, and reinstall SteamOS.
    system : reinstall SteamOS on the Steam Deck system partitions.
    home : remove games and personalization from the Steam Deck.
    chroot : chroot to the primary SteamOS partition set.
    sanitize : perform an NVME sanitize operation.
EOD
  emsg "$HELPMSG"
  if [[ "$EUID" -ne 0 ]]; then
    eerr "Please run as root."
    exit 1
  fi
}

[[ "$EUID" -ne 0 ]] && help

writePartitionTable=0
writeOS=0
writeHome=0

case "${1-help}" in
all)
  prompt_step "Reimage Steam Deck" "This action will reimage the Steam Deck.\nThis will permanently destroy all data on your Steam Deck and reinstall SteamOS.\n\nThis cannot be undone.\n\nChoose Proceed only if you wish to clear and reimage this device."
  select_disk
  sanitize_all
  writePartitionTable=1
  writeOS=1
  writeHome=1
  repair_steps
  prompt_reboot "Reimaging complete."
  ;;
system)
  prompt_step "Reinstall SteamOS" "This action will reinstall SteamOS on the Steam Deck, while attempting to preserve your games and personal content.\nSystem customizations may be lost.\n\nChoose Proceed to reinstall SteamOS on your device."
  writeOS=1
  repair_steps
  prompt_reboot "SteamOS reinstall complete."
  ;;
home)
  prompt_step "Delete local user data" "This action will reformat the home partitions on your Steam Deck.\nThis will destroy downloaded games and all personal content stored on the Deck, including system configuration.\n\nThis action cannot be undone.\n\nChoose Proceed to reformat all user home partitions."
  writeHome=1
  repair_steps
  prompt_reboot "User partitions have been reformatted."
  ;;
chroot)
  chroot_primary
  ;;
sanitize)
  prompt_step "Clear and sanitize NVME disk" "This action will kick off an NVME sanitize on the Steam Deck, irrevocably deleting all user data.\n\nThis action cannot be undone.\n\nChoose Proceed only if you want to remove all data from the attached Steam Deck primary drive."
  sanitize_all
  ;;
*)
  help
  ;;
esac 

