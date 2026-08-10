# Universal SteamOS Installer

Instalador de SteamOS para **qualquer disco** (NVMe, SATA, eMMC, disco virtual)
rodando em cima da [SteamOS Repair Image](https://help.steampowered.com/pt/faqs/view/1B71-EDF2-EB6D-2BB3)
oficial da Valve — a rootfs instalada é sempre o SteamOS puro, sem imagem customizada.

> **AVISO:** este projeto é experimental e destrutivo por natureza (particiona e
> formata discos). Use por sua conta e risco, de preferência em máquina virtual
> ou hardware de teste.

## Como usar

1. Grave a SteamOS Repair Image oficial num pendrive e boote por ela.
2. Conecte na internet (Wi-Fi ou cabo).
3. Abra o Konsole e rode:

```bash
curl -sL https://raw.githubusercontent.com/Lynkes/SteamOS/main/bootstrap.sh | bash
```

O bootstrap baixa o instalador para `/home/deck/universal-installer` (persiste
no pendrive entre boots), cria um atalho no desktop da sessão live e abre o
menu de instalação.

## Ações disponíveis

| Alvo | Descrição |
|---|---|
| `menu` | menu interativo com as ações abaixo |
| `all` | apaga o disco selecionado e instala o SteamOS do zero |
| `system` | reinstala só as partições de sistema (preserva a home) |
| `home` | reformata as partições home (apaga jogos e dados) |
| `drivers` | (re)executa só os hooks de driver num sistema já instalado |
| `chroot` | abre um shell dentro do sistema instalado |
| `sanitize` | secure-erase do disco (NVMe sanitize / hdparm / blkdiscard) |

O seletor de discos lista NVMe, SATA, eMMC e discos virtuais, **escondendo o
disco do próprio instalador**. Funciona com zenity (GUI) ou em terminal puro.

## Hardware suportado

A rootfs gravada é sempre o SteamOS puro; o que adapta a instalação ao PC são
os hooks de pós-instalação, que detectam o hardware real via `lspci` /
`/proc/cpuinfo` e instalam só o que faz sentido.

**GPUs**

| Fabricante | Cobertura | Pacotes principais |
|---|---|---|
| Intel Gen 8+ | Broadwell → Alder/Raptor/Meteor Lake, Iris Xe | `mesa`, `vulkan-intel` (ANV), `intel-media-driver` (VAAPI iHD), `linux-firmware-intel` |
| Intel dedicadas | DG1, Arc A-series (DG2), Arc B-series (BMG) | idem + `i915.force_probe` / `xe.force_probe` com os device ids detectados |
| Intel Gen 5–7.5 | Ironlake, Sandy/Ivy Bridge, Haswell, Bay Trail | `mesa` (crocus) + `libva-intel-driver` (VAAPI i965) |
| AMD GCN 2+ / RDNA | Polaris, Vega, RDNA 1–4 | `mesa`, `vulkan-radeon` (RADV), `libva-mesa-driver`, `mesa-vdpau`, `linux-firmware-amdgpu` |
| AMD GCN 1.0/1.1 | Tahiti, Pitcairn, Bonaire, Hawaii, Kaveri… | idem + `amdgpu.si_support=1` / `cik_support=1` (troca o driver `radeon` pelo `amdgpu`) |
| AMD pré-GCN | TeraScale (HD 2000–6000) | `mesa` + driver `radeon` (só OpenGL, sem Vulkan) |
| NVIDIA Turing+ | GTX 16xx, RTX 20xx→50xx | `nvidia-dkms` (ou `nvidia-open-dkms`), `nvidia-utils`, `lib32-nvidia-utils` |
| NVIDIA Maxwell/Pascal | GTX 9xx / 10xx | `nvidia-dkms` (ramo legado) |
| NVIDIA Kepler e anteriores | GTX 6xx/7xx e mais antigas | avisa que precisa de `nvidia-470xx-dkms`/`390xx` (AUR ou vendorizado) |
| Híbrido (iGPU + NVIDIA) | notebooks Optimus | acrescenta `nvidia-prime` para render offload |

**CPUs**

| Fabricante | O que é feito |
|---|---|
| Intel | `intel-ucode` + `thermald` habilitado (gerenciamento térmico) |
| AMD | `amd-ucode` |

O microcódigo entra no boot automaticamente: o `update-grub` executado na
finalização detecta o `/boot/*-ucode.img` e gera a linha `initrd` correta.

Já tem o SteamOS instalado e só quer os drivers? Use o alvo `drivers`, que
reexecuta os hooks nos dois partsets e regenera o boot, sem apagar nada.

## Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `DISK=/dev/sdX` | pula o seletor de disco |
| `NOPROMPT=1` | pula as confirmações |
| `POWEROFF=1` | desliga em vez de reiniciar ao final |
| `NVIDIA=0` / `NVIDIA=1` | nunca / sempre instala o driver NVIDIA |
| `NVIDIA_OPEN=1` | usa `nvidia-open-dkms` (módulos abertos, Turing+) |
| `NVIDIA_PKG=...` | força o nome do pacote do driver (ex.: `nvidia-470xx-dkms`) |
| `INTEL_GPU=0` / `=1` | nunca / sempre instala o stack Intel |
| `INTEL_ENABLE_GUC=1` | liga `i915.enable_guc=3` (GuC/HuC em Gen 9–11) |
| `INTEL_FORCE_PROBE=1` | aplica `i915.force_probe` também em GPUs integradas |
| `AMD_GPU=0` / `=1` | nunca / sempre instala o stack AMD (por padrão pula em Steam Deck) |
| `AMD_LEGACY=1` | força os parâmetros `si_support`/`cik_support` do amdgpu |
| `MICROCODE=0` | não instala microcódigo de CPU |
| `THERMALD=0` | não instala/habilita o thermald em CPUs Intel |

Exemplo de instalação não interativa:

```bash
sudo DISK=/dev/sda NOPROMPT=1 ./REPAIRDEVICE_NEW.sh all
```

Exemplo: só reinstalar drivers num sistema existente, sem tocar em NVIDIA:

```bash
sudo DISK=/dev/nvme0n1 NOPROMPT=1 NVIDIA=0 ./REPAIRDEVICE_NEW.sh drivers
```

## Layout do repositório

```
bootstrap.sh                # one-liner de entrada: baixa e executa
REPAIRDEVICE_NEW.sh         # motor de instalação (deriva do repair_device.sh da Valve)
postinstall/                # hooks executados após a imagem, por partset (A e B)
  _common.sh                # biblioteca compartilhada (não é hook)
  10-microcode.sh           # intel-ucode / amd-ucode (+ thermald em Intel)
  20-intel-gpu.sh           # Mesa / Vulkan / VA-API Intel, incl. Arc dedicadas
  30-amd-gpu.sh             # Mesa / RADV / VA-API AMD, incl. GCN 1.x e TeraScale
  40-nvidia.sh              # driver NVIDIA proprietário, por geração da placa
universal-installer.desktop # atalho para o desktop da sessão live
pkgs/                       # (opcional) .pkg.tar.zst vendorizados p/ install offline
```

### Hooks de pós-instalação

Todo script `postinstall/*.sh` roda uma vez por partset (em ordem alfabética,
daí os prefixos numéricos) após a rootfs ser gravada, recebendo por ambiente:
`DISK`, `DISK_SUFFIX`, `PARTSET`, `TARGET_ROOT_DEV`, `PAYLOAD_DIR` e
`POSTINSTALL_DIR`. Arquivos começando com `_` são bibliotecas e **não** são
executados como hook.

O próprio hook decide se é aplicável (todos verificam `lspci` /
`/proc/cpuinfo`) e sai com 0 quando não for. Falha de hook gera aviso mas não
aborta a instalação.

Para escrever um hook novo, comece por:

```bash
#!/bin/bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

has_gpu 'Matrox' || hskip "sem GPU Matrox - pulando"

stage_pkgs matrox || true
in_target <<'TARGET'
unlock_rootfs
pkg_install xf86-video-mga || true
add_cmdline algum.parametro=1
lock_rootfs
TARGET
```

O `_common.sh` oferece, do lado do instalador, `gpu_devices`, `has_gpu`,
`gpu_device_ids <vendor>`, `cpu_vendor`, `cpu_model`, `stage_pkgs` e
`in_target`; e dentro do chroot `unlock_rootfs`/`lock_rootfs`, `pkg_install`,
`pkg_install_local`, `kernel_headers`, `add_cmdline`, `rebuild_initramfs` e
`enable_service`.

### Instalação offline de drivers

Os repositórios da Valve não têm tudo (`nvidia-dkms`, por exemplo). Por padrão
os hooks tentam `pacman -Sy` dentro do chroot (precisa de rede). Para não
depender disso, baixe os pacotes uma vez e deixe no pendrive, num subdiretório
por hook:

```
pkgs/
  microcode/   intel-ucode / amd-ucode
  intel/       mesa, vulkan-intel, intel-media-driver, lib32-*
  amd/         mesa, vulkan-radeon, libva-mesa-driver, lib32-*
  nvidia/      nvidia-dkms, nvidia-utils, lib32-nvidia-utils, linux-neptune-*-headers
```

O hook detecta os `.pkg.tar.zst` do seu subdiretório e instala com `pacman -U`,
offline — nesse caso ele nem tenta a rede. Pacotes soltos direto em `pkgs/`
continuam funcionando para o hook NVIDIA (comportamento antigo).

## Testando em VM (recomendado)

```bash
qemu-img create -f qcow2 alvo.qcow2 64G
qemu-system-x86_64 -enable-kvm -m 8G -cpu host \
  -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive file=steamdeck-recovery.img,format=raw,if=virtio \
  -drive file=alvo.qcow2,if=virtio \
  -vga virtio -display gtk
```

O seletor de discos reconhece os discos virtio (`vd*`) normalmente.

## Créditos

Baseado no `repair_device.sh` da SteamOS Repair Image (Valve). Projetos
relacionados que valem estudo: [HoloISO](https://github.com/HoloISO/holoiso),
[Bazzite](https://bazzite.gg/) e [ChimeraOS](https://chimeraos.org/).
