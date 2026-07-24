#!/usr/bin/env python3
import os
import sys
import time
import shutil
import tempfile
import subprocess

def write_ar_header(name: str, size: int, mtime: int = None) -> bytes:
    if mtime is None:
        mtime = int(time.time())
    header = f"{name:<16}{mtime:<12}{0:<6}{0:<6}{100644:<8}{size:<10}`\n"
    return header.encode("ascii")

def extract_ar(deb_path: str, extract_dir: str):
    with open(deb_path, "rb") as f:
        magic = f.read(8)
        if magic != b"!<arch>\n":
            raise ValueError(f"{deb_path} is not a valid ar archive (magic: {magic!r})")
        
        members = {}
        while True:
            header = f.read(60)
            if not header or len(header) < 60:
                break
            name = header[0:16].decode("ascii", errors="ignore").strip().rstrip("/")
            size = int(header[48:58].decode("ascii", errors="ignore").strip())
            data = f.read(size)
            if size % 2 != 0:
                f.read(1)  # Padding byte
            
            member_path = os.path.join(extract_dir, name)
            with open(member_path, "wb") as mf:
                mf.write(data)
            members[name] = member_path
        return members

def patch_macho_dylib(dylib_path: str):
    with open(dylib_path, "rb") as f:
        data = bytearray(f.read())
    
    patches_applied = 0
    
    # 1. Resolve symbols using nm if available
    try:
        nm_out = subprocess.check_output(["nm", "-m", dylib_path]).decode("utf-8", errors="ignore")
        syms = {}
        for line in nm_out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0].isalnum():
                sym_name = parts[-1]
                if sym_name in ["_dvnLocked", "_dvnCheck", "_ytpBool", "_ytpInt"]:
                    syms[sym_name] = int(parts[0], 16)
        
        # mov w0, #0; ret (arm64: 00 00 80 52 c0 03 5f d6)
        MOV_W0_0_RET = bytes.fromhex("00008052c0035fd6")
        # mov w0, #1; ret (arm64: 20 00 80 52 c0 03 5f d6)
        MOV_W0_1_RET = bytes.fromhex("20008052c0035fd6")
        
        if "_dvnLocked" in syms:
            addr = syms["_dvnLocked"]
            data[addr:addr+8] = MOV_W0_0_RET
            patches_applied += 1
            print(f"[+] Patched symbol _dvnLocked at 0x{addr:x} -> return NO")
            
        if "_dvnCheck" in syms:
            addr = syms["_dvnCheck"]
            data[addr:addr+8] = MOV_W0_1_RET
            patches_applied += 1
            print(f"[+] Patched symbol _dvnCheck at 0x{addr:x} -> return YES")
    except Exception as e:
        print(f"[*] Warning: Symbol-based patch skipped ({e})")

    # 2. Pattern patch: replace all `ldrb w8, [x8, #0xd11]` (08 45 74 39) with `mov w8, #0` (08 00 80 52)
    # This guarantees that every check for locked flag (in _ytpBool, _ytpInt, token checks) evaluates to 0
    LDRB_W8_0xD11 = bytes.fromhex("08457439")
    MOV_W8_0 = bytes.fromhex("08008052")
    idx = 0
    count_ldrb = 0
    while True:
        idx = data.find(LDRB_W8_0xD11, idx)
        if idx == -1:
            break
        data[idx:idx+4] = MOV_W8_0
        count_ldrb += 1
        patches_applied += 1
        idx += 4
    print(f"[+] Patched {count_ldrb} instances of ldrb w8, [x8, #0xd11] -> mov w8, #0")

    # 3. Pattern patch: replace `strb w9, [x8, #0xd11]` (09 45 34 39) with `strb wzr, [x8, #0xd11]` (1f 45 34 39)
    # This prevents anything from setting the locked flag to 1
    STRB_W9_0xD11 = bytes.fromhex("09453439")
    STRB_WZR_0xD11 = bytes.fromhex("1f453439")
    idx = 0
    count_strb = 0
    while True:
        idx = data.find(STRB_W9_0xD11, idx)
        if idx == -1:
            break
        data[idx:idx+4] = STRB_WZR_0xD11
        count_strb += 1
        patches_applied += 1
        idx += 4
    print(f"[+] Patched {count_strb} instances of strb w9, [x8, #0xd11] -> strb wzr, [x8, #0xd11]")

    if patches_applied == 0:
        raise RuntimeError("No patch patterns matched in dylib! Please check binary format.")

    with open(dylib_path, "wb") as f:
        f.write(data)
    print(f"[+] Successfully wrote patched dylib ({patches_applied} total patches applied)")

    # 4. Re-sign dylib
    signed = False
    try:
        subprocess.check_call(["codesign", "-f", "-s", "-", dylib_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        signed = True
        print("[+] Re-signed dylib with codesign")
    except Exception:
        pass

    if not signed:
        try:
            subprocess.check_call(["ldid", "-S", dylib_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            signed = True
            print("[+] Re-signed dylib with ldid")
        except Exception as e:
            print(f"[*] Warning: Could not re-sign dylib with codesign or ldid ({e})")

def patch_deb(deb_path: str, output_deb_path: str = None):
    if output_deb_path is None:
        output_deb_path = deb_path

    temp_dir = tempfile.mkdtemp(prefix="patch_ytplus_")
    try:
        print(f"[*] Unpacking {deb_path}...")
        members = extract_ar(deb_path, temp_dir)
        
        if "debian-binary" not in members:
            raise ValueError("Invalid DEB package: missing debian-binary")
        
        # Find control.tar.*
        control_member = next((k for k in members if k.startswith("control.tar")), None)
        if not control_member:
            raise ValueError("Invalid DEB package: missing control.tar")
            
        # Find data.tar.*
        data_member = next((k for k in members if k.startswith("data.tar")), None)
        if not data_member:
            raise ValueError("Invalid DEB package: missing data.tar")

        # Extract data.tar.*
        data_tar_path = members[data_member]
        data_dir = os.path.join(temp_dir, "data_root")
        os.makedirs(data_dir, exist_ok=True)
        
        tar_extract_cmd = ["tar", "-xf", data_tar_path, "-C", data_dir]
        if data_member.endswith(".lzma"):
            tar_extract_cmd.insert(1, "--lzma")
        subprocess.check_call(tar_extract_cmd)

        # Locate YTLite.dylib
        found_dylibs = []
        for root, _, files in os.walk(data_dir):
            for file in files:
                if file.lower() == "ytlite.dylib":
                    found_dylibs.append(os.path.join(root, file))

        if not found_dylibs:
            raise FileNotFoundError("YTLite.dylib not found inside DEB package data!")

        for dylib_path in found_dylibs:
            print(f"[*] Patching {dylib_path}...")
            patch_macho_dylib(dylib_path)

        # Repackage data directory to data.tar.gz
        new_data_tar = os.path.join(temp_dir, "data.tar.gz")
        tar_args = ["tar", "-czf", new_data_tar, "-C", data_dir] + os.listdir(data_dir)
        subprocess.check_call(tar_args)

        # Read archive parts
        with open(members["debian-binary"], "rb") as f:
            debian_binary_bytes = f.read()
        with open(members[control_member], "rb") as f:
            control_bytes = f.read()
        with open(new_data_tar, "rb") as f:
            data_bytes = f.read()

        # Reconstruct standard Debian 2.0 AR archive
        temp_out = os.path.join(temp_dir, "output.deb")
        with open(temp_out, "wb") as f:
            f.write(b"!<arch>\n")
            f.write(write_ar_header("debian-binary", len(debian_binary_bytes)))
            f.write(debian_binary_bytes)
            if len(debian_binary_bytes) % 2 != 0:
                f.write(b"\n")
                
            f.write(write_ar_header(control_member, len(control_bytes)))
            f.write(control_bytes)
            if len(control_bytes) % 2 != 0:
                f.write(b"\n")
                
            f.write(write_ar_header("data.tar.gz", len(data_bytes)))
            f.write(data_bytes)
            if len(data_bytes) % 2 != 0:
                f.write(b"\n")

        shutil.move(temp_out, output_deb_path)
        print(f"[+] Successfully generated patched DEB: {output_deb_path} ({os.path.getsize(output_deb_path)} bytes)")

    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path_to_deb> [output_deb_path]")
        sys.exit(1)
    
    in_deb = sys.argv[1]
    out_deb = sys.argv[2] if len(sys.argv) > 2 else in_deb
    patch_deb(in_deb, out_deb)
