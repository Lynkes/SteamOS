#!/bin/bash
#
# Post-install hook: GPUs AMD/ATI (Radeon dedicadas e APUs Ryzen).
#
# O SteamOS já traz o stack AMD completo para o APU do Steam Deck, então este
# hook é pensado para PCs comuns: garante mesa/RADV/VA-API/VDPAU e o firmware
# amdgpu, e trata placas antigas:
#
#   GCN 1.0/1.1 (Southern/Sea Islands) -> força o amdgpu no lugar do radeon
#   TeraScale (HD 2000-6000)           -> só driver radeon + OpenGL, sem Vulkan
#
# Em hardware Steam Deck (Jupiter/Galileo) o hook sai sem fazer nada, já que a
# imagem oficial é feita exatamente para aquele APU.
#
# Overrides do usuário:
#   AMD_GPU=0     nunca instala | AMD_GPU=1 instala mesmo em Steam Deck / sem GPU detectada
#   AMD_LEGACY=1  força os parâmetros si_support/cik_support do amdgpu
#
# Modo offline: pacotes em $PAYLOAD_DIR/pkgs/amd/
#
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

AMD_RE='Advanced Micro Devices|AMD/ATI|ATI Technologies'

[[ ${AMD_GPU:-} != 0 ]] || hskip "AMD_GPU=0 - pulando driver AMD"

if [[ ${AMD_GPU:-} != 1 ]]; then
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  case "$product" in
    Jupiter*|Galileo*) hskip "Steam Deck ($product) - stack AMD já vem pronto na imagem" ;;
  esac
  has_gpu "$AMD_RE" || hskip "Nenhuma GPU AMD detectada - pulando (use AMD_GPU=1 para forçar)"
fi

hlog "GPU AMD detectada no partset $PARTSET"
gpu_devices | grep -Ei "$AMD_RE" | sed 's/^/     /' >&2 || true

amd_lines="$(gpu_devices | grep -Ei "$AMD_RE" || true)"

# GCN 1.0/1.1: o kernel entrega essas placas ao driver radeon por padrão;
# o amdgpu (necessário para RADV/Vulkan) precisa ser forçado.
GCN1_RE='Tahiti|Pitcairn|Verde|Oland|Hainan|Curacao|Bonaire|Hawaii|Kaveri|Kabini|Mullins|Temash'
# Pré-GCN (TeraScale): sem suporte amdgpu/Vulkan, apenas o driver radeon.
TERASCALE_RE='RV6|RV7|RS[678]|Cedar|Redwood|Juniper|Cypress|Hemlock|Barts|Turks|Caicos|Cayman|Wrestler|Sumo|Trinity|Richland'

legacy_gcn=0
terascale=0
grep -Eqi "$GCN1_RE" <<<"$amd_lines" && legacy_gcn=1 || true
grep -Eqi "$TERASCALE_RE" <<<"$amd_lines" && terascale=1 || true
[[ ${AMD_LEGACY:-} != 1 ]] || legacy_gcn=1

pkgs="mesa lib32-mesa libva-mesa-driver lib32-libva-mesa-driver mesa-vdpau lib32-mesa-vdpau"
if [[ $terascale = 1 && $legacy_gcn = 0 ]]; then
  hlog "Placa pré-GCN (TeraScale): apenas driver radeon + OpenGL, sem Vulkan"
else
  pkgs="$pkgs vulkan-radeon lib32-vulkan-radeon linux-firmware-amdgpu"
fi

params=""
if [[ $legacy_gcn = 1 ]]; then
  hlog "Placa GCN 1.0/1.1: forçando amdgpu no lugar do radeon"
  params="radeon.si_support=0 radeon.cik_support=0 amdgpu.si_support=1 amdgpu.cik_support=1"
fi

stage_pkgs amd || true

in_target <<TARGET
unlock_rootfs

pkg_install_local amd || pkg_install $pkgs || true

$( [[ -n $params ]] && echo "add_cmdline $params" || true )
$( [[ $legacy_gcn = 1 ]] && echo 'rebuild_initramfs' || true )

lock_rootfs
tlog "GPU AMD: concluído"
TARGET
