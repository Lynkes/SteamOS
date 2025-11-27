#!/bin/bash
# Steam Deck Repair and Reinstallation Script (Refactored)
# --------------------------------------------------------
# This script contains repair and recovery utilities for SteamOS on the Steam Deck.
# It assumes the expected partition layout and may destroy data.

set -euo pipefail

########################################
## Utility Functions
########################################

die() {
  echo >&2 "!! $*"; exit 1;
}

readvar() { IFS= read -r -d '' "$1" || true; }

diskpart() { echo "${DISK}${DISK_SUFFIX}$1"; }

errexit() {
  echo >&2
  eerr "An error occurred. See above logs.";
  sleep infinity;
}
trap errexit ERR

########################################
## Disk + Partition Configuration
########################################

DISK="/dev/nvme0n1"
DISK_SUFFIX="p"
DOPARTVERIFY=1

VENDORED_BIOS_UPDATE="/home/deck/jupiter-bios"
VENDORED_CONTROLLER_UPDATE="/home/deck/jupiter-controller-fw"

PART_SIZE_ESP="256"
PART_SIZE_EFI="64"
PART_SIZE_ROOT="5120"
PART_SIZE_VAR="256"
PART_SIZE_HOME="100"

DISK_SIZE=$(( 2 + PART_SIZE_HOME + PART_SIZE_ESP + 2 * ( PART_SIZE_EFI + PART_SIZE_ROOT + PART_SIZE_VAR ) ))
TARGET_SECTOR_SIZE=512

readvar PARTITION_TABLE <<EOF
  label: gpt
  %%DISKPART%%1: name="esp",      size=${PART_SIZE_ESP}MiB,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  %%DISKPART%%2: name="efi-A",    size=${PART_SIZE_EFI}MiB,  type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  %%DISKPART%%3: name="efi-B",    size=${PART_SIZE_EFI}MiB,  type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  %%DISKPART%%4: name="rootfs-A", size=${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  %%DISKPART%%5: name="rootfs-B", size=${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  %%DISKPART%%6: name="var-A",    size=${PART_SIZE_VAR}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  %%DISKPART%%7: name="var-B",    size=${PART_SIZE_VAR}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  %%DISKPART%%8: name="home",     size=${PART_SIZE_HOME}MiB, type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
EOF

FS_ESP=1
FS_EFI_A=2
FS_EFI_B=3
FS_ROOT_A=4
FS_ROOT_B=5
FS_VAR_A=6
FS_VAR_B=7
FS_HOME=8

########################################
## Logging + Presentation Helpers
########################################

_sh_c_colors=0
[[ -n ${TERM:-} && -t 1 && ${TERM,,} != dumb ]] && _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"

sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && echo -n $'\e['"${*:-0}m" ); }
sh_quote() { echo "${@@Q}"; }
estat()  { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
emsg()   { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
ewarn()  { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
einfo()  { echo >&2 "$(sh_c 30 1)::$(sh_c) $*"; }
eerr()   { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
showcmd() { echo >&2 "$(sh_c 30 1)+$(sh_c) ${@@Q}"; }
cmd() { showcmd "$@"; "$@"; }

fmt_ext4()  { cmd sudo mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { cmd sudo mkfs.vfat -n"$1" "$2"; }

########################################
## Zenity Prompts
########################################

prompt_step() {
  local title="$1" msg="$2" unconditional="${3-}"
  if [[ ! ${unconditional-} && ${NOPROMPT:-} ]]; then
    echo -e "$msg"; return 0
  fi

  zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg"
}

prompt_reboot() {
  local msg="$1"
  local mode="reboot"
  [[ ${POWEROFF:-} ]] && mode="shutdown"

  prompt_step "Action Successful" "${msg}\n\nChoose Proceed to $mode now, or Cancel to stay in the repair image." "${REBOOTPROMPT:-}" || exit 1

  if [[ ${POWEROFF:-} ]]; then
    cmd systemctl poweroff
  else
    cmd systemctl reboot
  fi
}

########################################
## Partition Validation
########################################

verifypart() {
  local dev="$1" exp_type="$2" exp_label="$3"

  [[ $DOPARTVERIFY = 1 ]] || return 0

  local TYPE PARTLABEL
  TYPE="$(blkid -o value -s TYPE "$dev" )"
  PARTLABEL="$(blkid -o value -s PARTLABEL "$dev" )"

  [[ "$TYPE" == "$exp_type" ]] || die "Partition $dev type mismatch: found $TYPE, expected $exp_type"
  [[ "$PARTLABEL" == "$exp_label" ]] || die "Partition $dev label mismatch: found $PARTLABEL, expected $exp_label"
}

########################################
## Imaging + Boot Finalization
########################################

imageroot() {
  local src="$1" tgt="$2"
  cmd dd if="$src" of="$tgt" bs=128M status=progress oflag=sync
  cmd btrfstune -f -u "$tgt"
  cmd btrfs check "$tgt"
}

finalize_part() {
  local partset="$1"
  estat "Finalizing install part $partset"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- mkdir -p /efi/SteamOS /esp/SteamOS/conf
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- steamos-partsets /efi/SteamOS/partsets
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- steamos-bootconf create --image "$partset" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$partset"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- grub-mkimage
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- update-grub
}

########################################
## Main Repair Logic
########################################

onexit=()
exithandler() {
  for f in "${onexit[@]}"; do "$f"; done
}
trap exithandler EXIT

repair_steps() {
  if [[ $writePartitionTable = 1 ]]; then
    estat "Writing known partition table"
    echo "$PARTITION_TABLE" | sfdisk "$DISK"

  elif [[ $writeOS = 1 || $writeHome = 1 ]]; then
    verifypart "$(diskpart $FS_ESP)"     vfat esp
    verifypart "$(diskpart $FS_EFI_A)"   vfat efi-A
    verifypart "$(diskpart $FS_EFI_B)"   vfat efi-B
    verifypart "$(diskpart $FS_VAR_A)"   ext4 var-A
    verifypart "$(diskpart $FS_VAR_B)"   ext4 var-B
    verifypart "$(diskpart $FS_HOME)"    ext4 home
  fi

  if [[ $writeOS = 1 || $writeHome = 1 ]]; then
    estat "Creating var partitions"
    fmt_ext4 var "$(diskpart $FS_VAR_A)"
    fmt_ext4 var "$(diskpart $FS_VAR_B)"
  fi

  if [[ $writeOS = 1 ]]; then
    estat "Creating boot partitions"
    fmt_fat32 esp "$(diskpart $FS_ESP)"
    fmt_fat32 efi "$(diskpart $FS_EFI_A)"
    fmt_fat32 efi "$(diskpart $FS_EFI_B)"
  fi

  if [[ $writeHome = 1 ]]; then
    estat "Creating home partition"
    cmd sudo mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart $FS_HOME)"
    tune2fs -m 0 "$(diskpart $FS_HOME)"
  fi

  if [[ $writeOS = 1 ]]; then
    estat "Staging BIOS update if necessary"
    local biostool="/usr/bin/jupiter-biosupdate"
    if [[ -d $VENDORED_BIOS_UPDATE ]]; then
      biostool="$VENDORED_BIOS_UPDATE/jupiter-biosupdate"
      export JUPITER_BIOS_DIR="$VENDORED_BIOS_UPDATE"
    fi

    fix_esp() {
      if [[ -n ${mounted_esp:-} ]]; then
        cmd umount -l /esp
        cmd umount -l /boot/efi
      fi
    }
    onexit+=(fix_esp)

    mount "$(diskpart $FS_ESP)" /esp
    mount "$(diskpart $FS_EFI_A)" /boot/efi
    mounted_esp=1

    if [[ ${FORCEBIOS:-} ]]; then "$biostool" --force || "$biostool"; else "$biostool"; fi

    fix_esp
  fi

  if [[ $writeOS = 1 ]]; then
    estat "Finding rootfs"
    local rootdevice
    rootdevice="$(findmnt -n -o source / )"
    [[ -n $rootdevice && -e $rootdevice ]] || die "Could not find USB installer root"

    estat "Freezing rootfs"
    unfreeze() { fsfreeze -u /; }
    onexit+=(unfreeze)
    cmd fsfreeze -f /

    estat "Imaging OS partition A"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_A)"

    estat "Imaging OS partition B"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_B)"

    estat "Finalizing boot configurations"
    finalize_part A
    finalize_part B

    cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable
  fi
}

########################################
## Chroot
########################################

chroot_primary() {
  local partset
  partset=$( steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamos-bootconf selected-image )
  estat "Entering chroot on partset $partset"
  cmd steamos-chroot --disk "$DISK" --partset "$partset"
}

########################################
## Sanitize NVMe
########################################

get_sanitize_progress() {
  local status progress
  status=$(nvme sanitize-log "$DISK" | grep "(SSTAT)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  (( status % 8 == 2 )) || return 0
  progress=$(nvme sanitize-log "$DISK" | grep "(SPROG)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  echo "sanitize progress: $(( progress * 100 / 65535 ))%"
  return 1
}

sanitize_all() {
  local sres=0
  get_sanitize_progress || sres=$?

  case $sres in
    0)
      echo -e "\nWARNING: This will destroy ALL user data on $DISK"
      sleep 5
      nvme sanitize -a 2 "$DISK"
      ;;
    1)
      echo "A sanitize operation is already in progress."
      ;;
    2)
      nvme format "$DISK" -n 1 -s 1 -r
      return 0
      ;;
    *) die "Unexpected sanitize-log result";;
  esac

  while ! get_sanitize_progress ; do sleep 5; done
}

