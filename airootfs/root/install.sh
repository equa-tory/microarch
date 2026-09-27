#!/usr/bin/env bash
# microarch installer: pacstrap-free copy of the live system onto a NEW
# ESP + root partition, created only in the disk's *unallocated* space
# (GPT/UEFI only). Never touches existing partitions unless you explicitly
# mark them for deletion and then confirm the install.
#
# Controls: up/down move, enter selects/marks, right+enter confirms install,
# esc/left goes back, q quits.
set -o pipefail
# Note: deliberately not `set -u` — bash treats a still-empty associative
# array (like MARKED below) as "unbound" under nounset, which would abort
# the very first draw of the menu.

[[ ${EUID} -eq 0 ]] || { echo "Run as root."; exit 1; }

BOOT_SRC="/run/archiso/airootfs"
ESP_SIZE_MIB=512
HEADROOM_MIB=1024
SECTOR_ALIGN=2048   # 1 MiB in 512B sectors

# ------------------------------------------------------------------ helpers
die() { tput cnorm 2>/dev/null; echo -e "\n$*" >&2; exit 1; }
mib() { echo $(( $1 / 1024 / 1024 )); }
bytes_h() {
    local b=$1
    awk -v b="$b" 'BEGIN{
        split("B KiB MiB GiB TiB", u, " ");
        i=1; v=b;
        while (v>=1024 && i<5) { v/=1024; i++ }
        printf "%.1f %s", v, u[i]
    }'
}

# boot device: the disk the live ISO is actually running from — never a
# target for install or deletion.
boot_disk() {
    local src
    src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)"
    [[ -n "${src}" ]] || return 0
    lsblk -no PKNAME "${src}" 2>/dev/null | head -1
}
BOOT_DISK="$(boot_disk)"

# -------------------------------------------------------------- disk layout
# Fills the parallel ROW_* arrays with one entry per disk / partition / free
# gap, in display order. sfdisk -d gives partition start+size in sectors,
# which we use to compute free gaps ourselves (more predictable to parse
# than sfdisk -F's text table).
declare -a ROW_TYPE ROW_DEV ROW_TEXT ROW_START ROW_SIZE ROW_SELECTABLE

