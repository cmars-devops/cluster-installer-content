"""Remaster an Ubuntu live-server ISO to inject Subiquity autoinstall args.

Invoked by the orchestrator's esxi_upload stage (and, in future, the
libvirt path) via uv. The Go side passes the source ISO, destination
ISO, and the per-node NoCloud datasource URL.

Why pycdlib (not go-diskfs): go-diskfs's iso9660 implementation silently
drops file content when copying large hybrid ISOs. pycdlib is a pure-Python
library purpose-built for ISO9660 modification with preserved El Torito
boot records, used by Anaconda installer and the Linux distro tooling
ecosystem at large.

Usage:
    uv run --with pycdlib python remaster.py \\
        --src  /path/to/ubuntu-26.04-live-server-amd64.iso \\
        --dst  /path/to/install-<host>.iso \\
        --url  http://<host>:<port>/profiles/<host>/

The URL is appended verbatim to every "linux /casper/vmlinuz ..." line
in /boot/grub/grub.cfg, splicing the autoinstall directive in BEFORE the
trailing "---" cloud-init separator so the kernel sees it (rather than
cloud-init's userdata stage).
"""
from __future__ import annotations

import argparse
import io
import re
import sys

import pycdlib


GRUB_CFG_PATH = "/boot/grub/grub.cfg"
ISOLINUX_CFG_PATH = "/isolinux/txt.cfg"  # legacy, may be absent on 24.04+


def autoinstall_inject(grub_text: str, ds_url: str) -> str:
    """Add `autoinstall ds=nocloud[-net\\;s=URL]` to every kernel line.

    When ds_url is empty, emit the cidata-only form
    (`ds=nocloud`) — the wizard's per-node cidata ISO carries
    user-data/meta-data on a CD labelled "cidata" and cloud-init
    auto-discovers it without needing an HTTP fetch. That lets the
    big install ISO be remastered ONCE and shared across every node,
    instead of one ~3 GB copy per host with only the URL differing.

    When ds_url is non-empty (legacy/debug), the `nocloud-net;s=URL`
    form is used. The semicolon between `nocloud-net` and `s=` is
    escaped with `\\` because GRUB treats unescaped `;` as a statement
    separator — without the backslash the `linux` line is silently
    truncated and Subiquity falls back to interactive mode.

    Also reduces `set timeout=...` to 1s so the default entry auto-fires.
    """
    if ds_url:
        auto_args = f" autoinstall ds=nocloud-net\\;s={ds_url}"
    else:
        auto_args = " autoinstall ds=nocloud"
    out_lines: list[str] = []
    for line in grub_text.splitlines():
        stripped = line.lstrip()
        # GRUB timeout
        if stripped.startswith("set timeout="):
            indent = line[: len(line) - len(stripped)]
            out_lines.append(f"{indent}set timeout=1")
            continue
        # kernel/linux entries
        lower = stripped.lower()
        if (
            lower.startswith("linux ")
            or lower.startswith("linuxefi ")
            or lower.startswith("append ")
        ):
            rstripped = line.rstrip()
            if " ---" in rstripped:
                idx = rstripped.rfind(" ---")
                out_lines.append(rstripped[:idx] + auto_args + " ---")
            else:
                out_lines.append(rstripped + auto_args)
            continue
        out_lines.append(line)
    return "\n".join(out_lines) + ("\n" if grub_text.endswith("\n") else "")


