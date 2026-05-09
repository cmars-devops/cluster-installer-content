"""Build a tiny ISO9660 image labeled "cidata" containing user-data and
meta-data files for cloud-init's NoCloud datasource.

We use pycdlib instead of Go's diskfs because diskfs's iso9660 backend
silently miscounts written bytes on small writes (the orchestrator saw
`copied N bytes, expected 0` errors). pycdlib is the same library used
for the Ubuntu install-ISO remaster, so the build chain stays consistent.

Usage:
    uv run --with pycdlib python build-cidata.py \\
        --user-data /path/to/user-data \\
        --meta-data /path/to/meta-data \\
        --out /path/to/seed-<hostname>.iso
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pycdlib


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user-data", required=True)
    ap.add_argument("--meta-data", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    ud = Path(args.user_data).read_bytes()
    md = Path(args.meta_data).read_bytes()

    iso = pycdlib.PyCdlib()
    # Volume identifier == NoCloud's expected "cidata" label so cloud-init
    # auto-discovers the disk by walking attached block devices.
    iso.new(
        interchange_level=3,    # supports filenames > 8.3 (lowercase via Joliet)
        joliet=3,
        rock_ridge="1.09",
        vol_ident="cidata",
    )
    iso.add_fp(_bytes_io(ud), len(ud),
               iso_path="/USERDATA.;1",
               rr_name="user-data",
               joliet_path="/user-data")
    iso.add_fp(_bytes_io(md), len(md),
               iso_path="/METADATA.;1",
               rr_name="meta-data",
               joliet_path="/meta-data")
    iso.write(args.out)
    iso.close()
    print(f"wrote {args.out}  ({len(ud)+len(md)} bytes payload)")
    return 0


def _bytes_io(b: bytes):
    import io
    return io.BytesIO(b)


if __name__ == "__main__":
    sys.exit(main())
