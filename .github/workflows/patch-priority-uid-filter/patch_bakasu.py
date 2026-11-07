#!/usr/bin/env python3
# Adds CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER support to BakaSU (KernelSU side).
# Idempotent. Fails loudly (exit 1) when an anchor is missing, so a silent half-patch is impossible.
import sys, io

root = sys.argv[1]  # path of the KernelSU "kernel" directory (e.g. drivers/kernelsu)

def rd(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)

def die(msg):
    sys.stderr.write("[-] " + msg + "\n")
    sys.exit(1)

# 1) Kconfig ---------------------------------------------------------------
p = root + "/Kconfig"
s = rd(p)
if "KSU_SUSFS_PRIORITY_UID_FILTER" in s:
    print("[+] Kconfig: already patched, skipped")
else:
    a = s.find("config KSU_SUSFS_SUS_MAP")
    if a < 0:
        die("Kconfig: anchor 'config KSU_SUSFS_SUS_MAP' not found")
    b = s.find("\nendmenu", a)
    if b < 0:
        die("Kconfig: 'endmenu' after SUS_MAP not found")
    add = (
        "\nconfig KSU_SUSFS_PRIORITY_UID_FILTER\n"
        "    bool \"Enable hiding app uids from getpriority/setpriority/ioprio_get/ioprio_set\"\n"
        "    depends on KSU_SUSFS\n"
        "    default y\n"
        "    help\n"
        "        - Hide the uids of user-defined apps from detections that probe them with getpriority()/ioprio_get().\n"
        "        - The uids are resolved from the package names given by 'ksu_susfs set_priority_uid_filter'.\n"
        "        - Effective only on processes with uid >= 10000.\n"
    )
    s = s[:b] + add + s[b:]
    wr(p, s)
    print("[+] Kconfig: patched")

# 2) supercall/dispatch.c --------------------------------------------------
p = root + "/supercall/dispatch.c"
s = rd(p)
if "CMD_SUSFS_SET_PRIORITY_UID_FILTER" in s:
    print("[+] dispatch.c: already patched, skipped")
else:
    anchor = "    case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING: {"
    if s.count(anchor) != 1:
        die("dispatch.c: anchor for CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING not found exactly once")
    add = (
        "#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
        "    case CMD_SUSFS_SET_PRIORITY_UID_FILTER: {\n"
        "        susfs_set_priority_uid_filter(arg);\n"
        "        return 0;\n"
        "    }\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
    )
    s = s.replace(anchor, add + anchor)
    wr(p, s)
    print("[+] dispatch.c: patched")

# 3) manager/throne_tracker.c ---------------------------------------------
p = root + "/manager/throne_tracker.c"
s = rd(p)
if "susfs_parse_priority_app_strings" in s:
    print("[+] throne_tracker.c: already patched, skipped")
else:
    inc_anchor = '#include "compat/kernel_compat.h"\n'
    if s.count(inc_anchor) != 1:
        die("throne_tracker.c: include anchor not found exactly once")
    s = s.replace(inc_anchor, inc_anchor +
        "\n#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
        "#include <linux/susfs.h>\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n")
    call_anchor = "    revert_creds(old_cred);\n}\n\nvoid track_throne("
    if s.count(call_anchor) != 1:
        die("throne_tracker.c: end-of-do_track_throne anchor not found exactly once")
    s = s.replace(call_anchor,
        "    revert_creds(old_cred);\n"
        "#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
        "    // packages.list changed (install/uninstall): resolve the filtered uids again\n"
        "    susfs_parse_priority_app_strings();\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
        "}\n\nvoid track_throne(")
    wr(p, s)
    print("[+] throne_tracker.c: patched")

print("[+] BakaSU PRIORITY_UID_FILTER support done.")
  
