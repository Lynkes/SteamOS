#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Improved: safer error handling, argument parsing, validation, dry-run, no-infinite-sleep
#
# tornar o script mais seguro e parar em erros
set -euo pipefail
# trap para mostrar linha do erro e pausar para inspeção
trap 'echo "[ERRO] Script abortado na linha $LINENO"; read -r -p "Pressione ENTER para sair..."' ERR
set -o nounset
set -o pipefail
# --- Configuration (edit as needed) ---
DISK_DEFAULT="/dev/nvme0n1"
DISK_SUFFIX="p"
DOPARTVERIFY=1

VENDORED_BIOS_UPDATE="/home/deck/jupiter-bios"
VENDORED_CONTROLLER_UPDATE="/home/deck/jupiter-controller-fw"

PART_SIZE_ESP="256"
PART_SIZE_EFI="64"
PART_SIZE_ROOT="5120"
PART_SIZE_VAR="256"
PART_SIZE_HOME="100"

TARGET_SECTOR_SIZE=512
# -------------------------------------

# runtime flags (modifiable via CLI)
DRYRUN=0
PROMPT=1
FORCEBIOS=0
POWEROFF=0

# computed values – initialized but may be replaced by autodetect
DISK="$DISK_DEFAULT"
DISKPART_SEP="${DISK_SUFFIX:-}"

# helper: ajusta separador de partição conforme o tipo de disco
set_diskpart_sep() {
  if [[ "$DISK" =~ ^/dev/nvme ]]; then
    DISKPART_SEP="p"
  else
    DISKPART_SEP=""
  fi
}

# valida o disco existe
if [[ ! -b "$DISK" ]]; then
  die "Disk $DISK does not exist. Ajuste --disk." 6
fi

# configura separador final ('' para sda, 'p' para nvme)
set_diskpart_sep

# ----- FUNÇÃO DISKPART CORRETA -----
# Garante 100% "/dev/sda6" e não "/dev/sdap6"
diskpart() { printf "%s%s%d" "$DISK" "$DISKPART_SEP" "$1"; }

# ----- SUBSTITUIÇÃO CORRETA %%DISKPART%% -----
# sfdisk NÃO quer /dev/sda1; a tabela usa somente prefixo (/dev/sda)
# Exemplo: "%%DISKPART%%6:" vira "/dev/sda6:"

