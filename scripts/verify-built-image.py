#!/usr/bin/env python3
"""Verify an Android boot image and extract its recovery ramdisk for checks."""
from __future__ import annotations

import argparse
import gzip
import lzma
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HEADER_FMT = "<8s10I16s512s32s1024sIQIIQ"
HEADER_KEYS = [
    "magic", "kernel_size", "kernel_addr", "ramdisk_size", "ramdisk_addr",
    "second_size", "second_addr", "tags_addr", "page_size", "header_version",
    "os_version", "name", "cmdline", "id", "extra_cmdline",
    "recovery_dtbo_size", "recovery_dtbo_offset", "header_size", "dtb_size",
    "dtb_addr",
]


def align(value: int, page: int) -> int:
    return ((value + page - 1) // page) * page


def decompress_ramdisk(data: bytes) -> bytes:
    if data.startswith(b"\x1f\x8b"):
        return gzip.decompress(data)
    if data.startswith(b"\xfd7zXZ\x00") or data.startswith(b"\x5d\x00\x00"):
        return lzma.decompress(data)
    try:
        return lzma.decompress(data)
    except lzma.LZMAError:
        pass
    raise RuntimeError(f"Unsupported ramdisk compression, magic={data[:12].hex()}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--partition-size", type=int, default=81_788_928)
    args = parser.parse_args()

    image = args.image.resolve()
    if not image.is_file():
        raise FileNotFoundError(image)
    size = image.stat().st_size
    if size > args.partition_size:
        raise RuntimeError(
            f"Image is too large: {size} bytes, recovery partition is "
            f"{args.partition_size} bytes"
        )

    with image.open("rb") as fh:
        raw_header = fh.read(4096)
        values = struct.unpack(HEADER_FMT, raw_header[: struct.calcsize(HEADER_FMT)])
        header = dict(zip(HEADER_KEYS, values))
        if header["magic"] != b"ANDROID!":
            raise RuntimeError("Not an Android boot image")
        page = int(header["page_size"])
        ramdisk_offset = page + align(int(header["kernel_size"]), page)
        fh.seek(ramdisk_offset)
        compressed = fh.read(int(header["ramdisk_size"]))

    cpio = decompress_ramdisk(compressed)
    with tempfile.TemporaryDirectory(prefix="ofox_verify_") as temp:
        temp_path = Path(temp)
        proc = subprocess.run(
            ["cpio", "-idm", "--no-absolute-filenames"],
            input=cpio,
            cwd=temp_path,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode not in (0, 1):
            sys.stderr.buffer.write(proc.stderr)
            raise RuntimeError("Could not extract ramdisk")

        required = {
            "init.of_sdcard.rc": "OrangeFox a52xq unified microSD pre-mount helper v2",
            "sbin/of_sdcard_mount.sh": "OrangeFox a52xq unified SD mount helper v2",
            "system/etc/twrp.flags": "xhci-hcd.*.auto* /usb_otg auto",
        }
        for rel, needle in required.items():
            target = temp_path / rel
            if not target.is_file():
                raise RuntimeError(f"Missing required ramdisk file: {rel}")
            text = target.read_text(errors="ignore")
            if needle not in text:
                raise RuntimeError(f"Missing expected content in {rel}: {needle}")

        init_qcom = temp_path / "init.recovery.qcom.rc"
        main_init = temp_path / "system/etc/init/hw/init.rc"
        import_found = any(
            p.is_file() and "import /init.of_sdcard.rc" in p.read_text(errors="ignore")
            for p in (init_qcom, main_init)
        )
        if not import_found:
            raise RuntimeError("MicroSD init script is not imported")

        props = []
        for rel in ("prop.default", "default.prop"):
            p = temp_path / rel
            if p.is_file():
                props.append(p.read_text(errors="ignore"))
        joined = "\n".join(props)
        for prop in (
            "persist.sys.isUsbOtgEnabled=true",
            "persist.sys.oem.otg_support=true",
        ):
            if prop not in joined:
                raise RuntimeError(f"Missing OTG property: {prop}")

        recovery_bin = temp_path / "system/bin/recovery"
        version = "unknown"
        if recovery_bin.is_file():
            output = subprocess.run(
                ["strings", str(recovery_bin)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            ).stdout
            for candidate in ("R12.1", "R12.0", "R12"):
                if candidate in output:
                    version = candidate
                    break
        if not version.startswith("R12"):
            raise RuntimeError(f"Built recovery does not identify as R12, found: {version}")

    print(f"PASS: {image.name}")
    print(f"Size: {size} / {args.partition_size} bytes")
    print(f"OrangeFox version detected: {version}")
    print("MicroSD helper: present")
    print("Dynamic USB-OTG rule: present")
    print("OTG properties: present")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"VERIFY FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
