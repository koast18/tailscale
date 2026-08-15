#!/usr/bin/env python3
"""Zero out the initializer sections of a Mach-O 64-bit little-endian dylib.

Background
----------
Go's -buildmode=c-archive on darwin/ios emits the runtime entry
(_rt0_arm64_ios_lib / _rt0_arm64_darwin_lib) as a load-time initializer. With
modern Xcode linkers that initializer lands in __TEXT,__init_offsets (dyld4
offset-relative initializers); older linkers use __DATA,__mod_init_func. dyld
runs these functions at dlopen.

The Go ctor spawns the Go runtime init thread via pthread_create. On iOS,
dlopen runs constructors while holding dyld's internal lock, so pthread_create
from inside the constructor deadlocks. Removing the initializer sections makes
dlopen skip the ctor entirely; the host then calls TsEnsureInit() (see
cmd/tscore/main.go) to start the Go runtime at a safe time.

This tool zeroes the size (and flags) of every initializer section. It does
not rewrite load commands or move data, so it is safe to run on a signed or
unsigned dylib; re-run codesign afterwards.

Usage: stripinits.py <dylib>
"""
import struct
import sys


def main(path: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic = struct.unpack("<I", data[:4])[0]
    if magic != 0xFEEDFACF:  # MH_MAGIC_64, little-endian
        print(f"{path}: not a 64-bit little-endian Mach-O (magic={magic:#x})")
        return 1

    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32
    found = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off : off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack("<I", data[off + 64 : off + 68])[0]
            so = off + 72
            for _j in range(nsects):
                sname = data[so : so + 16].split(b"\x00")[0].decode()
                size = struct.unpack("<Q", data[so + 40 : so + 48])[0]
                if sname in ("__mod_init_func", "__init_offsets") and size:
                    struct.pack_into("<Q", data, so + 40, 0)  # section size = 0
                    struct.pack_into("<I", data, so + 60, 0)  # flags = 0
                    found.append(sname)
                so += 80
        off += cmdsize

    if not found:
        print(f"{path}: no initializer sections found (already stripped?)")
        return 1

    with open(path, "wb") as f:
        f.write(data)
    print(f"{path}: stripped initializers: {', '.join(sorted(set(found)))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