# helper: print to stderr with color if supported
_sh_c_colors=0
[[ -n ${TERM-} && -t 2 && ${TERM,,} != dumb ]] && _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"
sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && echo -n $'\e['"${*:-0}m"; ); }
log()    { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
info()   { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
warn()   { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
error()  { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
die()    { local rc=${2-1}; error "$1"; exit "$rc"; }

# Dry-run wrapper for commands
run_cmd() {
  if [[ $DRYRUN -eq 1 ]]; then
    info "[DRYRUN] $*"
    return 0
  fi
  info "+ $*"
  "$@"
}

# Check required binaries early
require_cmds() {
  local miss=0
  for cmd in sfdisk dd mkfs.ext4 mkfs.vfat blkid steamos-chroot nvme; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Required command not found: $cmd"
      miss=1
    fi
  done
  [[ $miss -eq 0 ]] || die "Install missing dependencies and re-run."
}

# argument parsing (simple)
usage() {
  cat <<EOF
Usage: ${0##*/} [options] <target>
Targets: all | system | home | chroot | sanitize
Options:
  --disk /dev/sdX     target disk (default: $DISK_DEFAULT)
  --no-prompt         don't show GUI prompts; use console confirmations
  --dry-run           show actions but don't execute
  --force-bios        pass FORCEBIOS
  --poweroff          poweroff after finishing (default: reboot)
EOF
  exit 1
}

# small prompt fallback (zenity optional)
prompt_step() {
  local title="$1"; local msg="$2"; local unconditional="${3-}"
  if [[ $PROMPT -eq 0 ]]; then
    echo -e "$title: $msg"
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg" || exit 1
  else
    # console fallback
    echo -e "$title\n\n$msg"
    read -r -p "Proceed? [y/N] " ans
    [[ "${ans,,}" = "y" ]] || exit 1
  fi
}

# safe mount/umount helpers
safe_mount() {
  local dev="$1"; local target="$2"
  if mountpoint -q "$target"; then
    info "$target already mounted"
    return 0
  fi
  run_cmd sudo mount "$dev" "$target"
}
safe_umount() {
  local target="$1"
  if mountpoint -q "$target"; then
    run_cmd sudo umount -l "$target"
  fi
}

# improved trap/cleanup
onexit_funcs=()
register_onexit() { onexit_funcs+=("$1"); }
exithandler() {
  local f
  for f in "${onexit_funcs[@]}"; do
    "$f" || true
  done
}
trap exithandler EXIT

# partition-table template
read -r -d '' PARTITION_TABLE <<EOF || true
label: gpt
%%DISKPART%%1: name="esp",      size=         ${PART_SIZE_ESP}MiB,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
%%DISKPART%%2: name="efi-A",    size=         ${PART_SIZE_EFI}MiB,  type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
%%DISKPART%%3: name="efi-B",    size=         ${PART_SIZE_EFI}MiB,  type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
%%DISKPART%%4: name="rootfs-A", size=         ${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
%%DISKPART%%5: name="rootfs-B", size=         ${PART_SIZE_ROOT}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
%%DISKPART%%6: name="var-A",    size=         ${PART_SIZE_VAR}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
%%DISKPART%%7: name="var-B",    size=         ${PART_SIZE_VAR}MiB,  type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
%%DISKPART%%8: name="home",     size=         ${PART_SIZE_HOME}MiB, type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
EOF

# partition helpers
diskpart() { printf "%s%s%d" "$DISK" "$DISKPART_SEP" "$1"; }

# verify partition - safer messages, avoid infinity sleeps
verifypart() {
  [[ $DOPARTVERIFY -eq 1 ]] || return 0
  local dev="$1" expected_type="$2" expected_label="$3"
  local type partlabel
  type="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
  partlabel="$(blkid -o value -s PARTLABEL "$dev" 2>/dev/null || true)"
  if [[ -z "$type" ]]; then
    die "blkid didn't report TYPE for $dev (exists? readable?)" 2
  fi
  if [[ "$type" != "$expected_type" ]]; then
    die "Device $dev is type $type but expected $expected_type - aborting." 3
  fi
  if [[ "$partlabel" != "$expected_label" ]]; then
    die "Device $dev has PARTLABEL '$partlabel' but expected '$expected_label' - aborting." 4
  fi
}

# format helpers (use run_cmd wrapper)
fmt_ext4()  { [[ $# -eq 2 ]] || die "fmt_ext4 usage"; run_cmd sudo mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 ]] || die "fmt_fat32 usage"; run_cmd sudo mkfs.vfat -n"$1" "$2"; }

# image root copy (btrfs aware)
imageroot() {
  local src="$1" dst="$2"
  [[ -b "$dst" || -f "$dst" ]] || die "Target $dst doesn't exist"
  run_cmd sudo dd if="$src" of="$dst" bs=128M status=progress oflag=sync
  # only attempt btrfstune if output looks like btrfs
  if file -s "$dst" | grep -qi btrfs; then
    run_cmd sudo btrfstune -f -u "$dst"
    run_cmd sudo btrfs check "$dst" || warn "btrfs check returned non-zero"
  fi
}

# finalize partition (boot setup)
finalize_part() {
  local partset="$1"
  info "Finalizing install part $partset"
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- mkdir -p /efi/SteamOS
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- mkdir -p /esp/SteamOS/conf
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- steamos-partsets /efi/SteamOS/partsets
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- steamos-bootconf create --image "$partset" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$partset"
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- grub-mkimage || warn "grub-mkimage returned non-zero (non-fatal)"
  run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" -- update-grub || warn "update-grub returned non-zero (non-fatal)"
}



# install nvidia drivers inside a partset (kept much of original logic)
# install nvidia drivers inside a partset
install_nvidia_drivers() {
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

# NVMe sanitize helpers
get_sanitize_progress() {
  local status progress
  status=$(nvme sanitize-log "${DISK}" 2>/dev/null | awk '/\(SSTAT\)/{print $NF}' || true)
  if [[ -z "$status" ]]; then
    return 2
  fi
  # decode status heuristics from original script: return 0-ready,1-inprogress,2-unsupported
  # (this keeps compatibility with the original)
  if (( (0 + status) % 8 == 2 )); then
    return 0
  fi
  progress=$(nvme sanitize-log "${DISK}" 2>/dev/null | awk '/\(SPROG\)/{print $NF}' || true)
  if [[ -n "$progress" ]]; then
    printf "sanitize progress: %d%%\n" $(( ( progress * 100 )/ 65535 ))
    return 1
  fi
  return 2
}

sanitize_all() {
  local sres=0
  get_sanitize_progress || sres=$?
  case $sres in
    0)
      echo "This will irrevocably clear all data on ${DISK}"
      if [[ $DRYRUN -eq 1 ]]; then
        info "[DRYRUN] nvme sanitize -a 2 ${DISK}"
        return 0
      fi
      nvme sanitize -a 2 "${DISK}"
      info "Sanitize action started."
      ;;
    1)
      info "An NVME sanitize action is already in progress."
      return 0
      ;;
    2)
      info "Device doesn't support sanitize, falling back to secure format"
      if [[ $DRYRUN -eq 1 ]]; then
        info "[DRYRUN] nvme format ${DISK} -n 1 -s 1 -r"
        return 0
      fi
      nvme format "${DISK}" -n 1 -s 1 -r
      return 0
      ;;
    *)
      die "Unexpected result from sanitize-log: $sres" 5
      ;;
  esac

  # wait for progress to finish
  while get_sanitize_progress; do
    sleep 5
  done
  info "Sanitize done."
}

# Main repair steps (keeps structure of original but safer)
repair_steps() {
  local writePartitionTable=${1:-0}
  local writeOS=${2:-0}
  local writeHome=${3:-0}

  if [[ $writePartitionTable -eq 1 ]]; then
    info "Writing known partition table to $DISK"
    # Build final partition table (expand vars and substitute DISKPART token)
    PART_TABLE_FINAL=$(printf "%s" "$PARTITION_TABLE" \
    | sed "s|%%DISKPART%%|${DISK}${DISKPART_SEP}|g")


    # write to temp file and run sfdisk (safer quoting and easier to debug)
    tmpf=$(mktemp)
    printf '%s\n' "$PART_TABLE_FINAL" > "$tmpf"

    if [[ $DRYRUN -eq 1 ]]; then
      info "[DRYRUN] sfdisk $DISK < $tmpf"
    else
      info "Applying partition table to $DISK (see $tmpf for content)"
      sudo sfdisk "$DISK" < "$tmpf"
    fi

    rm -f "$tmpf"

  elif [[ $writeOS -eq 1 || $writeHome -eq 1 ]]; then
    # verify partitions
    verifypart "$(diskpart 1)" vfat esp
    verifypart "$(diskpart 2)" vfat efi-A
    verifypart "$(diskpart 3)" vfat efi-B
    verifypart "$(diskpart 6)" ext4 var-A
    verifypart "$(diskpart 7)" ext4 var-B
    verifypart "$(diskpart 8)" ext4 home
  fi

  if [[ $writeOS -eq 1 || $writeHome -eq 1 ]]; then
    info "Formatting var partitions"
    fmt_ext4 var "$(diskpart 6)"
    fmt_ext4 var "$(diskpart 7)"
  fi

  if [[ $writeOS -eq 1 ]]; then
    info "Formatting ESP/EFI partitions"
    fmt_fat32 esp "$(diskpart 1)"
    fmt_fat32 efi "$(diskpart 2)"
    fmt_fat32 efi "$(diskpart 3)"
  fi

  if [[ $writeHome -eq 1 ]]; then
    info "Formatting home partition"
    run_cmd sudo mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart 8)"
    run_cmd sudo tune2fs -m 0 "$(diskpart 8)"
  fi

  if [[ $writeOS -eq 1 ]]; then
    # Biostaging
    local biostool="/usr/bin/jupiter-biosupdate"
    if [[ -d "${VENDORED_BIOS_UPDATE:-}" ]]; then
      biostool="${VENDORED_BIOS_UPDATE}/jupiter-biosupdate"
      export JUPITER_BIOS_DIR="$VENDORED_BIOS_UPDATE"
    fi

    fix_esp() {
      safe_umount /esp
      safe_umount /boot/efi
    }
    register_onexit fix_esp

    info "Mounting ESP/EFI to stage BIOS"
    run_cmd sudo mkdir -p /esp /boot/efi
    safe_mount "$(diskpart 1)" /esp
    safe_mount "$(diskpart 2)" /boot/efi

    if [[ ${FORCEBIOS:-0} -eq 1 ]]; then
      run_cmd sudo "$biostool" --force || run_cmd sudo "$biostool"
    else
      run_cmd sudo "$biostool" || warn "Bios tool failed (non-fatal)"
    fi

    fix_esp
  fi

  if [[ $writeOS -eq 1 ]]; then
    info "Controller firmware update (if applicable)"
    local controller_tool="/usr/bin/jupiter-controller-update"
    if [[ -d "${VENDORED_CONTROLLER_UPDATE:-}" ]]; then
      controller_tool="${VENDORED_CONTROLLER_UPDATE}/jupiter-controller-update"
      export JUPITER_CONTROLLER_UPDATE_FIRMWARE_DIR="$VENDORED_CONTROLLER_UPDATE"
    fi
    # allow failure but try to run
    run_cmd sudo env JUPITER_CONTROLLER_UPDATE_IN_OOBE=1 "$controller_tool" || warn "controller update failed (non-fatal)"
  fi

  if [[ $writeOS -eq 1 ]]; then
    local rootdevice
    rootdevice="$(findmnt -n -o source / || true)"
    [[ -n "$rootdevice" && -e "$rootdevice" ]] || die "Could not find installer root device -- abort."

    # Freeze and ensure unfreeze on exit
    unfreeze() { if mountpoint -q /; then run_cmd sudo fsfreeze -u / || true; fi; }
    register_onexit unfreeze
    run_cmd sudo fsfreeze -f /

    info "Imaging OS partition A"
    imageroot "$rootdevice" "$(diskpart 4)"
    info "Imaging OS partition B"
    imageroot "$rootdevice" "$(diskpart 5)"

    echo ":: Enabling devmode so pacman can write to the rootfs"
    sudo steamos-devmode enable || true
    
    # install nvidia drivers in both partsets A and B
    install_nvidia_drivers "A"
    install_nvidia_drivers "B"

    sudo steamos-devmode disable || true

    info "Finalizing boot configurations and EFI content"
    finalize_part A
    finalize_part B

    run_cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable || warn "steamcl-install returned non-zero"
  fi
}

# CLI parse (minimal)
if [[ $# -lt 1 ]]; then usage; fi

# parse options before target
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) DISK="${2:-}"; shift 2;;
    --no-prompt) PROMPT=0; shift;;
    --dry-run) DRYRUN=1; shift;;
    --force-bios) FORCEBIOS=1; shift;;
    --poweroff) POWEROFF=1; shift;;
    all|system|home|chroot|sanitize)
      TARGET="$1"; shift;;
    -*)
      error "Unknown option: $1"; usage;;
    *)
      TARGET="$1"; shift;;
  esac
