#!/usr/bin/env python3
"""Raise the macOS SDK a thin Mach-O declares, so Apple will notarize it.

Upstream cross-compiles Bifrost's Intel slice on Ubuntu against MacOSX12.3.sdk, but the emitted
`LC_VERSION_MIN_MACOSX` load command records SDK 10.4. Apple rejects every notarization whose
nested x86_64 executable declares an SDK older than 10.9, so the field has to be corrected before
Xcode signs the helper.

This used to be `xcrun vtool -set-version-min macos 10.4 12.3 -replace`. vtool re-emits the whole
Mach-O, so its output could only be pinned by a digest produced on a Mac — which meant the pin
could not be computed or checked anywhere else, including in review. Editing the one field in
place is the same correction expressed as a transformation anybody can reproduce: four bytes
change, the digest is deterministic on every platform, and `verify-bifrost.sh` still independently
confirms the result with `vtool -show-build` on macOS.

Only the SDK version is touched. The minimum OS version (the deployment target) is deliberately
left alone: Apple gates notarization on the SDK, and raising the deployment target would claim
support the binary was never built for.
"""

from __future__ import annotations

import argparse
import shutil
import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_MAGIC_32 = 0xFEEDFACE
MH_CIGAM_32 = 0xCEFAEDFE
FAT_MAGICS = {0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA}

LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1


def encode_version(text: str) -> int:
    """`12.3` / `12.3.0` -> the packed X.Y.Z nibble form Mach-O stores."""
    parts = [int(p) for p in text.split(".")]
    while len(parts) < 3:
        parts.append(0)
    if len(parts) != 3:
        raise ValueError(f"not a version: {text}")
    major, minor, patch = parts
    if not (0 <= major <= 0xFFFF and 0 <= minor <= 0xFF and 0 <= patch <= 0xFF):
        raise ValueError(f"version out of range: {text}")
    return (major << 16) | (minor << 8) | patch


def decode_version(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 0xFF}.{value & 0xFF}"


def patch_slice(data: bytearray, offset: int, sdk: int) -> list[str]:
    """Rewrite the SDK field of every macOS version load command in one thin Mach-O."""
    magic = struct.unpack_from("<I", data, offset)[0]
    if magic in (MH_MAGIC_64, MH_MAGIC_32):
        endian = "<"
    elif magic in (MH_CIGAM_64, MH_CIGAM_32):
        endian = ">"
    else:
        raise ValueError(f"not a thin Mach-O at offset {offset}: magic {magic:#x}")
    is_64 = struct.unpack_from(endian + "I", data, offset)[0] in (MH_MAGIC_64, MH_CIGAM_64)
    header_size = 32 if is_64 else 28
    ncmds = struct.unpack_from(endian + "I", data, offset + 16)[0]

    changes: list[str] = []
    cursor = offset + header_size
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(endian + "II", data, cursor)
        if size < 8:
            raise ValueError("corrupt load command")
        if cmd == LC_VERSION_MIN_MACOSX:
            field = cursor + 12  # cmd, cmdsize, version, then sdk
            current = struct.unpack_from(endian + "I", data, field)[0]
            if current != sdk:
                struct.pack_into(endian + "I", data, field, sdk)
                changes.append(
                    f"LC_VERSION_MIN_MACOSX sdk {decode_version(current)} -> {decode_version(sdk)}"
                )
        elif cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from(endian + "I", data, cursor + 8)[0]
            if platform == PLATFORM_MACOS:
                field = cursor + 16  # cmd, cmdsize, platform, minos, then sdk
                current = struct.unpack_from(endian + "I", data, field)[0]
                if current != sdk:
                    struct.pack_into(endian + "I", data, field, sdk)
                    changes.append(
                        f"LC_BUILD_VERSION sdk {decode_version(current)} -> {decode_version(sdk)}"
                    )
        cursor += size
    return changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument(
        "--sdk", default="12.3", help="macOS SDK version to declare (default: 12.3)"
    )
    args = parser.parse_args()

    sdk = encode_version(args.sdk)
    data = bytearray(Path(args.source).read_bytes())
    if len(data) < 32:
        print("input is too small to be a Mach-O", file=sys.stderr)
        return 1

    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in FAT_MAGICS:
        print(
            "refusing to edit a universal binary: normalize each slice before lipo joins them",
            file=sys.stderr,
        )
        return 1

    try:
        changes = patch_slice(data, 0, sdk)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1

    destination = Path(args.destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(bytes(data))
    shutil.copymode(args.source, destination)
    for change in changes:
        print(change)
    if not changes:
        print(f"already declares macOS SDK {args.sdk}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
