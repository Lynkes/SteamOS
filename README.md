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
| `chroot` | abre um shell dentro do sistema instalado |
| `sanitize` | secure-erase do disco (NVMe sanitize / hdparm / blkdiscard) |

O seletor de discos lista NVMe, SATA, eMMC e discos virtuais, **escondendo o
disco do próprio instalador**. Funciona com zenity (GUI) ou em terminal puro.

## Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `DISK=/dev/sdX` | pula o seletor de disco |
| `NOPROMPT=1` | pula as confirmações |
| `POWEROFF=1` | desliga em vez de reiniciar ao final |
| `NVIDIA=0` / `NVIDIA=1` | nunca / sempre instala driver NVIDIA |

Exemplo de instalação não interativa:

```bash
sudo DISK=/dev/sda NOPROMPT=1 ./REPAIRDEVICE_NEW.sh all
```

## Layout do repositório

```
bootstrap.sh                # one-liner de entrada: baixa e executa
REPAIRDEVICE_NEW.sh         # motor de instalação (deriva do repair_device.sh da Valve)
postinstall/                # hooks executados após a imagem, por partset (A e B)
  nvidia.sh                 # driver NVIDIA proprietário (detecta GPU via lspci)
universal-installer.desktop # atalho para o desktop da sessão live
pkgs/                       # (opcional) .pkg.tar.zst vendorizados p/ install offline
```

### Hooks de pós-instalação

Todo script executável em `postinstall/*.sh` roda uma vez por partset após a
rootfs ser gravada, recebendo por ambiente: `DISK`, `DISK_SUFFIX`, `PARTSET`,
`TARGET_ROOT_DEV` e `PAYLOAD_DIR`. O próprio hook decide se é aplicável
(ex.: `nvidia.sh` verifica `lspci`) e sai com 0 quando não for. Falha de hook
gera aviso mas não aborta a instalação.

### Instalação offline de drivers

Os repositórios da Valve não têm `nvidia-dkms`. Por padrão o hook tenta
`pacman -Sy` dentro do chroot (precisa de rede e repos Arch). Para não depender
disso, baixe os pacotes uma vez e deixe no pendrive:

```bash
mkdir -p /home/deck/universal-installer/pkgs
# baixe de um mirror Arch: nvidia-dkms, nvidia-utils, lib32-nvidia-utils,
# linux-neptune-*-headers (compatíveis com a versão do SteamOS da imagem)
```

O hook detecta os `.pkg.tar.zst` e instala com `pacman -U`, offline.

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