done

# --- Auto detect disk (NVMe → SATA fallback, unless --disk was given) ---

AUTO_DISK=""
USER_DISK_SET=0

# Check if user provided --disk
if [[ "$DISK" != "$DISK_DEFAULT" ]]; then
  USER_DISK_SET=1
fi

if [[ $USER_DISK_SET -eq 0 ]]; then
  # Try NVMe first
  if ls /dev/nvme0n1 >/dev/null 2>&1; then
    AUTO_DISK="/dev/nvme0n1"
    info "NVMe detectado automaticamente: $AUTO_DISK"
  else
    # fallback SATA /dev/sdX
    SATA_FOUND=$(ls /dev/sd[a-z] 2>/dev/null | head -n 1 || true)
    if [[ -n "$SATA_FOUND" ]]; then
      AUTO_DISK="$SATA_FOUND"
      info "NVMe não encontrado. Usando disco SATA: $AUTO_DISK"
    else
      die "Nenhum disco NVMe ou SATA encontrado! Abortando." 9
    fi
  fi

  DISK="$AUTO_DISK"
else
  info "Usando disco informado pelo usuário via --disk: $DISK"
fi


# validate disk exists
if [[ ! -b "$DISK" && ! -e "$DISK" ]]; then
  die "Disk $DISK does not exist. Adjust --disk parameter." 6
