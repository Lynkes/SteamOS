#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
#
# Biblioteca compartilhada dos hooks de pós-instalação.
#
# Arquivos cujo nome começa com "_" NÃO são executados como hook pelo
# REPAIRDEVICE_NEW.sh - eles existem apenas para serem "source"ados pelos
# hooks reais:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#
# Ambiente recebido pelos hooks (ver run_postinstall no script principal):
#   DISK             disco alvo (ex: /dev/nvme0n1)
#   DISK_SUFFIX      "p" ou ""
#   PARTSET          "A" ou "B"
#   TARGET_ROOT_DEV  partição rootfs do partset (ex: /dev/nvme0n1p4)
#   PAYLOAD_DIR      diretório do instalador no pendrive
#   POSTINSTALL_DIR  diretório destes hooks
#

# Diretório onde pacotes vendorizados são copiados dentro do sistema alvo
PKG_STAGE_DIR=/opt/universal-pkgs

hlog()  { echo ":: $*"; }
hwarn() { echo ";; $*" >&2; }
# Encerra o hook com sucesso (não aplicável a esta máquina)
hskip() { echo ":: $*"; exit 0; }

##
## Detecção de hardware (lado do instalador, hardware real da máquina)
##

# Linhas `lspci -nn` de todos os controladores gráficos
gpu_devices()
{
  lspci -nn 2>/dev/null |
    grep -Ei 'vga compatible controller|3d controller|display controller' || true
}

# has_gpu <regex> - verdadeiro se alguma GPU casa com a regex (case insensitive)
has_gpu() { gpu_devices | grep -Eqi "$1"; }

# gpu_device_ids <vendor-id-hex> - lista os device ids (4 hex) desse fabricante
#   ex: gpu_device_ids 8086  ->  46a6
gpu_device_ids()
{
  gpu_devices |
    grep -oEi "\[$1:[0-9a-f]{4}\]" |
    cut -d: -f2 | tr -d ']' | tr 'A-F' 'a-f' | sort -u
}

