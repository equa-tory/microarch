# Customizing microarch

Every change below ends the same way: edit a file in this repo, then rebuild.

```
rm -rf /tmp/archiso-work   # mkarchiso's incremental-skip markers otherwise
                           # ignore changed airootfs files
./build.sh
```

## Add or remove a package

Edit `packages.x86_64` (one package per line, `#` comments out a line).
Rebuild.

## Add or change a file that ships out of the box

Everything under `airootfs/` is copied verbatim onto the live system's `/`.
Add or edit a file there at the same path it should have on the booted
system, then rebuild. Permissions/ownership other than the default (root,
`644`/`755` for dirs) are set in `profiledef.sh`'s `file_permissions` array —
add an entry there if a new file needs something else (a private key, a
setuid script, etc).

## Enable or disable a service

Services are enabled by a symlink under
`airootfs/etc/systemd/system/<target>.wants/<service>.service` pointing at
`/usr/lib/systemd/system/<service>.service` (or at a unit file you shipped
yourself next to it, for a custom service like `microarch-sync.service`).

- **Enable**: `ln -s /usr/lib/systemd/system/foo.service airootfs/etc/systemd/system/multi-user.target.wants/foo.service`
- **Disable**: delete that symlink.

`frpc.service` is the example of a service that's installed but disabled —
its unit file ships, but there's no `.wants` symlink for it.

## Change where authorized_keys / dotfiles come from

Both `build.sh` and `airootfs/usr/local/bin/microarch-sync` have a
`GH_USER="equa-tory"` line at the top — change it in both places (build-time
snapshot and every-boot refresh use the same source). The dotfiles repo name
(`dotfiles`) is otherwise hardcoded in the same two files if you want to
rename it there too.

## Add another synced git repo

Follow the same pattern as the dotfiles block in
`airootfs/usr/local/bin/microarch-sync`:

```bash
OTHER_DIR="/root/.config/something"
OTHER_REPO="https://github.com/${GH_USER}/something.git"
install -d -m 755 "$(dirname "${OTHER_DIR}")"
if [[ -d "${OTHER_DIR}/.git" ]]; then
    timeout 15 git -C "${OTHER_DIR}" pull --ff-only --quiet || true
else
    timeout 15 git clone --quiet --depth 1 "${OTHER_REPO}" "${OTHER_DIR}" || true
fi
```

Add the matching block to `build.sh` too if you want a snapshot baked into
the ISO (so it's present even offline on first boot), the same way
`dotfiles` is.

## Add a script you can run from anywhere

Drop it in your **dotfiles repo** under a `bin/` directory (e.g.
`dotfiles/bin/myscript`, executable). `airootfs/root/.bashrc` already puts
`~/.config/dotfiles/bin` on `PATH`, so the next time `microarch-sync` pulls
your dotfiles (every boot, if online), the script is runnable by name — no
ISO rebuild needed. This works on the live ISO and on anything installed
with `install.sh`.

If it needs to exist even fully offline on first boot, put it in
`airootfs/usr/local/bin/` in this repo instead and rebuild.

## Test in QEMU before burning a real disk

Boot the ISO headless with SSH forwarded:

```bash
qemu-img create -f qcow2 /tmp/mtest.qcow2 20G   # throwaway disk to install onto
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /tmp/mtest-vars.fd

qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 -enable-kvm \
  -drive if=pflash,format=raw,unit=0,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/mtest-vars.fd \
  -device virtio-scsi-pci,id=scsi0 \
  -drive id=cd0,if=none,format=raw,media=cdrom,readonly=on,file=out/microarch-*.iso \
  -device scsi-cd,bus=scsi0.0,drive=cd0 \
  -drive id=disk0,if=none,format=qcow2,file=/tmp/mtest.qcow2 \
  -device virtio-blk-pci,drive=disk0 \
  -boot order=d -netdev user,id=net0,hostfwd=tcp::60022-:22 \
  -device virtio-net-pci,netdev=net0 -nographic -serial mon:stdio
```

(`run_archiso -u -i out/microarch-*.iso` also works for a quick look with a
graphical window, but has no easy port-forward for a second disk.)

Log in (autologin on the console), run `/root/install.sh`, mark/delete
anything you want to test, install into the free space. Ctrl-A X quits QEMU.

Then boot the disk on its own to confirm it actually works:

```bash
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 -enable-kvm \
  -drive if=pflash,format=raw,unit=0,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/mtest-vars.fd \
  -drive id=disk0,if=none,format=qcow2,file=/tmp/mtest.qcow2 \
  -device virtio-blk-pci,drive=disk0 \
  -boot order=c -netdev user,id=net0,hostfwd=tcp::60022-:22 \
  -device virtio-net-pci,netdev=net0 -nographic -serial mon:stdio
```

`ssh -p 60022 root@localhost` to confirm it's really there. When you're
done, forget the whole thing ever existed:

```bash
rm -f /tmp/mtest.qcow2 /tmp/mtest-vars.fd
```
