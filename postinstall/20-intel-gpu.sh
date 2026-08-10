#!/bin/bash
#
# Post-install hook: GPUs Intel (iGPU HD/UHD/Iris Xe e dedicadas Arc).
#
# Instala o stack Mesa/Vulkan/VA-API adequado à geração detectada:
#
#   Gen 8+ (Broadwell em diante, incluindo Arc/Xe)
#       mesa + vulkan-intel (ANV) + intel-media-driver (VAAPI iHD)
#   Gen 5-7.5 (Ironlake .. Haswell/Bay Trail)
#       mesa (crocus) + libva-intel-driver (VAAPI i965)
#
# Para GPUs Intel dedicadas (DG1, Arc "Alchemist" DG2, Arc "Battlemage" BMG)
# acrescenta i915.force_probe / xe.force_probe com os device ids detectados -
# necessário em kernels onde a placa ainda é considerada experimental e
# inofensivo nos kernels em que já é suportada por padrão.
#
# Overrides do usuário:
#   INTEL_GPU=0          nunca instala | INTEL_GPU=1 instala mesmo sem GPU detectada
#   INTEL_ENABLE_GUC=1   força i915.enable_guc=3 (GuC/HuC em Gen9-11)
#   INTEL_FORCE_PROBE=1  força o force_probe também em GPUs integradas
#
# Modo offline: pacotes em $PAYLOAD_DIR/pkgs/intel/
#
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ ${INTEL_GPU:-} != 0 ]] || hskip "INTEL_GPU=0 - pulando driver Intel"
if [[ ${INTEL_GPU:-} != 1 ]] && ! has_gpu 'Intel'; then
  hskip "Nenhuma GPU Intel detectada - pulando (use INTEL_GPU=1 para forçar)"
fi

ids="$(gpu_device_ids 8086 | tr '\n' ' ')"
hlog "GPU Intel detectada no partset $PARTSET"
gpu_devices | grep -i intel | sed 's/^/     /' >&2 || true

# Classificação por prefixo do device id PCI.
#   00/01/04/0a/0d/0f -> Gen5..Gen7.5 (Ironlake, Sandy/Ivy Bridge, Haswell, Bay Trail)
#   49/56/e2          -> dedicadas (DG1, DG2/Alchemist, BMG/Battlemage)
legacy=0
discrete=""
for id in $ids; do
  case "${id:0:2}" in
    00|01|04|0a|0d|0f) legacy=1 ;;
    49|56|e2)          discrete="${discrete}${id}," ;;
  esac
done
discrete="${discrete%,}"

pkgs="mesa lib32-mesa vulkan-intel lib32-vulkan-intel"
if [[ $legacy = 1 ]]; then
  hlog "Geração pré-Broadwell: VA-API via i965 (libva-intel-driver)"
  pkgs="$pkgs libva-intel-driver lib32-libva-intel-driver"
else
  pkgs="$pkgs intel-media-driver linux-firmware-intel"
fi

params=""
if [[ -n $discrete ]]; then
  hlog "GPU Intel dedicada detectada (ids: $discrete) - habilitando force_probe"
  params="i915.force_probe=$discrete xe.force_probe=$discrete"
elif [[ ${INTEL_FORCE_PROBE:-} = 1 && -n ${ids// /} ]]; then
  params="i915.force_probe=$(echo "$ids" | tr ' ' ',' | sed 's/,$//')"
fi
[[ ${INTEL_ENABLE_GUC:-} != 1 ]] || params="$params i915.enable_guc=3"

if has_gpu 'NVIDIA'; then
  hlog "iGPU Intel + GPU NVIDIA: o hook 40-nvidia.sh cuida do PRIME/offload"
fi

stage_pkgs intel || true

in_target <<TARGET
unlock_rootfs

pkg_install_local intel || pkg_install $pkgs || true

$( [[ -n ${params// /} ]] && echo "add_cmdline $params" || true )

lock_rootfs
tlog "GPU Intel: concluído"
TARGET