def _resolve_iso_path(iso: pycdlib.PyCdlib, rr_path: str) -> str | None:
    """Find the canonical ISO9660 path (with ;1 suffix) for a Rock Ridge path.

    Ubuntu live-server stores files at long Linux-style paths via Rock
    Ridge, but pycdlib's mutating APIs (rm_file, add_fp) only accept the
    canonical iso_path. We walk the directory tree, matching each entry's
    Rock Ridge name, to discover the iso_path.
    """
    parts = [p for p in rr_path.split("/") if p]
    cur_iso_path = "/"
    for i, part in enumerate(parts):
        is_last = i == len(parts) - 1
        found_iso_name: str | None = None
        for child in iso.list_children(iso_path=cur_iso_path):
            if child is None or not child.rock_ridge:
                continue
            rr_name = child.rock_ridge.name()
            if isinstance(rr_name, bytes):
                rr_name = rr_name.decode("utf-8", errors="replace")
            if rr_name == part:
                fi = child.file_identifier()
                if isinstance(fi, bytes):
                    fi = fi.decode("ascii", errors="replace")
                # Strip ";1" version suffix for directories; keep for files.
                if not is_last and fi.endswith(";1"):
                    found_iso_name = fi[:-2]
                else:
                    found_iso_name = fi
                break
        if found_iso_name is None:
            return None
        cur_iso_path = (cur_iso_path.rstrip("/") + "/" + found_iso_name) if cur_iso_path != "/" else "/" + found_iso_name
    return cur_iso_path


def get_iso_text(iso: pycdlib.PyCdlib, rr_path: str) -> str | None:
    buf = io.BytesIO()
    try:
        iso.get_file_from_iso_fp(buf, rr_path=rr_path)
    except Exception:
        return None
    return buf.getvalue().decode("utf-8", errors="replace")


def replace_iso_file(iso: pycdlib.PyCdlib, rr_path: str, data: bytes) -> None:
    """Replace a file's contents inside the ISO. Length may change."""
    iso_path = _resolve_iso_path(iso, rr_path)
    if iso_path is None:
        raise RuntimeError(f"could not resolve iso_path for {rr_path}")
    rm_kw: dict = {"iso_path": iso_path}
    add_kw: dict = {"iso_path": iso_path}
    if iso.has_rock_ridge():
        rm_kw["rr_name"] = rr_path.rsplit("/", 1)[-1]
        add_kw["rr_name"] = rr_path.rsplit("/", 1)[-1]
    if iso.has_joliet():
        rm_kw["joliet_path"] = rr_path
        add_kw["joliet_path"] = rr_path
    iso.rm_file(**rm_kw)
    iso.add_fp(io.BytesIO(data), len(data), **add_kw)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--dst", required=True)
    ap.add_argument("--url", default="", help="NoCloud datasource URL (with trailing /). Leave empty when using a labeled cidata CD-ROM seed (the recommended path for shared install ISOs).")
    args = ap.parse_args()

    if args.url and not args.url.endswith("/"):
        print(f"WARN: --url should end with / (got {args.url!r})", file=sys.stderr)

    print(f"opening {args.src}")
    iso = pycdlib.PyCdlib()
    iso.open(args.src)

    # Patch /boot/grub/grub.cfg — the universal target on Ubuntu 24.04+.
    grub_text = get_iso_text(iso, GRUB_CFG_PATH)
    if grub_text is None:
        print(f"FATAL: {GRUB_CFG_PATH} not found in ISO", file=sys.stderr)
        return 2
    grub_new = autoinstall_inject(grub_text, args.url)
    if grub_new == grub_text:
        print(f"WARN: autoinstall args were already present (idempotent)", file=sys.stderr)
    replace_iso_file(iso, GRUB_CFG_PATH, grub_new.encode("utf-8"))
    print(f"patched {GRUB_CFG_PATH}")

    # Best-effort: patch isolinux txt.cfg if present (legacy BIOS path,
    # absent on 24.04+ but harmless to skip).
    isolinux_text = get_iso_text(iso, ISOLINUX_CFG_PATH)
    if isolinux_text:
        isolinux_new = autoinstall_inject(isolinux_text, args.url)
        replace_iso_file(iso, ISOLINUX_CFG_PATH, isolinux_new.encode("utf-8"))
        print(f"patched {ISOLINUX_CFG_PATH}")

    print(f"writing {args.dst}")
    iso.write(args.dst)
    iso.close()
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
