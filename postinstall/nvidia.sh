#!/bin/bash
#
# Post-install hook: proprietary NVIDIA drivers.
#
# Executado pelo REPAIRDEVICE_NEW.sh no sistema live, uma vez por partset,
# com o seguinte contrato de ambiente:
#   DISK             disco alvo (ex: /dev/nvme0n1)
#   DISK_SUFFIX      "p" ou ""
#   PARTSET          "A" ou "B"
#   TARGET_ROOT_DEV  partição rootfs do partset (ex: /dev/nvme0n1p4)
#   PAYLOAD_DIR      diretório do instalador no pendrive
#
# Overrides do usuário:
#   NVIDIA=0  nunca instala | NVIDIA=1 instala mesmo sem GPU detectada
#
# Modo offline: coloque pacotes .pkg.tar.zst em $PAYLOAD_DIR/pkgs/ (ex:
# nvidia-dkms, nvidia-utils, lib32-nvidia-utils, linux-neptune-headers) e
# eles serão instalados com pacman -U, sem depender de rede/mirror.
#
set -eu

if [[ ${NVIDIA:-} = 0 ]]; then
  echo ":: NVIDIA=0 - skipping NVIDIA driver install"
  exit 0
fi
if [[ ${NVIDIA:-} != 1 ]] && ! lspci 2>/dev/null | grep -Ei 'vga|3d|display' | grep -qi nvidia; then
  echo ":: No NVIDIA GPU detected - skipping (set NVIDIA=1 to force)"
  exit 0
fi

# Copia pacotes vendorizados do pendrive para dentro do alvo, se existirem
STAGE_DIR=/opt/universal-pkgs
if compgen -G "$PAYLOAD_DIR/pkgs/*.pkg.tar.zst" >/dev/null; then
  echo ":: Staging vendored packages into target rootfs"
  mnt="$(mktemp -d)"
  mount "$TARGET_ROOT_DEV" "$mnt"
  btrfs property set "$mnt" ro false 2>/dev/null || true
  mkdir -p "$mnt$STAGE_DIR"
  cp "$PAYLOAD_DIR"/pkgs/*.pkg.tar.zst "$mnt$STAGE_DIR/"
  umount "$mnt"
  rmdir "$mnt"
fi

echo ":: Installing NVIDIA drivers inside partset $PARTSET"
steamos-chroot --no-overlay --disk "$DISK" --partset "$PARTSET" -- bash -e <<'CHROOT_EOF'
set -euo pipefail

echo "[NVIDIA] Unlocking read-only rootfs"
if command -v steamos-readonly >/dev/null 2>&1; then
  steamos-readonly disable || true
fi
btrfs property set / ro false 2>/dev/null || true

if ls /opt/universal-pkgs/*.pkg.tar.zst >/dev/null 2>&1; then
  echo "[NVIDIA] Installing vendored packages (offline)"
  pacman -U --noconfirm /opt/universal-pkgs/*.pkg.tar.zst || true
  rm -rf /opt/universal-pkgs
else
  echo "[NVIDIA] Initializing keyring and refreshing packages"
  if command -v pacman-key >/dev/null 2>&1; then
    pacman-key --init 2>/dev/null || true
    # popula todos os keyrings disponíveis (archlinux + holo no SteamOS)
    pacman-key --populate 2>/dev/null || true
  fi

  pacman -Sy --noconfirm || true

  # SteamOS usa linux-neptune*; em Arch genérico é linux. Instala os headers
  # do kernel realmente presente.
  headers_pkgs=""
  for k in $(pacman -Qq 2>/dev/null | grep -E '^linux(-neptune[0-9.-]*)?$' || true); do
    headers_pkgs="$headers_pkgs ${k}-headers"
  done
  [ -n "$headers_pkgs" ] || headers_pkgs="linux-headers"

  # shellcheck disable=SC2086
  pacman -S --noconfirm --needed $headers_pkgs || true
  pacman -S --noconfirm --needed nvidia-dkms nvidia-utils lib32-nvidia-utils || true
fi

# blacklist nouveau
cat > /etc/modprobe.d/disable-nouveau.conf <<'DISABLE_NOUVEAU'
# Disable nouveau for proprietary Nvidia driver
blacklist nouveau
options nouveau modeset=0
DISABLE_NOUVEAU

cat > /etc/modprobe.d/nvidia-modeset.conf <<'NMOD'
options nvidia-drm modeset=1
NMOD

# Ensure nvidia_drm.modeset=1 on the kernel command line
if [ -f /etc/default/grub ]; then
  if ! grep -q 'nvidia_drm.modeset=1' /etc/default/grub; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' /etc/default/grub; then
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia_drm.modeset=1 /' /etc/default/grub || true
    else
      echo 'GRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1"' >> /etc/default/grub
    fi
  fi
fi

if command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P || true
fi

if command -v update-grub >/dev/null 2>&1; then
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

if command -v steamos-readonly >/dev/null 2>&1; then
  steamos-readonly enable || true
fi

echo "[NVIDIA] Done"
CHROOT_EOF
