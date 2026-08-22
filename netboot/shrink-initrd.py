import sys
src, dst = sys.argv[1], sys.argv[2]
DROP = tuple("usr/lib/firmware/"+v for v in ("nvidia","amdgpu","i915","xe","radeon"))
d = open(src,'rb').read()
out = bytearray(); off = 0; kept = dropped = 0; dropped_bytes = 0
while True:
    if d[off:off+6] != b'070701':
        raise SystemExit(f"no cpio header at {off}: {d[off:off+8]!r}")
    f = lambda i: int(d[off+6+i*8:off+6+(i+1)*8], 16)
    mode, uid, gid, nlink, mtime, fsize = f(1), f(2), f(3), f(4), f(5), f(6)
    namesize = f(11)
    name_end = off+110+namesize
    name = d[off+110:name_end-1].decode()
    hdr_end = name_end + (-(name_end) % 4)
    data_end = hdr_end + fsize
    entry_end = data_end + (-(data_end) % 4)
    if name == 'TRAILER!!!':
        break
    if name.startswith(DROP):
        dropped += 1; dropped_bytes += fsize
    else:
        out += d[off:entry_end]; kept += 1
    off = entry_end
# TRAILER
tn = b'TRAILER!!!\0'
th = b'070701' + b'0'*8*4 + b'%08X'%1 + b'0'*8 + b'%08X'%0 + b'0'*8*4 + b'%08X'%len(tn) + b'0'*8
assert len(th) == 110, len(th)
out += th + tn
out += b'\0' * (-len(out) % 512)
open(dst,'wb').write(out)
print(f"kept={kept} dropped={dropped} dropped_bytes={dropped_bytes/1048576:.1f}MB new_plain={len(out)/1048576:.1f}MB")