########################################
## Help + CLI
########################################

help() {
  cat >&2 <<EOF
Steam Deck Repair Utility
Available commands:
  all       – full reinstall (DESTROYS ALL DATA)
  system    – reinstall SteamOS only
  home      – wipe home partition (games + user data)
  chroot    – enter SteamOS chroot
  sanitize  – trigger NVMe sanitize
EOF
  [[ "$EUID" -ne 0 ]] && die "Run as root."
}

[[ "$EUID" -ne 0 ]] && help

writePartitionTable=0
writeOS=0
writeHome=0

case "${1-help}" in
  all)
    prompt_step "Reimage Steam Deck" "This will permanently erase ALL data and reinstall SteamOS."
    writePartitionTable=1; writeOS=1; writeHome=1
    repair_steps
    prompt_reboot "Reimaging complete."
    ;;

  system)
    prompt_step "Reinstall SteamOS" "This reinstalls the system while attempting to preserve user data."
    writeOS=1
    repair_steps
    prompt_reboot "System reinstall complete."
    ;;

  home)
    prompt_step "Delete user data" "This wipes all home partitions and destroys all personal content."
    writeHome=1
    repair_steps
    prompt_reboot "User data wiped."
    ;;

  chroot)
    chroot_primary
    ;;

  sanitize)
    prompt_step "NVMe Sanitize" "This will irrevocably delete ALL data on the NVMe."
    sanitize_all
    ;;

  *) help ;;
esac

# --- Enhanced Hardware Detection (Added) ---
# Supports more handheld PCs and future models.

get_hardware_model() {
    local model

    if [[ -f /sys/firmware/devicetree/base/model ]]; then
        model=$(tr -d '