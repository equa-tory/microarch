# microarch

Minimal CLI-only Arch Linux live ISO, based on archiso's `baseline` profile.
Boots BIOS or UEFI, runs as root, no GUI. Target: well under 1 GB.

## Packages

`base` `linux-lts` · `openssh` `iwd` `ufw` `curl` `wget` · `git` `github-cli`
`python` `fastfetch` `screen` `htop` `tar` `zoxide` `fd` `ripgrep` `neovim`
· firmware: `linux-firmware-intel` `linux-firmware-realtek` (edit
`packages.x86_64` to add more, e.g. amdgpu/atheros/broadcom).

## On boot

- Networking via `systemd-networkd` + `systemd-resolved` (DHCP, wired + wifi).
- `sshd`: key-only, root login only with a key. `authorized_keys` is seeded
  from https://github.com/equa-tory.keys and refreshed on every boot if
  there's a connection.
- shellrc is seeded from https://github.com/equa-tory/dotfiles (cloned to
  `~/.config/dotfiles`) and refreshed the same way.
- `ufw`: deny incoming, allow outgoing, allow 22/tcp.
- A root ed25519 SSH keypair is generated once (`/root/.ssh/id_ed25519`).
- `frpc` is installed but **disabled by default**. Edit
  `/etc/frp/frpc.toml` (proxies are commented out) and run
  `systemctl enable --now frpc` to use it.
- `cow_spacesize=2G` on both boot entries, so you can `pacman -S` things
  (e.g. a GUI) in the live session.

## Build

```
./build.sh
```
Refreshes `authorized_keys`/dotfiles (skipped if offline) and runs
`mkarchiso -v -w /tmp/archiso-work -o out/ .`. Needs `archiso` installed.

## Test

```
run_archiso -u -i out/microarch-*.iso   # UEFI
run_archiso -i out/microarch-*.iso      # BIOS
```

## Install to disk

The ISO ships `/root/install.sh`: an arrow-key installer (UEFI only) that
copies the live system onto a **new** ESP + root partition, created only in
a disk's unallocated free space — it never touches existing partitions
unless you explicitly mark one for deletion (by typing its exact name) and
then confirm.

Run it, pick a network if there's no ethernet, arrow down to a free-space
row, press enter, set an optional root password, then confirm with
right-arrow + enter. The installed system boots with **Limine** (the live
ISO itself still uses systemd-boot/syslinux — mkarchiso has no Limine boot
mode of its own).

## Customizing

See [GUIDE.md](GUIDE.md): adding packages, out-of-box files, services,
changing the authorized_keys/dotfiles source, syncing another repo, adding
a script usable anywhere, and testing in QEMU.
