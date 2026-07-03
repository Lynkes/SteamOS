#!/bin/bash
#
# Universal SteamOS Installer - bootstrap
#
# Rode na sessao live da SteamOS Repair Image oficial da Valve:
#
#   curl -sL https://raw.githubusercontent.com/Lynkes/SteamOS/main/bootstrap.sh | bash
#
# Baixa o instalador para /home/deck/universal-installer (partição home do
# pendrive - persiste entre boots e NÃO é copiada para o disco alvo) e abre
# o menu de instalação.
#
set -eu

REPO="Lynkes/SteamOS"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-/home/deck/universal-installer}"

echo ":: Downloading $REPO ($BRANCH) to $DEST"
mkdir -p "$DEST"
curl -#L "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar xz --strip-components=1 -C "$DEST"

chmod +x "$DEST"/*.sh "$DEST"/postinstall/*.sh 2>/dev/null || true

# Atalho no desktop da sessão live (persiste no pendrive)
if [[ -d /home/deck/Desktop && -f "$DEST/universal-installer.desktop" ]]; then
  cp "$DEST/universal-installer.desktop" /home/deck/Desktop/
  chmod +x /home/deck/Desktop/universal-installer.desktop
fi

echo ":: Done. Starting installer menu..."
exec sudo "$DEST/REPAIRDEVICE_NEW.sh" menu
