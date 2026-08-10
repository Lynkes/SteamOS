#!/bin/bash
#
# Post-install hook: microcódigo de CPU (Intel e AMD).
#
# Instala intel-ucode / amd-ucode conforme o processador da máquina. O
# update-grub executado depois pela finalização do instalador detecta o
# /boot/*-ucode.img e adiciona a linha initrd correspondente sozinho.
#
# Em CPUs Intel também instala e habilita o thermald (gerenciamento térmico,
# importante em notebooks e mini-PCs Intel).
#
# Overrides do usuário:
#   MICROCODE=0   nunca instala microcódigo
#   THERMALD=0    não instala/habilita o thermald em CPUs Intel
#
# Modo offline: pacotes em $PAYLOAD_DIR/pkgs/microcode/
#
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ ${MICROCODE:-} != 0 ]] || hskip "MICROCODE=0 - pulando microcódigo"

vendor="$(cpu_vendor)"
case "$vendor" in
  GenuineIntel) ucode="intel-ucode" ;;
  AuthenticAMD) ucode="amd-ucode"   ;;
  *)            hskip "Fabricante de CPU '${vendor:-desconhecido}' sem pacote de microcódigo - pulando" ;;
esac

hlog "CPU: ${vendor} - $(cpu_model)"
hlog "Instalando $ucode no partset $PARTSET"

extra=""
if [[ $vendor = GenuineIntel && ${THERMALD:-} != 0 ]]; then
  extra="thermald"
fi

stage_pkgs microcode || true

in_target <<TARGET
unlock_rootfs

pkg_install_local microcode || pkg_install $ucode $extra || true

$( [[ -n $extra ]] && echo 'enable_service thermald.service' || true )

if [ -f /boot/${ucode}.img ]; then
  tlog "microcódigo presente: /boot/${ucode}.img"
else
  tlog "aviso: /boot/${ucode}.img não encontrado após a instalação"
fi

lock_rootfs
tlog "microcódigo: concluído"
TARGET