fi

require_cmds

# Commands for targets
case "${TARGET-}" in
  all)
    prompt_step "Wipe Device & Install SteamOS" "This action will wipe and (re)install SteamOS on this device. This will permanently destroy all data on your device. Choose Proceed only if you wish to wipe and reinstall this device."
    repair_steps 1 1 1
    sanitize_all
    if [[ $POWEROFF -eq 1 ]]; then
      run_cmd systemctl poweroff
    else
      run_cmd systemctl reboot
    fi
    ;;
  system)
    prompt_step "Repair SteamOS" "This action will repair the SteamOS installation on the device, while attempting to preserve your games and personal content."
    repair_steps 0 1 0
    if [[ $POWEROFF -eq 1 ]]; then
      run_cmd systemctl poweroff
    else
      run_cmd systemctl reboot
    fi
    ;;
  home)
    prompt_step "Delete local user data" "This action will reformat the home partitions on your device. This will destroy downloaded games and all personal content."
    repair_steps 0 0 1
    if [[ $POWEROFF -eq 1 ]]; then
      run_cmd systemctl poweroff
    else
      run_cmd systemctl reboot
    fi
    ;;
  chroot)
    info "Opening steamos-chroot into primary partition set"
    run_cmd steamos-chroot --disk "$DISK" --partset "A"
    ;;
  sanitize)
    prompt_step "Clear and sanitize NVME disk" "This action will kick off an NVME sanitize on the primary drive, irrevocably deleting all user data."
    sanitize_all
    ;;
  *)
    usage
    ;;
esac
