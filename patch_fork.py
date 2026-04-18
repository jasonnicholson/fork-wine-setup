#!/usr/bin/env python3
"""Patch Fork.exe for Wine — all 7 methods in one script.

Patches:
  1. Theme.SubscribeToSystemEvents → ret
  2. Theme.GetSystemBrush → return fallback
  3. SystemThemeHelper.SubscribeToSystemEvents → ret
  4. SystemThemeHelper.GetSystemBrush → return fallback
  5. DiffLineNumberMargin.MeasureOverride → return Size(50, 0)
  6. DiffLineNumberMargin.OnRender → ret
  7. SpellingPlaceholderTextBox.RefreshSpellChecking → ret (disable spell check)
"""
import sys, shutil, struct, os

def rva_to_offset(sections, rva):
    for vaddr, vsize, raw_offset in sections:
        if vaddr <= rva < vaddr + vsize:
            return rva - vaddr + raw_offset
    return None

def get_sections(data):
    pe_offset = struct.unpack_from('<I', data, 0x3C)[0]
    num_sections = struct.unpack_from('<H', data, pe_offset + 6)[0]
    opt_hdr_size = struct.unpack_from('<H', data, pe_offset + 20)[0]
    section_offset = pe_offset + 24 + opt_hdr_size
    sections = []
    for i in range(num_sections):
        off = section_offset + i * 40
        vsize = struct.unpack_from('<I', data, off + 8)[0]
        vaddr = struct.unpack_from('<I', data, off + 12)[0]
        raw_offset = struct.unpack_from('<I', data, off + 20)[0]
        sections.append((vaddr, vsize, raw_offset))
    return sections

def read_method_header(data, offset):
    b = data[offset]
    if (b & 0x3) == 0x2:
        return offset + 1, b >> 2, False, 1
    elif (b & 0x3) == 0x3:
        hdr_size = (struct.unpack_from('<H', data, offset)[0] >> 12) * 4
        code_size = struct.unpack_from('<I', data, offset + 4)[0]
        return offset + hdr_size, code_size, True, hdr_size
    return None, None, None, None

def patch_noop(data, fo):
    co, cs, fat, hs = read_method_header(data, fo)
    if co is None: return False
    if fat:
        # Clear MoreSects flag (bit 3) and keep Fat format (0x3), InitLocals can stay
        old_flags = struct.unpack_from('<H', data, fo)[0]
        new_flags = old_flags & ~0x08  # clear MoreSects
        struct.pack_into('<H', data, fo, new_flags)
        struct.pack_into('<H', data, fo+2, 0)
        struct.pack_into('<I', data, fo+4, 1)
        struct.pack_into('<I', data, fo+8, 0)
        data[co] = 0x2A
        for i in range(1, cs): data[co+i] = 0
    else:
        data[fo] = 0x06; data[fo+1] = 0x2A
        for i in range(2, 1+cs): data[fo+i] = 0
    return True

def patch_return_arg(data, fo, ai):
    co, cs, fat, hs = read_method_header(data, fo)
    if co is None: return False
    il = bytes([0x02+ai, 0x2A]) if ai <= 3 else bytes([0x0E, ai, 0x2A])
    if fat:
        old_flags = struct.unpack_from('<H', data, fo)[0]
        struct.pack_into('<H', data, fo, old_flags & ~0x08)
        struct.pack_into('<H', data, fo+2, 1)
        struct.pack_into('<I', data, fo+4, len(il))
        struct.pack_into('<I', data, fo+8, 0)
        for i, b in enumerate(il): data[co+i] = b
        for i in range(len(il), cs): data[co+i] = 0
    else:
        data[fo] = (len(il) << 2) | 0x02
        for i, b in enumerate(il): data[fo+1+i] = b
        for i in range(len(il), cs): data[fo+1+i] = 0
    return True

def patch_return_size(data, fo, size_token, width=50.0):
    """Replace method body with: return new Size(width, 0.0)"""
    co, cs, fat, hs = read_method_header(data, fo)
    if co is None or not fat: return False

    if size_token is None:
        print("    WARNING: Could not find Size constructor token, using ret instead")
        return patch_noop(data, fo)

    new_il = bytearray()
    new_il += b'\x23' + struct.pack('<d', width)    # ldc.r8 width
    new_il += b'\x23' + struct.pack('<d', 0.0)      # ldc.r8 0.0
    new_il += b'\x73' + struct.pack('<I', size_token)  # newobj Size(double,double)
    new_il += b'\x2a'                                  # ret

    struct.pack_into('<H', data, fo, 0x3003)  # Fat | InitLocals, no MoreSects
    struct.pack_into('<H', data, fo+2, 2)     # maxStack
    struct.pack_into('<I', data, fo+4, len(new_il))
    struct.pack_into('<I', data, fo+8, 0)     # no locals

    for i, b in enumerate(new_il): data[co+i] = b
    for i in range(len(new_il), cs): data[co+i] = 0
    return True

