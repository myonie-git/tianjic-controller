#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Export Controller deployment files and compare @address data.

Commands:
  export CASE_DIR -o OUTDIR [--ch N] [--irq-last]
  compare GOLDEN DUMP [--mode packets|memory]
  selftest CASE_DIR [-o OUTDIR]

Outputs:
  send_image.bin: 16-byte little-endian SEND records.
  boot_prim_*.bin: 32-byte little-endian core memory rows.
  manifest.json: image files, core coordinates and row-address segments.
  init_regs.txt: W/P/F initialization recipe for the caller to execute.

Records: tag[127:112], flags[111:104], ch[103:96], pkt[95:0].
TX flags: LAST bit0, FENCE bit1 (wait for prior TX handshakes), IRQ bit2.
Packet packing follows soc/verif/multi_die/seq/md_lvds_HEX_sequence.sv;
record fields follow controller/rtl/pkg/tj_ctrl_pkg.sv.

Packet comparison preserves record counts and ignores order. Memory comparison
checks final values at the golden addresses. Requires Python 3.6+, standard library only.
"""
import argparse
import io
import json
import os
import re
import sys
from collections import Counter

FLAG_LAST, FLAG_FENCE, FLAG_IRQ = 1, 2, 4

# Default SPI initialization sequence; southside protocol, section 7.
LVDS_GRP_PARAM = (0x0 << 15) | (0x8 << 10) | (0x8 << 5) | 0x1E | 0x1
INIT_RECIPE = [
    ('W', 0x01160400, 0x101, 'Enable LVDS configuration broadcast.'),
    ('W', 0x01160000, 0x004, 'LVDS control: send_mode=1, parallel TX/RX enabled.'),
    ('W', 0x01160004, LVDS_GRP_PARAM, 'LVDS group 0 parameters.'),
    ('W', 0x01160024, LVDS_GRP_PARAM, 'LVDS group 1 parameters.'),
    ('W', 0x01160044, LVDS_GRP_PARAM, 'LVDS group 2 parameters.'),
    ('W', 0x01160064, LVDS_GRP_PARAM, 'LVDS group 3 parameters.'),
    ('W', 0x01160400, 0x000, 'Disable LVDS configuration writes.'),
    ('W', 0x02FFF000, 0x101, 'Enable core configuration and broadcast writes.'),
    ('W', 0x02FFF00C, 0x000, 'Set the broadcast core selection.'),
    ('W', 0x0208000C, 0x000, 'Disable the configuration clock.'),
    ('W', 0x02080010, 0x002, 'Core light-sleep control.'),
    ('W', 0x0208001C, 0x007, 'Enable move, soma and dendrite clock gating.'),
    ('W', 0x02080000, 0x001, 'Release core resets.'),
    ('W', 0x02FFF000, 0x001, 'Disable broadcast; keep configuration access enabled.'),
]


def parse_lvds_config(path):
    """Read (lvds, dy, dx, end_packet, end_num, addr, send_mode, body) rows."""
    rows = []
    with io.open(path, encoding='utf-8') as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            parts = line.split(',')
            if len(parts) != 8:
                raise ValueError('%s:%d 字段数 %d != 8' % (path, ln, len(parts)))
            lvds, dy, dx, endp, endn, addr, mode = (int(x) for x in parts[:7])
            body = int(parts[7], 16)
            if mode != 1:
                raise ValueError('%s:%d send_mode=%d(基线 a2a 恒 1)' % (path, ln, mode))
            rows.append((lvds, dy, dx, endp, endn, addr, mode, body))
    return rows


def pack_pkt(lvds, dy, dx, endp, endn, addr, body):
    base = ((lvds & 0x3) << 4) | ((dy & 0x3F) << 6) | ((dx & 0x3F) << 12)
    if endp:
        return ((endn & 0x7FFF) << 32) | base | 0b0100
    return ((body & (1 << 64) - 1) << 32) | ((addr & 0x3FFF) << 18) | base | 0b0010


def unpack_pkt(pkt):
    typ = pkt & 0xF
    lvds = (pkt >> 4) & 0x3
    dy = (pkt >> 6) & 0x3F
    dx = (pkt >> 12) & 0x3F
    if typ == 0b0100:
        return (lvds, dy, dx, 1, (pkt >> 32) & 0x7FFF, 0, 1, 0)
    if typ == 0b0010:
        return (lvds, dy, dx, 0, 0, (pkt >> 18) & 0x3FFF, 1, pkt >> 32)
    raise ValueError('未知包 TYPE %x' % typ)


def pack_record(pkt, ch=0, flags=0, tag=0):
    v = ((tag & 0xFFFF) << 112) | ((flags & 0xFF) << 104) | ((ch & 0xFF) << 96) | pkt
    return v.to_bytes(16, 'little')


def unpack_record(b16):
    v = int.from_bytes(b16, 'little')
    return {'tag': v >> 112, 'flags': (v >> 104) & 0xFF,
            'ch': (v >> 96) & 0xFF, 'pkt': v & (1 << 96) - 1}


def parse_at_pairs(path):
    """Read @address data rows without discarding repeated addresses."""
    rows = []
    with io.open(path, encoding='utf-8') as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            m = re.match(r'^@([0-9a-fA-F]+)\s+([0-9a-fA-F]+)$', line)
            if not m:
                raise ValueError('%s:%d 非 @addr data 格式: %r' % (path, ln, line))
            rows.append((int(m.group(1), 16), int(m.group(2), 16)))
    return rows


def parse_at_file(path):
    """Read final memory/register values; the last row at each address wins."""
    return dict(parse_at_pairs(path))


def read_pairs(path):
    """Read y/x coordinate pairs."""
    out = []
    with io.open(path, encoding='utf-8') as f:
        for line in f:
            p = line.split()
            if len(p) == 2:
                out.append((int(p[0]), int(p[1])))
    return out


def do_export(case_dir, outdir, ch=0, irq_last=False):
    os.makedirs(outdir, exist_ok=True)
    report = {'case': os.path.abspath(case_dir)}

    # SEND record image.
    lc = os.path.join(case_dir, 'lvds_config.txt')
    n_rec = 0
    if os.path.isfile(lc):
        rows = parse_lvds_config(lc)
        with open(os.path.join(outdir, 'send_image.bin'), 'wb') as f:
            for i, r in enumerate(rows):
                lvds, dy, dx, endp, endn, addr, _, body = r
                flags = 0
                if endp:
                    flags |= FLAG_FENCE
                if i == len(rows) - 1:
                    flags |= FLAG_LAST
                    if irq_last:
                        flags |= FLAG_IRQ
                f.write(pack_record(pack_pkt(lvds, dy, dx, endp, endn, addr, body),
                                    ch=ch, flags=flags))
        n_rec = len(rows)
    report['send_records'] = n_rec

    # Per-core images from die subdirectories or a flat case directory.
    manifest = []
    die_dirs = sorted(d for d in os.listdir(case_dir)
                      if d.startswith('die_') and os.path.isdir(os.path.join(case_dir, d)))
    scopes = [(d, os.path.join(case_dir, d)) for d in die_dirs] or [('die_0_0', case_dir)]
    for die_name, droot in scopes:
        for fn in sorted(os.listdir(droot)):
            m = re.match(r'^(\d+)_(\d+)_mem_config\.txt$', fn)
            if not m:
                continue
            y, x = int(m.group(1)), int(m.group(2))
            lines = parse_at_file(os.path.join(droot, fn))
            addrs = sorted(lines)
            blob_name = 'boot_prim_%s_%d_%d.bin' % (die_name, y, x)
            with open(os.path.join(outdir, blob_name), 'wb') as f:
                for a in addrs:
                    f.write(lines[a].to_bytes(32, 'little'))
            contiguous_head = addrs == list(range(len(addrs)))
            # Each segment describes destination rows for the next part of the blob.
            segments = []
            for a in addrs:
                if segments and a == segments[-1][0] + segments[-1][1]:
                    segments[-1][1] += 1
                else:
                    segments.append([a, 1])
            manifest.append({
                'die': die_name, 'core_y': y, 'core_x': x,
                'file': blob_name, 'lines': len(lines),
                'start_line': addrs[0] if addrs else 0,
                'kind': ('boot_chain' if len(lines) <= 5 and contiguous_head
                         else 'full_image'),
                'line_addrs_contiguous': contiguous_head,
                'segments': segments,
            })
    with io.open(os.path.join(outdir, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump({'case': report['case'], 'send_records': n_rec, 'ch': ch,
                   'cores': manifest}, f, ensure_ascii=False, indent=1)
    report['cores'] = len(manifest)

    # Initialization recipe and per-core start sequences.
    cores = []
    core_config = {}
    for die_name, droot in scopes:
        cl = os.path.join(droot, 'core_list.txt')
        if os.path.isfile(cl):
            for y, x in read_pairs(cl):
                key = (die_name, y, x)
                cores.append(key)
                ctrl = os.path.join(droot, '%d_%d_ctrl_config.txt' % (y, x))
                cfg = parse_at_file(ctrl).get(0x80008, 0x4) if os.path.isfile(ctrl) else 0x4
                core_config[key] = cfg & ~0x1
    with io.open(os.path.join(outdir, 'init_regs.txt'), 'w', encoding='utf-8') as f:
        f.write('# SPI recipe: W address data; P address mask value; F marks a SEND transfer.\n')
        for op, a, v, cmt in INIT_RECIPE:
            f.write('%s %08X %08X  # %s\n' % (op, a, v, cmt))
        f.write('# Core image loading is external; see manifest.json.\n')
        for die_name, y, x in cores:
            f.write('W 02FFF00C %08X  # Select core %s (%d,%d).\n' % ((y << 2) | x, die_name, y, x))
            # Pulse config_en; preserve the other CONFIG bits.
            cfg = core_config[(die_name, y, x)]
            f.write('W 02080008 %08X  # config_en=1; preserve core CONFIG\n' % (cfg | 0x1))
            f.write('W 02080008 %08X  # config_en=0\n' % cfg)
            f.write('W 02080004 00000001  # Start%s.\n'
                    % (' (receive stage)' if n_rec else ''))
            f.write('W 02080004 00000000\n')
        if n_rec:
            # LVDS cases: receive the SEND image, then start computation.
            f.write('F 00000000 00000000  # Send send_image.bin and wait for SEND completion.\n')
            for die_name, y, x in cores:
                f.write('W 02FFF00C %08X  # Select core %s (%d,%d).\n' % ((y << 2) | x, die_name, y, x))
                f.write('P 02080018 00000001 00000001  # Wait for receive completion.\n')
            f.write('# Start computation without another CONFIG pulse.\n')
            for die_name, y, x in cores:
                f.write('W 02FFF00C %08X  # Select core %s (%d,%d).\n' % ((y << 2) | x, die_name, y, x))
                f.write('W 02080004 00000001  # Start computation.\n')
                f.write('W 02080004 00000000\n')
            for die_name, y, x in cores:
                f.write('W 02FFF00C %08X  # Select core %s (%d,%d).\n' % ((y << 2) | x, die_name, y, x))
                f.write('P 02080018 00000001 00000001  # Wait for compute completion.\n')
        else:
            # Memory-only cases start once and wait until idle.
            for die_name, y, x in cores:
                f.write('W 02FFF00C %08X  # Select core %s (%d,%d).\n' % ((y << 2) | x, die_name, y, x))
                f.write('P 02080018 00000001 00000001  # Wait for compute completion.\n')
    report['init_cores'] = len(cores)
    return report


def do_compare(golden_path, dump_path, mode='packets'):
    """Compare complete packet multisets or selected final memory values."""
    if mode == 'memory':
        g, s = parse_at_file(golden_path), parse_at_file(dump_path)
        miss = sorted(a for a in g if a not in s)
        bad = sorted(a for a in g if a in s and g[a] != s[a])
        for a in miss[:10]:
            print('MISSING @%04x' % a)
        for a in bad[:10]:
            print('MISMATCH @%04x golden=%x sim=%x' % (a, g[a], s[a]))
        print('memory: %d golden addresses | missing %d | mismatched %d'
              % (len(g), len(miss), len(bad)))
        return 0 if not (miss or bad) else 1

    g = Counter(parse_at_pairs(golden_path))
    s = Counter(parse_at_pairs(dump_path))
    missing, extra = g - s, s - g
    for (address, value), count in sorted(missing.items())[:10]:
        print('MISSING @%04x data=%x count=%d' % (address, value, count))
    for (address, value), count in sorted(extra.items())[:10]:
        print('EXTRA   @%04x data=%x count=%d' % (address, value, count))
    print('packets: %d golden | missing %d | extra %d'
          % (sum(g.values()), sum(missing.values()), sum(extra.values())))
    return 0 if not (missing or extra) else 1


def do_selftest(case_dir, outdir):
    rep = do_export(case_dir, outdir)
    lc = os.path.join(case_dir, 'lvds_config.txt')
    if not os.path.isfile(lc):
        print('selftest: 无 lvds_config(纯后门测例),跳过记录流核对;export 报告:', rep)
        return 0
    rows = parse_lvds_config(lc)
    with open(os.path.join(outdir, 'send_image.bin'), 'rb') as f:
        blob = f.read()
    assert len(blob) == 16 * len(rows), '记录数 %d != 行数 %d' % (len(blob) // 16, len(rows))
    n_fence = 0
    for i, r in enumerate(rows):
        rec = unpack_record(blob[16 * i:16 * i + 16])
        back = unpack_pkt(rec['pkt'])
        want = (r[0], r[1] & 0x3F, r[2] & 0x3F, r[3], r[4] & 0x7FFF if r[3] else 0,
                0 if r[3] else r[5] & 0x3FFF, 1, 0 if r[3] else r[7])
        assert back == want, '第 %d 行往返不一致: %r vs %r' % (i, back, want)
        if r[3]:
            assert rec['flags'] & FLAG_FENCE, '第 %d 行 end 包未置 fence' % i
            n_fence += 1
        assert bool(rec['flags'] & FLAG_LAST) == (i == len(rows) - 1)
    print('selftest PASS:%d 条记录往返一致,fence=%d,last=1;export 报告: %s'
          % (len(rows), n_fence, rep))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd')
    e = sub.add_parser('export')
    e.add_argument('case_dir')
    e.add_argument('-o', '--out', required=True)
    e.add_argument('--ch', type=int, default=0)
    e.add_argument('--irq-last', action='store_true')
    c = sub.add_parser('compare')
    c.add_argument('golden')
    c.add_argument('dump')
    c.add_argument('--mode', choices=('packets', 'memory'), default='packets',
                   help='packets: exact multiset; memory: selected final address values')
    s = sub.add_parser('selftest')
    s.add_argument('case_dir')
    s.add_argument('-o', '--out', default='/tmp/tj_image_selftest')
    a = ap.parse_args()
    if a.cmd == 'export':
        print(json.dumps(do_export(a.case_dir, a.out, a.ch, a.irq_last)))
        return 0
    if a.cmd == 'compare':
        return do_compare(a.golden, a.dump, a.mode)
    if a.cmd == 'selftest':
        return do_selftest(a.case_dir, a.out)
    ap.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main())