build_rows() {
    ROW_TYPE=(); ROW_DEV=(); ROW_TEXT=(); ROW_START=(); ROW_SIZE=(); ROW_SELECTABLE=()
    local disk
    while IFS= read -r disk; do
        [[ -n "${disk}" ]] || continue
        local size pttype
        size=$(lsblk -ndbo SIZE "${disk}")
        pttype=$(lsblk -ndo PTTYPE "${disk}")
        local is_boot=0
        [[ "$(basename "${disk}")" == "${BOOT_DISK}" ]] && is_boot=1

        ROW_TYPE+=("disk"); ROW_DEV+=("${disk}")
        ROW_TEXT+=("$(basename "${disk}")  $(bytes_h "${size}")  ${pttype:-no partition table}$([[ ${is_boot} -eq 1 ]] && echo '  [boot medium]')")
        ROW_START+=(0); ROW_SIZE+=("${size}"); ROW_SELECTABLE+=(0)

        if [[ ${is_boot} -eq 1 ]]; then
            continue   # the disk we booted from: show only, skip layout
        fi
        if [[ -n "${pttype}" && "${pttype}" != "gpt" ]]; then
            continue   # an existing non-GPT table (e.g. MBR): show only, don't touch
        fi
        # pttype is "gpt", or empty (a brand-new/blank disk) — lay it out.
        # A blank disk gets a fresh GPT label at install time (see do_install).

        # existing partitions, sorted by start sector
        local sectsize secttotal
        sectsize=$(blockdev --getss "${disk}")
        secttotal=$(blockdev --getsz "${disk}")

        local -a starts sizes names
        starts=(); sizes=(); names=()
        while IFS= read -r line; do
            [[ "${line}" =~ ^${disk}p?([0-9]+)\ *:\ *start=\ *([0-9]+),\ *size=\ *([0-9]+) ]] || continue
            names+=("${disk}$([[ "${disk}" =~ [0-9]$ ]] && echo p)${BASH_REMATCH[1]}")
            starts+=("${BASH_REMATCH[2]}")
            sizes+=("${BASH_REMATCH[3]}")
        done < <(sfdisk -d "${disk}" 2>/dev/null | grep -E "^${disk}p?[0-9]+ *:")

        # sort the three arrays together by start
        local -a order
        mapfile -t order < <(for i in "${!starts[@]}"; do echo "${starts[$i]} $i"; done | sort -n | awk '{print $2}')

        local cursor=34   # first usable LBA on a GPT disk (34 = 1 + 32 header/table sectors +1 slack... use conservative default)
        cursor=${SECTOR_ALIGN}
        local i idx
        for i in "${!order[@]}"; do
            idx=${order[$i]}
            local pstart=${starts[$idx]} psize=${sizes[$idx]} pname=${names[$idx]}
            local gap=$(( pstart - cursor ))
            if (( gap > 0 )); then
                add_free_row "${disk}" "${cursor}" "${gap}" "${sectsize}" "${is_boot}"
            fi
            local label mnt fstype
            label=$(lsblk -ndo PARTLABEL "${pname}" 2>/dev/null)
            fstype=$(lsblk -ndo FSTYPE "${pname}" 2>/dev/null)
            mnt=$(lsblk -ndo MOUNTPOINT "${pname}" 2>/dev/null)
            local mark=""
            [[ -n "${MARKED[${pname}]:-}" ]] && mark="[DEL] "
            ROW_TYPE+=("part"); ROW_DEV+=("${pname}")
            ROW_TEXT+=("  ${mark}$(basename "${pname}")  $(bytes_h $(( psize * sectsize )))  ${fstype:-?}  ${label}${mnt:+ (mounted at ${mnt})}")
            ROW_START+=("${pstart}"); ROW_SIZE+=("${psize}")
            if [[ -n "${mnt}" || ${is_boot} -eq 1 ]]; then
                ROW_SELECTABLE+=(0)
            else
                ROW_SELECTABLE+=(1)
            fi
            cursor=$(( pstart + psize ))
            # round cursor up to alignment for the next gap's start
            cursor=$(( ( (cursor + SECTOR_ALIGN - 1) / SECTOR_ALIGN ) * SECTOR_ALIGN ))
        done
        local tailgap=$(( (secttotal - 34) - cursor ))
        (( tailgap > 0 )) && add_free_row "${disk}" "${cursor}" "${tailgap}" "${sectsize}" "${is_boot}"
    done < <(lsblk -ndo PATH -e7,11 | grep -v "^/dev/zram")
}

add_free_row() {
    local disk=$1 start=$2 sectors=$3 sectsize=$4 is_boot=$5
    local size=$(( sectors * sectsize ))
    (( size < 16 * 1024 * 1024 )) && return   # ignore slivers under 16 MiB
    ROW_TYPE+=("free"); ROW_DEV+=("${disk}")
    ROW_TEXT+=("  free space  $(bytes_h "${size}")")
    ROW_START+=("${start}"); ROW_SIZE+=("${sectors}")
    if [[ ${is_boot} -eq 1 || ${size} -lt ${REQUIRED_BYTES} ]]; then
        ROW_SELECTABLE+=(0)
    else
        ROW_SELECTABLE+=(1)
    fi
}

# ------------------------------------------------------------- required size
required_bytes() {
    local used
    used=$(df -B1 --output=used / | tail -1 | tr -d ' ')
    echo $(( used + ESP_SIZE_MIB*1024*1024 + HEADROOM_MIB*1024*1024 ))
}
REQUIRED_BYTES=$(required_bytes)

declare -A MARKED   # partition path -> 1, marked for deletion

# ------------------------------------------------------------------ network
have_ethernet() {
    ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -qE '^(en|eth)'
}

wifi_setup() {
    command -v iwctl >/dev/null || return 0
    local dev
    dev=$(iwctl device list 2>/dev/null | awk '/wlan|station/{print $2; exit}')
    [[ -n "${dev}" ]] || dev=$(iwctl device list 2>/dev/null | awk 'NR>4{print $2; exit}')
    [[ -n "${dev}" ]] || { echo "No wifi device found, skipping."; return 0; }

    echo "Scanning for wifi networks..."
    iwctl station "${dev}" scan >/dev/null 2>&1
    sleep 3
    local -a nets
    mapfile -t nets < <(iwctl station "${dev}" get-networks 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*m//g' \
        | awk 'NR>4 && NF>2 {sub(/^>/,""); $1=$1; ssid=""; for(i=1;i<NF-1;i++) ssid=ssid $i " "; print ssid}' \
        | sed 's/ *$//' | grep -v '^$' | sort -u)
    nets+=("Skip Wi-Fi setup")

    local choice
    choice=$(arrow_menu "No wired ethernet detected — choose a Wi-Fi network" "${nets[@]}")
    [[ "${choice}" == "Skip Wi-Fi setup" || -z "${choice}" ]] && return 0

    local pass
    read -rsp "Password for '${choice}' (blank if open): " pass; echo
    if [[ -n "${pass}" ]]; then
        iwctl --passphrase "${pass}" station "${dev}" connect "${choice}"
    else
        iwctl station "${dev}" connect "${choice}"
    fi
    echo "Waiting for a connection..."
    for _ in $(seq 1 15); do
        ip route show default 2>/dev/null | grep -q default && break
        sleep 1
    done
}

