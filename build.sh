#!/usr/bin/env bash
# Build the microarch ISO. Refreshes the authorized_keys snapshot and the
# dotfiles checkout (best-effort, skipped if offline), then runs mkarchiso.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

GH_USER="equa-tory"
tmp_keys="$(mktemp)"
if curl -fsS --max-time 10 "https://github.com/${GH_USER}.keys" -o "${tmp_keys}" && grep -q '^ssh-' "${tmp_keys}"; then
    install -m 600 "${tmp_keys}" airootfs/root/.ssh/authorized_keys
    echo "build.sh: refreshed authorized_keys"
fi
rm -f "${tmp_keys}"

if [[ -d airootfs/root/.config/dotfiles/.git ]]; then
    git -C airootfs/root/.config/dotfiles pull --ff-only --quiet || echo "build.sh: dotfiles pull failed, keeping existing copy"
else
    mkdir -p airootfs/root/.config
    git clone --quiet --depth 1 "https://github.com/${GH_USER}/dotfiles.git" airootfs/root/.config/dotfiles \
        || echo "build.sh: no network, dotfiles will be pulled by microarch-sync on first boot instead"
fi

sudo mkarchiso -v -w /tmp/archiso-work -o out/ .
