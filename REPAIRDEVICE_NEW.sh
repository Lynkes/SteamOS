#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# A collection of functions to repair and modify a Steam Deck installation,
# generalized to target any disk (NVMe / SATA / eMMC / virtio) and any PC.
# This makes a number of assumptions about the target device and will be
# destructive if you have modified the expected partition layout.
#
# Environment overrides:
#   DISK=/dev/sdX     skip the disk picker and use this disk
#   NOPROMPT=1        skip confirmation dialogs
#   POWEROFF=1        power off instead of reboot when done
#   NVIDIA=0          never install NVIDIA drivers / NVIDIA=1 force install
#

set -eu

readvar() { IFS= read -r -d '' "$1" || true; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTINSTALL_DIR="$SCRIPT_DIR/postinstall"

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
#
# Sector size: GPT tables aren't portable between logical sector sizes, but since we write the table with sfdisk
#              directly against the target disk (instead of dd'ing a prebuilt image), sfdisk translates the MiB-based
#              sizes to whatever sector size the target uses (512e or 4Kn) - one less portability problem.

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
fmt_ext4()  { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd mkfs.vfat -n"$1" "$2"; }

##
## Prompt mechanics - Zenity when a display is available, terminal fallback otherwise
##

have_gui() { command -v zenity >/dev/null 2>&1 && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; }

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
  if have_gui; then
    zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg" || exit 1
  else
    echo >&2
    emsg "== $title =="
    echo -e >&2 "$msg"
    local ans
    read -r -p "Type 'yes' to proceed, anything else cancels: " ans
    [[ ${ans,,} = yes ]] || exit 1
  fi
}

prompt_reboot()
{
  local msg=$1
  local mode="reboot"
  [[ ${POWEROFF:-} ]] && mode="shutdown"

  prompt_step "Action Successful" "${msg}\n\nChoose Proceed to $mode the device now, or Cancel to stay in the repair image." "${REBOOTPROMPT:-}"
  if [[ ${POWEROFF:-} ]]; then
    cmd systemctl poweroff
  else
    cmd systemctl reboot
  fi
}

##
## Disk selection
##

# Disco (pai) que hospeda o rootfs do instalador - nunca pode ser alvo da instalação
installer_disk()
{
  local rootsrc
  rootsrc="$(findmnt -n -o source / 2>/dev/null)" || return 0
  [[ -b $rootsrc ]] || return 0
  lsblk -n -o PKNAME "$rootsrc" 2>/dev/null | head -n1
}

# Sufixo de partição: dispositivos cujo nome termina em dígito (nvme0n1, mmcblk0)
# usam "p" antes do número da partição; os demais (sda, vda) não.
set_disk_suffix()
{
  case "$DISK" in
    *[0-9]) DISK_SUFFIX="p" ;;
    *)      DISK_SUFFIX=""  ;;
  esac
}