# ----------------------------------------------------------------- TUI core
# Simple arrow-key menu over a list of plain strings; prints the chosen
# string to stdout. Returns empty on Esc/q.
arrow_menu() {
    local title=$1; shift
    local -a items=("$@")
    local sel=0 key k1 k2
    tput civis 2>/dev/null
    while true; do
        clear
        echo "${title}"
        echo
        local i
        for i in "${!items[@]}"; do
            if [[ ${i} -eq ${sel} ]]; then
                echo " > ${items[$i]}"
            else
                echo "   ${items[$i]}"
            fi
        done
        echo
        echo "(up/down move, enter select, q cancel)"
        IFS= read -rsn1 key
        if [[ "${key}" == $'\x1b' ]]; then
            read -rsn1 -t 0.2 k1; read -rsn1 -t 0.2 k2
            case "${k1}${k2}" in
                '[A'|'OA') (( sel = (sel - 1 + ${#items[@]}) % ${#items[@]} )) ;;
                '[B'|'OB') (( sel = (sel + 1) % ${#items[@]} )) ;;
            esac
        elif [[ "${key}" == "" ]]; then
            tput cnorm 2>/dev/null
            echo "${items[$sel]}"
            return 0
        elif [[ "${key}" == "q" ]]; then
            tput cnorm 2>/dev/null
            echo ""
            return 1
        fi
    done
}

# Two-choice confirm bar: [Cancel] [Install] — right arrow highlights
# Install, enter activates the highlighted choice. Returns 0 for Install.
confirm_bar() {
    local sel=0   # 0 = Cancel, 1 = Install
    local key k1 k2
    tput civis 2>/dev/null
    while true; do
        printf '\r'
        if [[ ${sel} -eq 0 ]]; then
            printf ' [ Cancel ] <   Install  '
        else
            printf '   Cancel   <  [ Install ]'
        fi
        IFS= read -rsn1 key
        if [[ "${key}" == $'\x1b' ]]; then
            read -rsn1 -t 0.2 k1; read -rsn1 -t 0.2 k2
            case "${k1}${k2}" in
                '[C'|'OC') sel=1 ;;   # right
                '[D'|'OD') sel=0 ;;   # left
            esac
        elif [[ "${key}" == "" ]]; then
            echo
            tput cnorm 2>/dev/null
            [[ ${sel} -eq 1 ]] && return 0 || return 1
        elif [[ "${key}" == "q" ]]; then
            echo; tput cnorm 2>/dev/null; return 1
        fi
    done
}

# ------------------------------------------------------------- main browser
main_menu() {
    local cursor=0
    while true; do
        build_rows
        local -a sel_idx
        sel_idx=()
        local i
        for i in "${!ROW_TYPE[@]}"; do
            [[ ${ROW_SELECTABLE[$i]} -eq 1 ]] && sel_idx+=("${i}")
        done
        (( cursor >= ${#sel_idx[@]} )) && cursor=$(( ${#sel_idx[@]} - 1 ))
        (( cursor < 0 )) && cursor=0

        clear
        echo "microarch installer — required space: $(bytes_h "${REQUIRED_BYTES}")"
        echo "up/down move · enter mark partition / install into free space · q quit"
        echo
        for i in "${!ROW_TYPE[@]}"; do
            local marker="  "
            if [[ ${#sel_idx[@]} -gt 0 && ${i} -eq ${sel_idx[$cursor]:- -1} ]]; then
                marker=" >"
            fi
            if [[ ${ROW_SELECTABLE[$i]} -eq 1 ]]; then
                echo "${marker} ${ROW_TEXT[$i]}"
            else
                echo "   ${ROW_TEXT[$i]}"
            fi
        done
        echo
        if [[ ${#MARKED[@]} -gt 0 ]]; then
            echo "Marked for deletion: ${!MARKED[*]}"
        fi
        [[ ${#sel_idx[@]} -eq 0 ]] && echo "Nothing selectable — free some space or delete a partition." && \
            { echo "(q to quit)"; }

        local key k1 k2
        tput civis 2>/dev/null
        IFS= read -rsn1 key
        tput cnorm 2>/dev/null
        case "${key}" in
            $'\x1b')
                read -rsn1 -t 0.2 k1; read -rsn1 -t 0.2 k2
                case "${k1}${k2}" in
                    '[A'|'OA') (( cursor = (cursor - 1 + ${#sel_idx[@]}) % ${#sel_idx[@]} )) 2>/dev/null ;;
                    '[B'|'OB') (( cursor = (cursor + 1) % ${#sel_idx[@]} )) 2>/dev/null ;;
                esac
                ;;
            "")
                [[ ${#sel_idx[@]} -eq 0 ]] && continue
                local idx=${sel_idx[$cursor]}
                if [[ "${ROW_TYPE[$idx]}" == "part" ]]; then
                    handle_partition "${ROW_DEV[$idx]}"
                elif [[ "${ROW_TYPE[$idx]}" == "free" ]]; then
                    handle_free "${idx}"
                fi
                ;;
            q) return 1 ;;
        esac
    done
}

handle_partition() {
    local dev=$1
    if [[ -n "${MARKED[${dev}]:-}" ]]; then
        unset -v "MARKED[${dev}]"
        return
    fi
    echo
    read -rp "Type '$(basename "${dev}")' to mark it for deletion (empty to cancel): " typed
    [[ "${typed}" == "$(basename "${dev}")" ]] && MARKED["${dev}"]=1
}

handle_free() {
    local idx=$1
    local disk=${ROW_DEV[$idx]} start=${ROW_START[$idx]} sectors=${ROW_SIZE[$idx]}
    local sectsize; sectsize=$(blockdev --getss "${disk}")
    local free_bytes=$(( sectors * sectsize ))

    clear
    echo "Install into: $(basename "${disk}") free space, $(bytes_h "${free_bytes}")"
    echo "Required:     $(bytes_h "${REQUIRED_BYTES}")"
    echo
    if [[ ${#MARKED[@]} -gt 0 ]]; then
        echo "Partitions that will be DELETED first:"
        local d
        for d in "${!MARKED[@]}"; do echo "  - ${d}"; done
        echo
    fi
    echo "New partitions to create in the free space:"
    echo "  - ${disk}(new ESP)   ${ESP_SIZE_MIB} MiB, FAT32"
    echo "  - ${disk}(new root)  $(bytes_h $(( free_bytes - ESP_SIZE_MIB*1024*1024 ))), ext4"
    echo

    local rootpass
    read -rsp "Root password for the installed system (blank = SSH keys only, no console password): " rootpass
    echo
    echo
    echo "Ready?"
    if confirm_bar; then
        do_install "${disk}" "${start}" "${sectors}" "${sectsize}" "${rootpass}"
        echo
        read -rp "Press enter to exit." _
        exit 0
    fi
}

# --------------------------------------------------------------------- doit
do_install() {
    local disk=$1 start=$2 sectors=$3 sectsize=$4 rootpass=$5
    set -e
    trap 'echo "Install failed." >&2' ERR

    echo "==> Deleting marked partitions..."
    local d partnum
    for d in "${!MARKED[@]}"; do
        partnum=$(grep -oE '[0-9]+$' <<< "${d}")
        sfdisk --delete "${disk}" "${partnum}"
    done
    partprobe "${disk}" 2>/dev/null || true
    udevadm settle

    if [[ -z "$(blkid -o value -s PTTYPE "${disk}" 2>/dev/null)" ]]; then
        echo "==> ${disk} has no partition table — creating a fresh GPT label..."
        printf 'label: gpt\n' | sfdisk "${disk}"
        partprobe "${disk}" 2>/dev/null || true
        udevadm settle
    fi

    echo "==> Creating ESP + root partition in the free space..."
    local esp_sectors=$(( ESP_SIZE_MIB * 1024 * 1024 / sectsize ))
    local esp_start=${start}
    local root_start=$(( esp_start + esp_sectors ))
    local root_sectors=$(( sectors - esp_sectors ))

    sfdisk --append "${disk}" <<EOF
start=${esp_start}, size=${esp_sectors}, type=uefi, name="microarch-esp"
start=${root_start}, size=${root_sectors}, type=linux, name="microarch-root"
EOF
    partprobe "${disk}" 2>/dev/null || true
    udevadm settle
    sleep 1

    local sep=""
    [[ "${disk}" =~ [0-9]$ ]] && sep="p"
    local esp_part root_part
    esp_part=$(lsblk -no PATH "${disk}" | grep -E "${disk}${sep}[0-9]+$" | tail -2 | head -1)
    root_part=$(lsblk -no PATH "${disk}" | grep -E "${disk}${sep}[0-9]+$" | tail -1)

    echo "==> Formatting ${esp_part} (FAT32) and ${root_part} (ext4)..."
    mkfs.fat -F32 -n MICROARCH "${esp_part}"  # FAT labels cap at 11 chars
    mkfs.ext4 -F -L microarch "${root_part}"

    echo "==> Mounting and copying the live system..."
    mount "${root_part}" /mnt
    mkdir -p /mnt/boot
    mount "${esp_part}" /mnt/boot
    cp -a "${BOOT_SRC}/." /mnt/

    echo "==> Fixing up the installed copy..."
    rm -f /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
    rmdir /mnt/etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
    rm -f /mnt/etc/systemd/system/multi-user.target.wants/pacman-init.service
    # mkinitcpio.conf.d/*.conf drop-ins apply unconditionally to every
    # preset (like systemd .conf.d snippets) — the archiso HOOKS override
    # must go, or the installed system's initramfs tries to mount a
    # squashfs boot medium that doesn't exist.
    rm -f /mnt/etc/mkinitcpio.conf.d/archiso.conf
    rmdir /mnt/etc/mkinitcpio.conf.d 2>/dev/null || true
    rm -f /mnt/etc/mkinitcpio.d/linux-lts.preset
    cat > /mnt/etc/mkinitcpio.d/linux-lts.preset <<'PRESET'
PRESETS=('default')
ALL_kver="/boot/vmlinuz-linux-lts"
default_image="/boot/initramfs-linux-lts.img"
PRESET

    local kver
    kver=$(basename "$(find /usr/lib/modules -maxdepth 1 -name '*-lts' | head -1)")
    cp "/usr/lib/modules/${kver}/vmlinuz" /mnt/boot/vmlinuz-linux-lts

    arch-chroot /mnt /usr/bin/mkinitcpio -p linux-lts
    arch-chroot /mnt /usr/bin/pacman-key --init
    arch-chroot /mnt /usr/bin/pacman-key --populate archlinux

    genfstab -U /mnt >> /mnt/etc/fstab

    echo "==> Installing Limine..."
    local root_uuid
    root_uuid=$(blkid -s PARTUUID -o value "${root_part}")
    mkdir -p /mnt/boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI
    cat > /mnt/boot/EFI/BOOT/limine.conf <<EOF2
timeout: 0

/microarch
    protocol: linux
    path: boot():/vmlinuz-linux-lts
    module_path: boot():/initramfs-linux-lts.img
    cmdline: root=PARTUUID=${root_uuid} rw console=tty0 console=ttyS0,115200n8 quiet
EOF2

    if [[ -n "${rootpass}" ]]; then
        echo "root:${rootpass}" | arch-chroot /mnt /usr/bin/chpasswd
    else
        arch-chroot /mnt /usr/bin/passwd -d root
    fi

    if ip route show default 2>/dev/null | grep -q default; then
        echo "==> Online: updating packages..."
        arch-chroot /mnt /usr/bin/pacman -Syu --noconfirm || echo "pacman update failed, continuing"
    fi

    rm -f /mnt/root/install.sh

    echo "==> Unmounting..."
    umount -R /mnt

    echo
    echo "Done. Remove the installation media and reboot."
}

# ---------------------------------------------------------------------- run
[[ "$(uname -m)" == "x86_64" ]] || die "x86_64 only."
[[ -d /sys/firmware/efi ]] || die "This installer requires UEFI boot (it writes Limine as a UEFI bootloader). BIOS/legacy targets are not supported."

have_ethernet || wifi_setup
main_menu
