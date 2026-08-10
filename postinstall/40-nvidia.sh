#!/bin/bash
#
# Post-install hook: drivers proprietários NVIDIA.
#
# Detecta a geração da placa pelo device id PCI e escolhe o pacote:
#
#   Turing (16xx/20xx) em diante   nvidia-dkms  (ou nvidia-open-dkms com NVIDIA_OPEN=1)
#   Maxwell / Pascal (9xx/10xx)    nvidia-dkms  (ramo legado, avisa se indisponível)
#   Kepler e anteriores            avisa: precisa de nvidia-470xx/390xx (AUR / vendorizado)
#
# Quando há também uma iGPU (Intel ou AMD) instala o nvidia-prime para
# render offload.
#
# Overrides do usuário:
#   NVIDIA=0       nunca instala | NVIDIA=1 instala mesmo sem GPU detectada
#   NVIDIA_OPEN=1  usa nvidia-open-dkms (módulos abertos, Turing+)
#   NVIDIA_PKG=... nome do pacote do driver a instalar (ex: nvidia-470xx-dkms)
#
# Modo offline: coloque os .pkg.tar.zst em $PAYLOAD_DIR/pkgs/nvidia/ (ou, por
# compatibilidade, direto em $PAYLOAD_DIR/pkgs/) - ex: nvidia-dkms,
# nvidia-utils, lib32-nvidia-utils, linux-neptune-*-headers.
#
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ ${NVIDIA:-} != 0 ]] || hskip "NVIDIA=0 - pulando driver NVIDIA"
if [[ ${NVIDIA:-} != 1 ]] && ! has_gpu 'NVIDIA'; then
  hskip "Nenhuma GPU NVIDIA detectada - pulando (use NVIDIA=1 para forçar)"
fi

hlog "GPU NVIDIA detectada no partset $PARTSET"
gpu_devices | grep -i nvidia | sed 's/^/     /' >&2 || true

# Faixas de device id por arquitetura (o id cresce com a geração):
#   >= 0x1e00  Turing/Ampere/Ada/Blackwell   -> driver atual
#   >= 0x1300  Maxwell/Pascal                -> driver atual (ramo legado 5xx)
#   <  0x1300  Kepler e anteriores           -> 470xx/390xx (fora dos repos oficiais)
newest=0
for id in $(gpu_device_ids 10de); do
  dec=$((16#$id))
  (( dec > newest )) && newest=$dec || true
done

driver="${NVIDIA_PKG:-}"
if [[ -z $driver ]]; then
  if (( newest == 0 )); then
    driver="nvidia-dkms"
  elif (( newest >= 0x1e00 )); then
    driver="nvidia-dkms"
    [[ ${NVIDIA_OPEN:-} != 1 ]] || driver="nvidia-open-dkms"
  elif (( newest >= 0x1300 )); then
    driver="nvidia-dkms"
    hwarn "Placa Maxwell/Pascal: o driver atual ainda funciona, mas em ramo legado."
  else
    driver="nvidia-470xx-dkms"
    hwarn "Placa Kepler ou anterior: precisa de $driver, que NÃO está nos repositórios"
    hwarn "oficiais. Vendorize o pacote em $PAYLOAD_DIR/pkgs/nvidia/ ou use NVIDIA_PKG=."
  fi
fi

pkgs="$driver nvidia-utils lib32-nvidia-utils"
if has_gpu 'Intel|Advanced Micro Devices|AMD/ATI|ATI Technologies'; then
  hlog "Sistema híbrido (iGPU + NVIDIA) - incluindo nvidia-prime"
  pkgs="$pkgs nvidia-prime"
fi

hlog "Pacote de driver escolhido: $driver"

stage_pkgs nvidia 1 || true

in_target <<TARGET
unlock_rootfs

if ! pkg_install_local nvidia; then
  # DKMS precisa dos headers do kernel realmente instalado
  # shellcheck disable=SC2046
  pkg_install \$(kernel_headers) || true
  pkg_install $pkgs || true
fi

cat > /etc/modprobe.d/disable-nouveau.conf <<'DISABLE_NOUVEAU'
# Disable nouveau for proprietary Nvidia driver
blacklist nouveau
options nouveau modeset=0
DISABLE_NOUVEAU

cat > /etc/modprobe.d/nvidia-modeset.conf <<'NMOD'
options nvidia-drm modeset=1
NMOD

add_cmdline nvidia_drm.modeset=1

rebuild_initramfs

lock_rootfs
tlog "NVIDIA: concluído"
TARGET
