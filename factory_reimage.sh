#!/bin/bash

set -euo pipefail

[[ ${EUID-} = 0 ]] || exec sudo -- "$0" "$@"

export POWEROFF=1 # Shutdown rather than reboot as final step
export NOPROMPT=1 # Don't prompt in general
export REBOOTPROMPT=0 # Explicit prompt at shutdown/reboot step
export FORCEBIOS=1 # Pass --force to reflash existing bios if possible

"${BASH_SOURCE[0]%/*}"/repair_device.sh sanitize
"${BASH_SOURCE[0]%/*}"/repair_device.sh all
