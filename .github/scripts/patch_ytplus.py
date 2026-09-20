#!/usr/bin/env python3
import os
import sys
import time
import shutil
import struct
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
    syms = {}
    try:
        nm_out = subprocess.check_output(["nm", "-m", dylib_path]).decode("utf-8", errors="ignore")
        for line in nm_out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0].isalnum():
                sym_name = parts[-1]
                if sym_name in ["_dvnLocked", "_dvnCheck", "_ytpBool", "_ytpInt"]:
                    syms[sym_name] = int(parts[0], 16)
        
        MOV_W0_0_RET = bytes.fromhex("00008052c0035fd6") # mov w0, #0; ret
        MOV_W0_1_RET = bytes.fromhex("20008052c0035fd6") # mov w0, #1; ret
        MOV_W0_1 = bytes.fromhex("20008052")             # mov w0, #1
        MOV_W0_0 = bytes.fromhex("00008052")             # mov w0, #0
        
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

        # 2. Dynamic branch target decoding inside _ytpBool and _ytpInt
        for func_name in ["_ytpBool", "_ytpInt"]:
            if func_name not in syms:
                continue
            addr = syms[func_name]
            for i in range(16):
                pc = addr + i * 4
                insn = struct.unpack("<I", data[pc:pc+4])[0]
                if (insn & 0xfc000000) == 0x94000000:
                    imm26 = insn & 0x03ffffff
                    if imm26 & (1 << 25):
                        imm26 -= (1 << 26)
                    target = pc + imm26 * 4
                    # Skip stubs (> 0xb00000) to find real license check call
                    if target >= 0xb00000:
                        continue
                    
                    # Trace thunks if target chains into another function
                    t_insn2 = struct.unpack("<I", data[target+4:target+8])[0]
                    real_target = target
                    if (t_insn2 & 0xfc000000) == 0x94000000:
                        imm26_t = t_insn2 & 0x03ffffff
                        if imm26_t & (1 << 25):
                            imm26_t -= (1 << 26)
                        thunk_call = (target + 4) + imm26_t * 4
                        real_target = thunk_call
                        rt_insn2 = struct.unpack("<I", data[real_target+4:real_target+8])[0]
                        if (rt_insn2 & 0xfc000000) == 0x94000000:
                            imm26_rt = rt_insn2 & 0x03ffffff
                            if imm26_rt & (1 << 25):
                                imm26_rt -= (1 << 26)
                            final_check = (real_target + 4) + imm26_rt * 4
                            data[final_check:final_check+8] = MOV_W0_1_RET
                            patches_applied += 1
                            print(f"[+] Patched core license check function at 0x{final_check:x} -> return YES")
                    
                    data[target:target+8] = MOV_W0_1_RET
                    patches_applied += 1
                    print(f"[+] Patched license check target at 0x{target:x} -> return YES")
                    if real_target != target:
                        data[real_target:real_target+8] = MOV_W0_1_RET
                        patches_applied += 1
                        print(f"[+] Patched license check helper at 0x{real_target:x} -> return YES")

                    # Replace the BL instruction inside _ytpBool / _ytpInt with unconditional branch b +0x84
                    # This jumps directly to the [YTLUserDefaults boolForKey:] / [YTLUserDefaults integerForKey:]
                    # block, completely bypassing all Goron/OLLVM obfuscated jump tables and DRM checks,
                    # while preserving AAPCS64 register state and matching objc_retain/objc_release balance!
                    B_PLUS_0x84 = bytes.fromhex("21000014") # b +0x84
                    data[pc:pc+4] = B_PLUS_0x84
                    patches_applied += 1
                    print(f"[+] Patched BL at 0x{pc:x} (+0x{i*4:x}) in {func_name} -> b +0x84 (direct jump to UserDefaults)")
                    break
    except Exception as e:
        print(f"[*] Warning: Symbol/branch analysis error ({e})")

    # 3. Pattern patch: architecture-dependent lock flags
    flag_patches = [
        ("08457439", "08008052", "ldrb w8, [x8, #0xd11] -> mov w8, #0 (arm64)"),
        ("09453439", "1f453439", "strb w9, [x8, #0xd11] -> strb wzr, [x8, #0xd11] (arm64)"),
        ("08857239", "08008052", "ldrb w8, [x8, #0xca1] -> mov w8, #0 (arm64e)"),
        ("09853239", "1f853239", "strb w9, [x8, #0xca1] -> strb wzr, [x8, #0xca1] (arm64e)")
    ]
    for src_hex, dst_hex, desc in flag_patches:
        src = bytes.fromhex(src_hex)
        dst = bytes.fromhex(dst_hex)
        idx = 0
        cnt = 0
        while True:
            idx = data.find(src, idx)
            if idx == -1:
                break
            data[idx:idx+len(dst)] = dst
            cnt += 1
            patches_applied += 1
            idx += len(dst)
        if cnt > 0:
            print(f"[+] Patched {cnt} instances of {desc}")

    # 4. Pattern patch: Fix empty Home Feed bug by neutralizing hasAdLoggingData check
    pat_sel = bytes.fromhex("018d42f9") # ldr x1, [x8, #0x518]
    idx = 0
    ad_count = 0
    while True:
        idx = data.find(pat_sel, idx)
        if idx == -1:
            break
        next_insn = struct.unpack("<I", data[idx+4:idx+8])[0]
        if (next_insn & 0xfc000000) == 0x94000000:
            third_insn = struct.unpack("<I", data[idx+8:idx+12])[0]
            # Match mov x23, x0 (0xaa0003f7) or mov x26, x0 (0xaa0003fa)
            if third_insn in [0xaa0003f7, 0xaa0003fa]:
                data[idx+4:idx+8] = bytes.fromhex("00008052") # mov w0, #0
                ad_count += 1
                patches_applied += 1
                print(f"[+] Patched hasAdLoggingData BL at 0x{idx+4:x} -> mov w0, #0")
        idx += 4
    if ad_count > 0:
        print(f"[+] Neutralized {ad_count} hasAdLoggingData checks (Home Feed bug cured)")

    if patches_applied == 0:
        raise RuntimeError("No patch patterns matched in dylib! Please check binary format.")

    with open(dylib_path, "wb") as f:
        f.write(data)
    print(f"[+] Successfully wrote patched dylib ({patches_applied} total patches applied)")

    # 5. Re-sign dylib
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
        env = os.environ.copy()
        env["COPYFILE_DISABLE"] = "1"
        tar_args = ["tar", "-czf", new_data_tar, "-C", data_dir] + os.listdir(data_dir)
        subprocess.check_call(tar_args, env=env)

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