# Lista todos os discos utilizáveis e deixa o usuário escolher o alvo.
# Define DISK e DISK_SUFFIX. Respeita DISK=/dev/xxx vindo do ambiente.
select_disk()
{
  if [[ -n ${DISK:-} ]]; then
    [[ -b $DISK ]] || die "DISK=$DISK is not a block device"
    set_disk_suffix
    einfo "Using preselected disk $DISK"
    return 0
  fi

  local skip
  skip="$(installer_disk)"

  local -a names=() zargs=()
  local name info
  for dev in /sys/block/*; do
    name="${dev##*/}"
    case "$name" in
      nvme*n[0-9]|nvme*n[0-9][0-9]|sd*|mmcblk[0-9]*|vd*) ;;
      *) continue ;;
    esac
    [[ $name != "${skip:-}" ]] || continue
    [[ -b "/dev/$name" ]] || continue
    info="$(lsblk -dn -o SIZE,TRAN,MODEL "/dev/$name" 2>/dev/null | tr -s ' ' || true)"
    names+=("$name")
    zargs+=("$name" "${info:-?}")
  done

  [[ ${#names[@]} -gt 0 ]] || die "No candidate target disks found (installer disk is excluded)."

  local selected=""
  if have_gui; then
    selected=$(zenity --list --title="Select Target Disk" \
                      --text="All data on the selected disk will be affected.\nInstaller disk (${skip:-n/a}) is hidden." \
                      --column="Disk" --column="Size / Bus / Model" "${zargs[@]}" \
                      --height=350 --width=520) || true
  else
    emsg "Available target disks (installer disk ${skip:-n/a} excluded):"
    local i
    for i in "${!names[@]}"; do
      echo >&2 "  $((i+1))) ${names[$i]}  ($(lsblk -dn -o SIZE,TRAN,MODEL "/dev/${names[$i]}" 2>/dev/null | tr -s ' '))"
    done
    local choice
    read -r -p "Select disk [1-${#names[@]}]: " choice
    [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#names[@]} ]] || die "Invalid selection."
    selected="${names[$((choice-1))]}"
  fi

  [[ -n $selected ]] || die "No disk selected."
  DISK="/dev/$selected"
  set_disk_suffix
  estat "Selected target disk: $DISK (partition prefix: '${DISK_SUFFIX}')"
}

# Garante que o disco alvo comporta o layout
check_disk_size()
{
  local bytes needed
  bytes="$(blockdev --getsize64 "$DISK")"
  needed=$(( DISK_SIZE * 1024 * 1024 ))
  if (( bytes < needed )); then
    die "Disk $DISK is too small: $(( bytes / 1024 / 1024 ))MiB available, ${DISK_SIZE}MiB required."
  fi
}

##
## Hardware detection
##

is_steam_deck()
{
  local product
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  [[ $product = Jupiter* || $product = Galileo* ]]
}

##
## Post-install hooks
##

# Run every script in postinstall/ against a partset. Each hook decides for
# itself whether it applies (e.g. nvidia.sh checks lspci) and receives:
#   DISK, DISK_SUFFIX, PARTSET, TARGET_ROOT_DEV, PAYLOAD_DIR
#   $1 partset name
#   $2 rootfs device of that partset
run_postinstall()
{
  local partset="$1" rootdev="$2" hook
  [[ -d $POSTINSTALL_DIR ]] || return 0
  for hook in "$POSTINSTALL_DIR"/*.sh; do
    [[ -e $hook ]] || continue
    estat "Post-install hook: $(basename "$hook") (partset $partset)"
    if ! DISK="$DISK" DISK_SUFFIX="$DISK_SUFFIX" PARTSET="$partset" \
         TARGET_ROOT_DEV="$rootdev" PAYLOAD_DIR="$SCRIPT_DIR" \
         bash "$hook"; then
      ewarn "Hook $(basename "$hook") failed on partset $partset - continuing"
    fi
  done
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
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$1" -- mkdir -p /efi/SteamOS
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

# Reinstall a fresh SteamOS copy.
#
repair_steps(){

  if [[ $writePartitionTable = 1 ]]; then
    check_disk_size
    estat "Write known partition table"
    echo "$PARTITION_TABLE" | sed "s|%%DISKPART%%|${DISK}${DISK_SUFFIX}|g" | cmd sfdisk "$DISK"
    # re-read partitions before formatting them
    cmd partprobe "$DISK" || cmd blockdev --rereadpt "$DISK" || true
    cmd udevadm settle || true

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
    cmd mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart $FS_HOME)"
    estat "Remove the reserved blocks on the home partition..."
    cmd tune2fs -m 0 "$(diskpart $FS_HOME)"
  fi

  # Stage a BIOS update for next reboot if updating OS. OOBE images like this one don't auto-update the bios on boot.
  # Only meaningful on real Steam Deck hardware (Jupiter/Galileo) - skipped everywhere else.
  if [[ $writeOS = 1 ]] && is_steam_deck; then
    estat "Staging a BIOS update for next boot if necessary"
    # If we included a VENDORED_BIOS_UPDATE directory above, use the newer payload there and point JUPITER_BIOS_DIR to
    # it.  Directory should contain both a newer tool and newer firmware.
    biostool=/usr/bin/jupiter-biosupdate
    if [[ -n $VENDORED_BIOS_UPDATE && -d $VENDORED_BIOS_UPDATE ]]; then
      biostool="$VENDORED_BIOS_UPDATE"/jupiter-biosupdate
      export JUPITER_BIOS_DIR="$VENDORED_BIOS_UPDATE"
    fi

    if [[ -x $biostool ]]; then
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
    else
      ewarn "jupiter-biosupdate not found - skipping BIOS staging"
    fi
  elif [[ $writeOS = 1 ]]; then
    einfo "Not a Steam Deck - skipping BIOS staging"
  fi

  # Perform a controller update if updating OS.  OOBE images like this one don't auto-update controllers on boot.
  if [[ $writeOS = 1 ]] && is_steam_deck; then
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
    rootfs_frozen=
    unfreeze() {
      if [[ -n ${rootfs_frozen:-} ]]; then
        fsfreeze -u / || true
        rootfs_frozen=
      fi
    }
    onexit+=(unfreeze)
    cmd fsfreeze -f /
    rootfs_frozen=1

    estat "Imaging OS partition A"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_A)"

    estat "Imaging OS partition B"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_B)"

    # unfreeze before touching the network / package manager
    estat "Unfreezing rootfs"
    unfreeze

    # run post-install hooks (driver installs etc.) on both partsets
    run_postinstall A "$(diskpart $FS_ROOT_A)"
    run_postinstall B "$(diskpart $FS_ROOT_B)"

    estat "Finalizing boot configurations"
    finalize_part A
    finalize_part B
    estat "Finalizing EFI system partition"
    cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable
  fi
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

# call nvme sanitize (NVMe) or secure-erase/blkdiscard (SATA), and wait for completion.
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
    get_sanitize_progress || sres=$?

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
        ;;
      2)
        echo "NVMe sanitize not supported, trying secure format..."
        nvme format "$DISK" -n 1 -s 1 -r || echo "NVMe secure format failed!"
        return 0
        ;;
      *)
        echo "Unexpected sanitize-log result for $DISK"
        return $sres
        ;;
    esac

    # Espera término
    while ! get_sanitize_progress; do
      sleep 5
    done
    echo "... NVMe sanitize done."

  else
    echo "Disk type: SATA/SSD"
    # Primeiro tenta hdparm secure erase, se suportado e não congelado pelo BIOS
    if command -v hdparm >/dev/null 2>&1 \
       && hdparm -I "$DISK" 2>/dev/null | grep -qE '^[[:space:]]+supported$' \
       && hdparm -I "$DISK" 2>/dev/null | grep -qE '^[[:space:]]+not[[:space:]]+frozen$'; then
      echo "Using hdparm security-erase..."
      hdparm --user-master u --security-set-pass NULL "$DISK" || true
      hdparm --user-master u --security-erase NULL "$DISK" && {
        echo "... SATA secure erase done."
        return 0
      }
      echo "hdparm secure erase failed, falling back..."
    fi

    # Fallback: destrói todo o conteúdo com blkdiscard (rápido, só SSD) ou dd (lento)
    if blkdiscard -f "$DISK" 2>/dev/null; then
      echo "... blkdiscard wipe done."
    else
      echo "Using dd to zero-fill $DISK (this may take a long time)..."
      dd if=/dev/zero of="$DISK" bs=128M status=progress oflag=direct || true
      sync
      echo "... zero-fill done."
    fi
    echo "... SATA/SSD sanitize done."
  fi
}


# print quick list of targets
#
help()
{
  readvar HELPMSG << EOD
This tool reinstalls or repairs a SteamOS installation on a chosen disk
(Steam Deck NVMe, SATA SSD, eMMC or virtual disk).

Possible targets:
    menu : interactive menu with all the actions below.
    all : permanently destroy all data on the selected disk, and reinstall SteamOS.
    system : reinstall SteamOS on the system partitions of the selected disk.
    home : remove games and personalization from the selected disk.
    chroot : chroot to the primary SteamOS partition set.
    sanitize : perform a sanitize/secure-erase operation on the selected disk.

Environment:
    DISK=/dev/sdX  preselect target disk    NOPROMPT=1  skip confirmations
    NVIDIA=0|1     force-skip/force NVIDIA driver install
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
menu)
  choice=""
  if have_gui; then
    choice=$(zenity --list --title="Universal SteamOS Installer" \
                    --text="Select an action" \
                    --column="Action" --column="Description" \
                    all      "Wipe a disk and install SteamOS" \
                    system   "Reinstall OS partitions only (keep home)" \
                    home     "Reformat home partitions (wipe games/data)" \
                    chroot   "Open a shell in the installed system" \
                    sanitize "Secure-erase a disk" \
                    --height=340 --width=560) || exit 0
  else
    emsg "Select an action:"
    select choice in all system home chroot sanitize quit; do break; done
    [[ -n ${choice:-} && $choice != quit ]] || exit 0
  fi
  exec "$0" "$choice"
  ;;
all)
  select_disk
  prompt_step "Reimage Device" "This action will reimage the disk $DISK.\nThis will permanently destroy all data on $DISK and reinstall SteamOS.\n\nThis cannot be undone.\n\nChoose Proceed only if you wish to clear and reimage this disk."
  sanitize_all
  writePartitionTable=1
  writeOS=1
  writeHome=1
  repair_steps
  prompt_reboot "Reimaging complete."
  ;;
system)
  select_disk
  prompt_step "Reinstall SteamOS" "This action will reinstall SteamOS on $DISK, while attempting to preserve your games and personal content.\nSystem customizations may be lost.\n\nChoose Proceed to reinstall SteamOS on this disk."
  writeOS=1
  repair_steps
  prompt_reboot "SteamOS reinstall complete."
  ;;
home)
  select_disk
  prompt_step "Delete local user data" "This action will reformat the home partitions on $DISK.\nThis will destroy downloaded games and all personal content, including system configuration.\n\nThis action cannot be undone.\n\nChoose Proceed to reformat all user home partitions."
  writeHome=1
  repair_steps
  prompt_reboot "User partitions have been reformatted."
  ;;
chroot)
  select_disk
  chroot_primary
  ;;
sanitize)
  select_disk
  prompt_step "Clear and sanitize disk" "This action will kick off a sanitize/secure-erase of $DISK, irrevocably deleting all data on it.\n\nThis action cannot be undone.\n\nChoose Proceed only if you want to remove all data from this disk."
  sanitize_all
  ;;
*)
  help
  ;;
esac
