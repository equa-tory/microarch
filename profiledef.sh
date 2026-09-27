#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="microarch"
iso_label="MICROARCH_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="microarch <https://github.com/equa-tory/microarch>"
iso_application="microarch minimal live ISO"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=(xz -9e)
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.ssh"]="0:0:700"
  ["/root/.ssh/authorized_keys"]="0:0:600"
  ["/root/install.sh"]="0:0:755"
  ["/usr/local/bin/microarch-sync"]="0:0:755"
  ["/usr/local/bin/frpc"]="0:0:755"
)
