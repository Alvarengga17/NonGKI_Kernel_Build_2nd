#!/usr/bin/env bash
# Adds CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER to an existing SUSFS v2.3.0 kernel + BakaSU.
# Idempotent. Any problem => exit 1 (the build stops here instead of producing a silently broken kernel).
set -euo pipefail

ACTION_DIR="$1"
cd "$GITHUB_WORKSPACE/device_kernel"
DEFCONFIG="arch/${KERNEL_ARCH}/configs/${DEFCONFIG_NAME}"

fail() { echo "[-] $*"; exit 1; }

echo "::group::[+] Pre-checks"
[ -f fs/susfs.c ] && [ -f include/linux/susfs.h ] || fail "SUSFS is not integrated in this kernel (fs/susfs.c missing)."
SUSFS_VER=$(grep -E '^#define SUSFS_VERSION' include/linux/susfs.h | cut -d' ' -f3 | tr -d '"')
echo "[+] SUSFS version in kernel: ${SUSFS_VER}"
[ "$SUSFS_VER" = "v2.3.0" ] || fail "This patch is for SUSFS v2.3.0 only (found: ${SUSFS_VER})."
[ -f drivers/kernelsu/Kconfig ] || fail "KernelSU (BakaSU) is not set up at drivers/kernelsu."
[ -f "$DEFCONFIG" ] || fail "defconfig not found: $DEFCONFIG"
command -v patch >/dev/null || fail "'patch' is not installed."
if ! command -v python3 >/dev/null 2>&1; then
  echo "[+] Installing python3..."
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y python3 >/dev/null
  elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm python >/dev/null
  fi
  command -v python3 >/dev/null || fail "python3 is not available."
fi
echo "::endgroup::"

echo "::group::[+] Kernel side (susfs.c / susfs.h / susfs_def.h / ioprio.c / sys.c)"
if grep -q "susfs_is_priority_uid_filtered" fs/susfs.c; then
  echo "[-] Kernel already contains PRIORITY_UID_FILTER, skipped."
else
  # -F0: no fuzz. Dry-run first so that a mismatch never leaves a half-patched tree.
  if ! patch -p1 -F0 --dry-run < "$ACTION_DIR/susfs-priority-uid-filter-kernel.patch"; then
    fail "Kernel patch does not apply cleanly (the kernel source changed?). Nothing was modified."
  fi
  patch -p1 -F0 --no-backup-if-mismatch < "$ACTION_DIR/susfs-priority-uid-filter-kernel.patch"
  echo "[+] Kernel side patched."
fi
echo "::endgroup::"

echo "::group::[+] BakaSU side (Kconfig / supercall / throne tracker)"
python3 -I "$ACTION_DIR/patch_bakasu.py" "$GITHUB_WORKSPACE/device_kernel/drivers/kernelsu"
echo "::endgroup::"

echo "::group::[+] defconfig"
# An earlier (buggy) step may have appended the bare line "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER" (no "=y"): remove it.
sed -i '/^CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER$/d' "$DEFCONFIG"
grep -q '^CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y$' "$DEFCONFIG" || echo "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y" >> "$DEFCONFIG"
grep -n "PRIORITY_UID_FILTER" "$DEFCONFIG"
echo "::endgroup::"

echo "::group::[+] Final verification"
chk() { grep -q "$2" "$1" || fail "verification failed: '$2' not found in $1"; echo "  ok: $1"; }
chk fs/susfs.c                                   "susfs_is_priority_uid_filtered"
chk fs/susfs.c                                   "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER"
chk include/linux/susfs.h                        "susfs_set_priority_uid_filter"
chk include/linux/susfs_def.h                    "CMD_SUSFS_SET_PRIORITY_UID_FILTER 0x60030"
chk block/ioprio.c                               "susfs_is_priority_uid_filtered"
chk kernel/sys.c                                 "susfs_is_priority_uid_filtered"
chk drivers/kernelsu/Kconfig                     "config KSU_SUSFS_PRIORITY_UID_FILTER"
chk drivers/kernelsu/supercall/dispatch.c        "CMD_SUSFS_SET_PRIORITY_UID_FILTER"
chk drivers/kernelsu/manager/throne_tracker.c    "susfs_parse_priority_app_strings"
if [ "$(grep -c 'susfs_is_priority_uid_filtered' block/ioprio.c)" -lt 3 ]; then fail "ioprio.c hooks incomplete"; fi
if [ "$(grep -c 'susfs_is_priority_uid_filtered' kernel/sys.c)" -lt 3 ]; then fail "sys.c hooks incomplete"; fi
find . -type f \( -name '*.rej' -o -name '*.orig' \) | grep . && fail "reject files found" || true
echo "::endgroup::"
echo "[+] SUSFS PRIORITY_UID_FILTER is ready."