def main():
    import dnfile

    fork_path = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.expanduser("~/.wine-fork/drive_c/users/{}/AppData/Local/Fork/current/Fork.exe".format(
            os.environ.get("USER", "jason")))

    if not os.path.exists(fork_path):
        print(f"ERROR: {fork_path} not found")
        sys.exit(1)

    backup = fork_path + ".original"
    if not os.path.exists(backup):
        shutil.copy2(fork_path, backup)
        print(f"Backed up to: {backup}")
    else:
        print(f"Backup exists: {backup}")

    dn = dnfile.dnPE(fork_path)

    # --- WinRT theme methods (by MethodDef name scan) ---
    theme_targets = {}
    for row in dn.net.mdtables.MethodDef:
        name = str(row.Name)
        if name in ("SubscribeToSystemEvents", "GetSystemBrush") and row.Rva > 0:
            theme_targets.setdefault(name, []).append(row.Rva)

    # --- DiffLineNumberMargin methods (by TypeDef→MethodList) ---
    diff_targets = {}
    spelling_target = None
    for trow in dn.net.mdtables.TypeDef:
        tname = str(trow.TypeName)
        if tname == 'DiffLineNumberMargin':
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                mname = str(mrow.Name)
                if mname in ('MeasureOverride', 'OnRender') and mrow.Rva > 0:
                    diff_targets[mname] = mrow.Rva
        elif tname == 'SpellingPlaceholderTextBox':
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                mname = str(mrow.Name)
                if mname == 'RefreshSpellChecking' and mrow.Rva > 0:
                    spelling_target = mrow.Rva

    # --- Find Size(double,double) constructor token in MemberRef table ---
    size_ctor_token = None
    for i, row in enumerate(dn.net.mdtables.MemberRef):
        if str(row.Name) == '.ctor':
            cls = row.Class
            if cls and hasattr(cls, 'row') and hasattr(cls.row, 'TypeName'):
                if str(cls.row.TypeName) == 'Size' and str(getattr(cls.row, 'TypeNamespace', '')) == 'System.Windows':
                    size_ctor_token = (0x0A << 24) | (i + 1)
                    break
    if size_ctor_token:
        print(f"  Found Size ctor token: 0x{size_ctor_token:08x}")
    else:
        print("  WARNING: Size ctor token not found!")

    data = bytearray(open(fork_path, 'rb').read())
    sections = get_sections(data)
    count = 0

    print("\n--- WinRT theme patches ---")
    for name, rvas in theme_targets.items():
        for rva in rvas:
            fo = rva_to_offset(sections, rva)
            if fo is None: continue
            if name == "SubscribeToSystemEvents":
                ok = patch_noop(data, fo)
            else:
                ok = patch_return_arg(data, fo, 1)
            print(f"  {'OK' if ok else 'FAIL'}: {name} @ RVA 0x{rva:08x}")
            if ok: count += 1

    print("\n--- DiffLineNumberMargin patches ---")
    for mname, rva in diff_targets.items():
        fo = rva_to_offset(sections, rva)
        if fo is None: continue
        if mname == 'MeasureOverride':
            ok = patch_return_size(data, fo, size_ctor_token, width=50.0)
        else:
            ok = patch_noop(data, fo)
        print(f"  {'OK' if ok else 'FAIL'}: DiffLineNumberMargin.{mname} @ RVA 0x{rva:08x}")
        if ok: count += 1

    print("\n--- SpellCheck patch ---")
    if spelling_target:
        fo = rva_to_offset(sections, spelling_target)
        if fo is not None:
            ok = patch_noop(data, fo)
            print(f"  {'OK' if ok else 'FAIL'}: SpellingPlaceholderTextBox.RefreshSpellChecking @ RVA 0x{spelling_target:08x}")
            if ok: count += 1
    else:
        print("  SKIP: SpellingPlaceholderTextBox.RefreshSpellChecking not found")

    open(fork_path, 'wb').write(data)
    print(f"\nPatched {count} methods total. Original saved as {backup}")

if __name__ == '__main__':
    main()