cpu_vendor() { grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}'; }
cpu_model()  { grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//'; }

##
## Pacotes vendorizados (instalação offline)
##

# stage_pkgs <nome> [legacy]
#
# Copia os .pkg.tar.zst de $PAYLOAD_DIR/pkgs/<nome>/ para
# $PKG_STAGE_DIR/<nome> dentro do rootfs alvo. Com legacy=1, cai de volta
# para o diretório plano $PAYLOAD_DIR/pkgs/ (compatibilidade).
#
# Retorna 0 se algo foi copiado, 1 caso contrário.
stage_pkgs()
{
  local name="$1" legacy="${2-}" src=""

  if compgen -G "$PAYLOAD_DIR/pkgs/$name/*.pkg.tar.zst" >/dev/null; then
    src="$PAYLOAD_DIR/pkgs/$name"
  elif [[ $legacy = 1 ]] && compgen -G "$PAYLOAD_DIR/pkgs/*.pkg.tar.zst" >/dev/null; then
    src="$PAYLOAD_DIR/pkgs"
  else
    return 1
  fi

  hlog "Staging de pacotes vendorizados: $src -> $PKG_STAGE_DIR/$name"
  local mnt
  mnt="$(mktemp -d)"
  mount "$TARGET_ROOT_DEV" "$mnt"
  btrfs property set "$mnt" ro false 2>/dev/null || true
  mkdir -p "$mnt$PKG_STAGE_DIR/$name"
  cp "$src"/*.pkg.tar.zst "$mnt$PKG_STAGE_DIR/$name/"
  umount "$mnt"
  rmdir "$mnt"
  return 0
}

##
## Execução dentro do sistema alvo
##

# Preâmbulo injetado em toda chamada de in_target: helpers que rodam DENTRO
# do chroot do sistema instalado.
read -r -d '' TARGET_PRELUDE <<'PRELUDE' || true
set -u
PKG_STAGE_DIR=/opt/universal-pkgs
_pacman_synced=0

tlog() { echo "   [target] $*"; }

_was_ro_mount=0

unlock_rootfs()
{
  # O steamos-chroot entrega a rootfs montada como ro, e o pacman do SteamOS
  # guarda o banco em /usr/lib/holo/pacmandb - dentro da própria rootfs, não
  # em /var. Sem remontar rw ele falha com "unable to lock database", e a
  # propriedade btrfs nem pode ser alterada enquanto a montagem for ro.
  if findmnt -rno OPTIONS / 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    _was_ro_mount=1
    mount -o remount,rw / 2>/dev/null || tlog "aviso: não consegui remontar / como rw"
  fi

  # Só agora, com a montagem rw, dá para mexer na propriedade read-only.
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly disable >/dev/null 2>&1 || true
  fi
  btrfs property set / ro false 2>/dev/null || true
}

lock_rootfs()
{
  sync 2>/dev/null || true
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly enable >/dev/null 2>&1 || true
  fi
  # Devolve a montagem ao estado em que o steamos-chroot a entregou.
  [ "${_was_ro_mount:-0}" = 1 ] && mount -o remount,ro / 2>/dev/null
  return 0
}

# Inicializa keyring e sincroniza os repositórios uma única vez por chroot.
pacman_sync()
{
  [ "$_pacman_synced" = 1 ] && return 0

  # Uma execução anterior interrompida deixa um db.lck que bloqueia tudo.
  # O caminho vem do pacman-conf: no SteamOS o DBPath é /usr/lib/holo/pacmandb,
  # e não o /var/lib/pacman que se esperaria.
  local db
  db="$(pacman-conf DBPath 2>/dev/null || echo /var/lib/pacman/)"
  if [ -e "$db/db.lck" ] && ! pgrep -x pacman >/dev/null 2>&1; then
    tlog "removendo lock órfão do pacman em $db"
    rm -f "$db/db.lck"
  fi

  if command -v pacman-key >/dev/null 2>&1; then
    pacman-key --init >/dev/null 2>&1 || true
    # popula todos os keyrings disponíveis (archlinux + holo no SteamOS)
    pacman-key --populate >/dev/null 2>&1 || true
  fi
  if pacman -Sy --noconfirm; then
    _pacman_synced=1
    return 0
  fi
  tlog "aviso: não foi possível sincronizar os repositórios (sem rede ou sem mirror)"
  return 1
}

# pkg_install <pacotes...>
# Instala um a um para que um pacote indisponível não derrube os demais.
pkg_install()
{
  [ $# -gt 0 ] || return 0
  pacman_sync || return 1
  local p rc=0
  for p in "$@"; do
    if pacman -S --noconfirm --needed "$p"; then
      tlog "instalado: $p"
    else
      tlog "aviso: indisponível ou falhou: $p"
      rc=1
    fi
  done
  return $rc
}

# pkg_install_local <nome> - instala os pacotes vendorizados de $PKG_STAGE_DIR/<nome>
pkg_install_local()
{
  local d="$PKG_STAGE_DIR/$1"
  ls "$d"/*.pkg.tar.zst >/dev/null 2>&1 || return 1
  tlog "instalando pacotes vendorizados (offline) de $d"
  pacman -U --noconfirm "$d"/*.pkg.tar.zst || return 1
  rm -rf "$d"
  return 0
}

# Nomes dos pacotes de headers do(s) kernel(s) realmente instalado(s).
# SteamOS usa linux-neptune*; Arch genérico usa linux.
kernel_headers()
{
  local k out=""
  for k in $(pacman -Qq 2>/dev/null | grep -E '^linux(-neptune[0-9.-]*)?$' || true); do
    out="$out ${k}-headers"
  done
  [ -n "$out" ] || out="linux-headers"
  echo "$out"
}

# add_cmdline <param> [param...] - acrescenta parâmetros ao GRUB_CMDLINE_LINUX_DEFAULT
add_cmdline()
{
  local f=/etc/default/grub p
  [ -f "$f" ] || printf 'GRUB_CMDLINE_LINUX_DEFAULT=""\n' > "$f"
  for p in "$@"; do
    if grep -qF -- "$p" "$f"; then
      continue
    fi
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' "$f"; then
      sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|&$p |" "$f"
    else
      printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$p" >> "$f"
    fi
    tlog "cmdline += $p"
  done
}

rebuild_initramfs()
{
  if command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P || true
  fi
}

enable_service()
{
  if systemctl enable "$1" >/dev/null 2>&1; then
    tlog "serviço habilitado: $1"
  else
    tlog "aviso: não foi possível habilitar $1"
  fi
}
PRELUDE

# in_target - lê um script na entrada padrão e executa dentro do partset alvo,
# com o preâmbulo de helpers acima já carregado.
in_target()
{
  { printf '%s\n' "$TARGET_PRELUDE"; cat; } |
    steamos-chroot --no-overlay --disk "$DISK" --partset "$PARTSET" -- bash
}
