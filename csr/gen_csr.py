#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate CSR RTL, a register manual, and a testbench from YAML.

Uses a restricted YAML subset and the Python 3.6+ standard library.
"""
import argparse
import hashlib
import io
import os
import re
import sys

SRC_MD5 = 'unknown'  # YAML fingerprint embedded in generated files.

# YAML subset parser.
# Two-space indentation; block maps/lists and single-line inline maps.
# Scalars: strings, decimal/hex integers, and booleans.

def _strip_comment(line):
    out, q = [], None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q:
                q = None
        else:
            if ch in ('"', "'"):
                q = ch
                out.append(ch)
            elif ch == '#':
                break
            else:
                out.append(ch)
    return ''.join(out).rstrip()


def _scalar(tok):
    tok = tok.strip()
    if not tok:
        return None
    if tok[0] in ('"', "'"):
        if len(tok) < 2 or tok[-1] != tok[0]:
            raise ValueError('未闭合引号: %r' % tok)
        return tok[1:-1]
    low = tok.lower()
    if low in ('true', 'yes'):
        return True
    if low in ('false', 'no'):
        return False
    if re.match(r'^0[xX][0-9a-fA-F_]+$', tok):
        return int(tok.replace('_', ''), 16)
    if re.match(r'^-?[0-9][0-9_]*$', tok):
        return int(tok.replace('_', ''))
    return tok


def _split_flow(body):
    """Split an inline mapping at commas outside quoted strings."""
    parts, cur, q = [], [], None
    for ch in body:
        if q:
            cur.append(ch)
            if ch == q:
                q = None
        elif ch in ('"', "'"):
            q = ch
            cur.append(ch)
        elif ch == ',':
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append(''.join(cur))
    return [p.strip() for p in parts if p.strip()]


def _flow_map(text):
    assert text.startswith('{') and text.endswith('}'), '流式 map 格式错: %r' % text
    d = {}
    for ent in _split_flow(text[1:-1]):
        if ':' not in ent:
            raise ValueError('流式 map 项缺冒号: %r' % ent)
        k, v = ent.split(':', 1)
        k = k.strip()
        if k in d:
            raise ValueError('流式 map 重复键: %r' % k)
        d[k] = _scalar(v)
    return d


class _Yaml(object):
    def __init__(self, text):
        self.lines = []
        for raw in text.splitlines():
            s = _strip_comment(raw)
            if not s.strip():
                continue
            ind = len(s) - len(s.lstrip(' '))
            if '\t' in s[:ind + 1]:
                raise ValueError('禁止 TAB 缩进: %r' % raw)
            self.lines.append([ind, s.strip()])
        self.i = 0

    def parse(self):
        val = self._container(0)
        if self.i != len(self.lines):
            raise ValueError('尾部有未解析行: %r' % self.lines[self.i])
        return val

    def _container(self, indent):
        if self.i >= len(self.lines):
            return {}
        ind, txt = self.lines[self.i]
        if ind != indent:
            raise ValueError('缩进错误(期待 %d): %r' % (indent, txt))
        return self._list(indent) if txt.startswith('- ') else self._map(indent)

    def _map(self, indent):
        d = {}
        while self.i < len(self.lines):
            ind, txt = self.lines[self.i]
            if ind < indent:
                break
            if ind > indent:
                raise ValueError('意外缩进: %r' % txt)
            if txt.startswith('- '):
                break
            if ':' not in txt:
                raise ValueError('缺冒号: %r' % txt)
            k, rest = txt.split(':', 1)
            k, rest = k.strip(), rest.strip()
            if k in d:
                raise ValueError('重复键(后者会静默覆盖前者,禁止): %r' % k)
            self.i += 1
            if not rest:  # Nested mapping or list.
                if self.i < len(self.lines) and self.lines[self.i][0] > indent:
                    d[k] = self._container(self.lines[self.i][0])
                else:
                    d[k] = None
            elif rest.startswith('{'):
                d[k] = _flow_map(rest)
            else:
                d[k] = _scalar(rest)
        return d

    def _list(self, indent):
        lst = []
        while self.i < len(self.lines):
            ind, txt = self.lines[self.i]
            if ind != indent or not txt.startswith('- '):
                break
            body = txt[2:].strip()
            if body.startswith('{'):
                lst.append(_flow_map(body))
                self.i += 1
            else:
                # Reuse the mapping parser for this list item.
                self.lines[self.i] = [indent + 2, body]
                lst.append(self._map(indent + 2))
        return lst


# Register model and validation.

KINDS = ('RW', 'RO', 'W1C', 'W1S', 'PULSE')
SV_KEYWORDS = {'global', 'do', 'reg', 'wire', 'logic', 'input', 'output', 'begin',
               'end', 'module', 'signed', 'unsigned', 'if', 'else', 'case', 'type',
               'time', 'table', 'bit', 'byte', 'int', 'ref', 'new', 'this', 'var'}


def _bits(v):
    if isinstance(v, int):
        if not 0 <= v <= 31:
            raise ValueError('bits 越界: %r' % v)
        return v, v
    m = re.match(r'^(\d+)\s*:\s*(\d+)$', str(v))
    if not m:
        raise ValueError('bits 格式错: %r' % v)
    hi, lo = int(m.group(1)), int(m.group(2))
    if hi < lo or hi > 31:
        raise ValueError('bits 越界: %r' % v)
    return hi, lo


class Field(object):
    def __init__(self, d, reg, flat):
        self.name = None if flat else d['name']
        self.hi, self.lo = _bits(d.get('bits', '31:0'))
        self.kind = d.get('kind')
        if self.kind not in KINDS:
            raise ValueError('%s.%s: kind 非法 %r' % (reg, self.name, self.kind))
        self.reset = int(d.get('reset', 0))
        self.const = d.get('const', None)
        self.desc = d.get('desc', '')
        self.w = self.hi - self.lo + 1
        if self.kind == 'RO' and self.const is None:
            self.hw = True          # Hardware-driven RO field.
        else:
            self.hw = False
        if self.const is not None and self.kind != 'RO':
            raise ValueError('%s.%s: const 仅限 RO' % (reg, self.name))
        if self.reset >> self.w:
            raise ValueError('%s.%s: reset 超宽' % (reg, self.name))
        if self.const is not None and (self.const >> self.w):
            raise ValueError('%s.%s: const 超宽' % (reg, self.name))


class Reg(object):
    def __init__(self, d, blk):
        self.name = d['name']
        self.offset = d['offset']
        self.desc = d.get('desc', '')
        self.impl = d.get('impl', blk.impl) or 'v1'
        self.span = d.get('size', 4)          # Byte size; reserved regions may span multiple words.
        self.ro_expr = d.get('ro_expr', None)
        self.hwo = bool(d.get('hwo', False))
        self.target = d.get('target', None)
        self.fields = []
        if self.impl != 'v1':
            return                             # Reserved or external register.
        if 'fields' in d:
            self.fields = [Field(f, self.name, False) for f in d['fields']]
        else:
            self.fields = [Field(d, self.name, True)]
        occ = 0
        for f in self.fields:
            m = ((1 << f.w) - 1) << f.lo
            if occ & m:
                raise ValueError('%s.%s: 字段位重叠' % (blk.name, self.name))
            occ |= m
        if self.offset % 4 or self.offset < 0:
            raise ValueError('%s.%s: 偏移非法(须 ≥0 且 4 对齐)' % (blk.name, self.name))
        if self.ro_expr and any(f.kind != 'RO' for f in self.fields):
            raise ValueError('%s.%s: ro_expr 仅限 RO' % (blk.name, self.name))

    def rw_mask(self):
        m = 0
        for f in self.fields:
            if f.kind == 'RW':
                m |= ((1 << f.w) - 1) << f.lo
        return m

    def reset_val(self):
        v = 0
        for f in self.fields:
            if f.kind in ('RW', 'W1C'):
                v |= f.reset << f.lo
            elif f.kind == 'RO' and f.const is not None:
                v |= f.const << f.lo
        return v


class Block(object):
    def __init__(self, d):
        self.name = d['name']
        self.sv = d.get('sv', self.name.lower())
        self.base = d['base']
        self.size = d['size']
        self.desc = d.get('desc', '')
        self.count = int(d.get('count', 1))
        self.stride = int(d.get('stride', 0))
        self.impl_count = int(d.get('impl_count', self.count))
        self.impl = d.get('impl', 'v1')
        if self.sv in SV_KEYWORDS:
            raise ValueError('块 %s: sv 名撞关键字,请加 sv: 属性' % self.name)
        if not (0 < self.impl_count <= self.count):
            raise ValueError('块 %s: impl_count 必须在 1..count' % self.name)
        if self.count > 1 and (self.stride <= 0 or self.stride % 4):
            raise ValueError('块 %s: stride 非法' % self.name)
        self.regs = [Reg(r, self) for r in d['regs']]
        rn = [r.name for r in self.regs]
        if len(set(rn)) != len(rn):
            raise ValueError('块 %s: 寄存器重名' % self.name)
        # W1S targets must be single-field W1C registers in this block, with matching bit ranges.
        byname = {r.name: r for r in self.regs}
        for r in self.regs:
            has_w1s = any(f.kind == 'W1S' for f in r.fields)
            if r.target and not has_w1s:
                raise ValueError('%s.%s: target 仅限 W1S 寄存器' % (self.name, r.name))
            if has_w1s:
                if not r.target or r.target not in byname:
                    raise ValueError('%s.%s: W1S 缺少有效 target' % (self.name, r.name))
                t = byname[r.target]
                if len(t.fields) != 1 or t.fields[0].kind != 'W1C':
                    raise ValueError('%s.%s: target %s 须为单字段 W1C' % (self.name, r.name, r.target))
                if (t.fields[0].w, t.fields[0].lo) != (r.fields[0].w, r.fields[0].lo):
                    raise ValueError('%s.%s: 与 target %s 位段不一致' % (self.name, r.name, r.target))
        ext = self.stride if self.count > 1 else self.size
        for r in self.regs:
            if r.offset + r.span > ext:
                raise ValueError('%s.%s: 越出块界' % (self.name, r.name))
        if self.count > 1 and self.count * self.stride > self.size:
            raise ValueError('块 %s: count*stride 超 size' % self.name)
        occ = set()
        for r in self.regs:
            for o in range(r.offset, r.offset + r.span, 4):
                if o in occ:
                    raise ValueError('%s.%s: 偏移冲突' % (self.name, r.name))
                occ.add(o)

    def live_regs(self):
        return [r for r in self.regs if r.impl == 'v1']


def load_model(path):
    global SRC_MD5
    with io.open(path, encoding='utf-8') as f:
        text = f.read()
    SRC_MD5 = hashlib.md5(text.encode('utf-8')).hexdigest()[:12]
    doc = _Yaml(text).parse()
    meta = doc['meta']
    blocks = [Block(b) for b in doc['blocks']]
    blocks.sort(key=lambda b: b.base)
    for a, b in zip(blocks, blocks[1:]):
        if a.base + a.size > b.base:
            raise ValueError('块重叠: %s / %s' % (a.name, b.name))
    if blocks[-1].base + blocks[-1].size > (1 << meta['apb_aw']):
        raise ValueError('超出 APB 窗口')
    names = [b.name for b in blocks]
    if len(set(names)) != len(names):
        raise ValueError('块名重复')
    return meta, blocks


# SystemVerilog helpers.

def member(blk, reg, fld):
    p = '%s_%s' % (blk.sv, reg.name.lower())
    if fld.name:
        p += '_%s' % fld.name.lower()
    if p in SV_KEYWORDS:
        raise ValueError('成员名撞关键字: %s' % p)
    return p


def dim(n, w):
    if n > 1 and w > 1:
        return '[%d:0][%d:0] ' % (n - 1, w - 1)
    if n > 1:
        return '[%d:0] ' % (n - 1)
    if w > 1:
        return '[%d:0] ' % (w - 1)
    return ''


def word_expr(blk, reg, idx='k'):
    """Return a decoder address expression in 32-bit words."""
    if blk.count > 1:
        return '%d + %s*%d' % ((blk.base + reg.offset) >> 2, idx, blk.stride >> 2)
    return '%d' % ((blk.base + reg.offset) >> 2)


def resolve_expr(blk, expr):
    """Resolve ro_expr names for RW/W1C registers with one field in this block."""
    out = expr
    for r in blk.live_regs():
        if len(r.fields) == 1 and r.fields[0].kind in ('RW', 'W1C'):
            out = re.sub(r'\b%s\b' % r.name, 'q_' + member(blk, r, r.fields[0]), out)
    return out


def iter_live(blocks):
    for b in blocks:
        if b.impl != 'v1':
            continue
        for r in b.live_regs():
            yield b, r


GEN_HDR = '// 本文件由 gen_csr.py 自动生成(真源 tj_ctrl_csr.yaml,md5=%s),勿手改;\n// 指纹取代日期戳:同一真源再生成逐字节相同,防漂移 diff 可直接做门禁\n'


# SystemVerilog package generation.

def emit_pkg(meta, blocks):
    o = []
    o.append('// =============================================================================')
    o.append('// tj_ctrl_csr_pkg.sv — CSR 偏移常量 + hwi/hwo 结构体(map v%s)' % meta['version'])
    o.append(GEN_HDR % SRC_MD5)
    o.append('// 域契约:CSR 全部位于 pclk;hwi 各成员必须已同步到 pclk(引擎侧负责 CDC),')
    o.append('//         hwo 中 PULSE 成员为单拍脉冲,跨域请自行做脉冲同步。')
    o.append('// =============================================================================')
    o.append('package tj_ctrl_csr_pkg;')
    o.append('')
    for b in blocks:
        tag = '' if b.impl == 'v1' else '(预留 %s)' % b.impl
        o.append('  // ---- %s %s @0x%04X %s' % (b.name, b.desc.split('(')[0], b.base, tag))
        o.append('  localparam int unsigned TJ_CSR_%s_BASE = \'h%04X;' % (b.name, b.base))
        if b.count > 1:
            o.append('  localparam int unsigned TJ_CSR_%s_STRIDE = \'h%02X;' % (b.name, b.stride))
            o.append('  localparam int unsigned TJ_CSR_%s_N = %d;  // 例化数(v1)' % (b.name, b.impl_count))
            o.append('  localparam int unsigned TJ_CSR_%s_N_FULL = %d;  // 地址预留数' % (b.name, b.count))
        for r in b.regs:
            o.append('  localparam int unsigned TJ_CSR_%s_%s = \'h%02X;%s' % (
                b.name, r.name, r.offset, '  // 预留' if r.impl != 'v1' else ''))
        o.append('')
    # Hardware inputs to the CSR block.
    o.append('  typedef struct packed {  // 硬件 → CSR(pclk 同步)')
    for b, r in iter_live(blocks):
        n = b.impl_count if b.count > 1 else 1
        if r.ro_expr:
            continue                     # Derived reads do not need hardware inputs.
        for f in r.fields:
            if f.hw:
                o.append('    logic %s%s;' % (dim(n, f.w), member(b, r, f)))
            elif f.kind == 'W1C':
                o.append('    logic %s%s_set;' % (dim(n, f.w), member(b, r, f)))
    o.append('  } tj_csr_i_t;')
    o.append('')
    # Hardware outputs from the CSR block.
    o.append('  typedef struct packed {  // CSR → 硬件(RW=电平,PULSE=单拍,派生=组合)')
    for b, r in iter_live(blocks):
        n = b.impl_count if b.count > 1 else 1
        for f in r.fields:
            if f.kind in ('RW', 'PULSE'):
                o.append('    logic %s%s;%s' % (dim(n, f.w), member(b, r, f),
                                                '  // PULSE' if f.kind == 'PULSE' else ''))
        if r.hwo and r.ro_expr:
            o.append('    logic %s%s_%s;  // 派生' % (dim(1, 32), b.sv, r.name.lower()))
    o.append('  } tj_csr_o_t;')
    o.append('')
    o.append('endpackage')
    return '\n'.join(o) + '\n'


# APB RTL generation.

def _stor_decl(b, r, f):
    n = b.impl_count if b.count > 1 else 1
    return '  logic %sq_%s;' % (dim(n, f.w), member(b, r, f))


def _rst_val(b, f):
    n = b.impl_count if b.count > 1 else 1
    lit = "%d'h%X" % (f.w, f.reset)
    return ('{%d{%s}}' % (n, lit)) if n > 1 else lit


def _pw(f):
    return 'pwdata[%d:%d]' % (f.hi, f.lo) if f.w > 1 or f.hi > 0 else 'pwdata[%d]' % f.lo


def emit_rtl(meta, blocks):
    aw = meta['apb_aw']
    o = []
    o.append('// =============================================================================')
    o.append('// tj_ctrl_csr.sv — APB 从机 + 寄存器组(map v%s,pclk 单域,零等待)' % meta['version'])
    o.append(GEN_HDR % SRC_MD5)
    o.append('// 行为约定:未映射/预留地址 → pslverr(读返回 0,写忽略);写 RO 忽略不报错;')
    o.append('//           W1C 置位与写清同拍冲突时置位优先;PULSE 读恒 0。')
    o.append('// =============================================================================')
    o.append('module tj_ctrl_csr')
    o.append('  import tj_ctrl_csr_pkg::*;')
    o.append('(')
    o.append('  input  logic              pclk,')
    o.append('  input  logic              presetn,')
    o.append('  input  logic              psel,')
    o.append('  input  logic              penable,')
    o.append('  input  logic              pwrite,')
    o.append('  input  logic [%d:0]       paddr,' % (aw - 1))
    o.append('  input  logic [31:0]       pwdata,')
    o.append('  output logic              pready,')
    o.append('  output logic              pslverr,')
    o.append('  output logic [31:0]       prdata,')
    o.append('  input  tj_csr_i_t         hwi,')
    o.append('  output tj_csr_o_t         hwo')
    o.append(');')
    o.append('')
    o.append('  wire              wr   = psel & penable & pwrite;')
    o.append('  wire [%d:0]       word = paddr[%d:2];' % (aw - 3, aw - 1))
    o.append('')
    # Register storage.
    for b, r in iter_live(blocks):
        for f in r.fields:
            if f.kind in ('RW', 'W1C', 'PULSE'):
                o.append(_stor_decl(b, r, f))
    o.append('')

    # Sequential logic for each register block.
    for b in blocks:
        if b.impl != 'v1':
            continue
        regs = b.live_regs()
        stor = [(r, f) for r in regs for f in r.fields if f.kind in ('RW', 'W1C', 'PULSE')]
        if not stor:
            continue
        n = b.impl_count if b.count > 1 else 1
        o.append('  // ---- %s @0x%04X' % (b.name, b.base))
        o.append('  always_ff @(posedge pclk or negedge presetn) begin')
        o.append('    if (!presetn) begin')
        for r, f in stor:
            o.append('      q_%s <= %s;' % (member(b, r, f), _rst_val(b, f)))
        o.append('    end else begin')
        ind = '      '
        loop = b.count > 1
        if loop:
            o.append('      for (int k = 0; k < %d; k++) begin' % n)
            ind = '        '
        sfx = '[k]' if loop else ''
        for r in regs:
            wexp = 'wr && (word == %s)' % word_expr(b, r)
            # W1S writes targeting this register.
            w1s_src = []
            for r2 in regs:
                if r2.target == r.name:
                    w1s_src.append('((wr && (word == %s)) ? %s : \'0)'
                                   % (word_expr(b, r2), _pw(r2.fields[0])))
            for f in r.fields:
                nm = 'q_%s%s' % (member(b, r, f), sfx)
                if f.kind == 'RW':
                    o.append('%sif (%s) %s <= %s;' % (ind, wexp, nm, _pw(f)))
                elif f.kind == 'W1C':
                    setm = 'hwi.%s_set%s' % (member(b, r, f), sfx)
                    extra = ''.join(' | %s' % s for s in w1s_src)
                    o.append('%s%s <= (%s & ~((%s) ? %s : \'0)) | %s%s;'
                             % (ind, nm, nm, wexp, _pw(f), setm, extra))
                elif f.kind == 'PULSE':
                    o.append('%s%s <= (%s) ? %s : 1\'b0;' % (ind, nm, wexp, _pw(f)))
                # W1S has no storage.
        if loop:
            o.append('      end')
        o.append('    end')
        o.append('  end')
        o.append('')

    # Read data and address decoding.
    o.append('  // ---- 读多路(或树)与地址命中')
    o.append('  logic [31:0] rmux;')
    o.append('  logic        rhit;')
    o.append('  always_comb begin')
    o.append('    rmux = \'0;')
    o.append('    rhit = 1\'b0;')
    for b in blocks:
        if b.impl != 'v1':
            continue
        regs = b.live_regs()
        loop = b.count > 1
        ind = '    '
        if loop:
            o.append('    for (int k = 0; k < %d; k++) begin' % b.impl_count)
            ind = '      '
        sfx = '[k]' if loop else ''
        for r in regs:
            o.append('%sif (word == %s) begin  // %s.%s @0x%04X%s' % (
                ind, word_expr(b, r), b.name, r.name, b.base + r.offset,
                '+k*0x%X' % b.stride if loop else ''))
            o.append('%s  rhit = 1\'b1;' % ind)
            if r.ro_expr:
                o.append('%s  rmux |= (%s);' % (ind, resolve_expr(b, r.ro_expr)))
            else:
                for f in r.fields:
                    if f.kind in ('PULSE', 'W1S'):
                        continue
                    if f.kind == 'RO' and f.const is not None:
                        src = "%d'h%X" % (f.w, f.const)
                    elif f.kind == 'RO':
                        src = 'hwi.%s%s' % (member(b, r, f), sfx)
                    else:
                        src = 'q_%s%s' % (member(b, r, f), sfx)
                    dst = 'rmux[%d:%d]' % (f.hi, f.lo) if f.w > 1 else 'rmux[%d]' % f.lo
                    o.append('%s  %s |= %s;' % (ind, dst, src))
            o.append('%send' % ind)
        if loop:
            o.append('    end')
    o.append('  end')
    o.append('')
    o.append('  assign prdata  = rmux;')
    o.append('  assign pready  = 1\'b1;')
    o.append('  assign pslverr = psel & penable & ~rhit;')
    o.append('')
    # Drive CSR outputs.
    o.append('  // ---- hwo 汇总(全成员显式赋值,无锁存)')
    o.append('  always_comb begin')
    for b, r in iter_live(blocks):
        for f in r.fields:
            if f.kind in ('RW', 'PULSE'):
                m = member(b, r, f)
                o.append('    hwo.%s = q_%s;' % (m, m))
        if r.hwo and r.ro_expr:
            o.append('    hwo.%s_%s = %s;' % (b.sv, r.name.lower(), resolve_expr(b, r.ro_expr)))
    o.append('  end')
    o.append('')
    o.append('endmodule')
    return '\n'.join(o) + '\n'


# Register manual generation.

KIND_ZH = {'RW': 'RW', 'RO': 'RO', 'W1C': 'W1C', 'W1S': 'W1S', 'PULSE': '脉冲'}


def emit_doc(meta, blocks):
    o = []
    o.append('# Tianjic Controller 寄存器手册')
    o.append('')
    o.append('| 项目 | 内容 |')
    o.append('|---|---|')
    o.append('| 映射版本 | v%s |' % meta['version'])
    o.append('| 真源指纹 | md5=%s(gen_csr.py 自动生成,真源 `controller/csr/tj_ctrl_csr.yaml`,勿手改;同源再生成逐字节相同)|'
             % SRC_MD5)
    o.append('| 总线 | APB,32bit 数据,字节地址,窗口 64KB;零等待;未映射/预留地址返回 pslverr |')
    o.append('| 约定 | W1C=硬件置位、写 1 清零(同拍冲突置位优先);脉冲=写 1 出单拍、读恒 0;写 RO 忽略不报错 |')
    o.append('')
    o.append('## 地址总览')
    o.append('')
    o.append('| 基址 | 块 | 实例 | 步进 | 说明 | 实现 |')
    o.append('|---|---|---|---|---|---|')
    for b in blocks:
        inst = ('%d(v1 例化 %d)' % (b.count, b.impl_count)) if b.count > 1 else '1'
        step = '0x%02X' % b.stride if b.count > 1 else '—'
        impl = ('v1' if b.impl == 'v1' else
                '外部模块' if b.impl == 'ext' else '预留(%s)' % b.impl)
        o.append('| 0x%04X | %s | %s | %s | %s | %s |' % (b.base, b.name, inst, step, b.desc, impl))
    o.append('')
    for b in blocks:
        o.append('## %s(基址 0x%04X)' % (b.name, b.base))
        o.append('')
        if b.count > 1:
            o.append('实例 k 的寄存器地址 = 0x%04X + k×0x%02X + 偏移;'
                     '地址预留 %d 实例,v1 例化 %d(其余访问返回 pslverr)。'
                     % (b.base, b.stride, b.count, b.impl_count))
            o.append('')
        o.append('%s' % b.desc)
        o.append('')
        o.append('| 偏移 | 寄存器 | 位 | 字段 | 类型 | 复位 | 说明 |')
        o.append('|---|---|---|---|---|---|---|')
        for r in b.regs:
            if r.impl != 'v1' or b.impl != 'v1':
                span = ('0x%02X~0x%02X' % (r.offset, r.offset + r.span - 4)
                        if r.span > 4 else '0x%02X' % r.offset)
                tag = '外部' if ('ext' in (r.impl, b.impl)) else '预留'
                o.append('| %s | %s | — | — | %s | — | %s |' % (span, r.name, tag, r.desc))
                continue
            first = True
            for f in r.fields:
                bits = ('[%d:%d]' % (f.hi, f.lo)) if f.w > 1 else ('[%d]' % f.lo)
                if f.kind == 'RO' and f.const is not None:
                    rst = '0x%X(常量)' % f.const
                elif f.kind in ('RW', 'W1C'):
                    rst = '0x%X' % f.reset
                else:
                    rst = '—'
                kind = KIND_ZH[f.kind]
                if r.ro_expr:
                    kind = 'RO(派生)'
                desc = f.desc
                if first and r.desc and r.desc != desc:
                    desc = r.desc + ('<br>' + desc if desc else '')
                o.append('| %s | %s | %s | %s | %s | %s | %s |' % (
                    '0x%02X' % r.offset if first else '',
                    r.name if first else '',
                    bits, f.name or '—', kind, rst, desc))
                first = False
        o.append('')
    return '\n'.join(o) + '\n'


# CSR testbench generation.

def emit_tb(meta, blocks):
    aw = meta['apb_aw']
    o = []
    o.append('// File        : tb_tj_ctrl_csr.sv')
    o.append('// Module      : tb_tj_ctrl_csr')
    o.append('// Description : Tests for the Tianjic APB register block.')
    o.append('// Generated by gen_csr.py from tj_ctrl_csr.yaml (md5=%s).' % SRC_MD5)
    o.append('// Regenerate: sh controller/csr/regen.sh; do not edit this file.')
    o.append('// Compile with -timescale=1ns/1ps.')
    o.append('')
    o.append('module tb_tj_ctrl_csr;')
    o.append('  import tj_ctrl_csr_pkg::*;')
    o.append('')
    o.append('  logic pclk = 1\'b0, presetn = 1\'b0;')
    o.append('  always #5 pclk = ~pclk;')
    o.append('')
    o.append('  logic psel, penable, pwrite;')
    o.append('  logic [%d:0] paddr;' % (aw - 1))
    o.append('  logic [31:0] pwdata, prdata;')
    o.append('  logic pready, pslverr;')
    o.append('  tj_csr_i_t hwi;')
    o.append('  tj_csr_o_t hwo;')
    o.append('')
    o.append('  tj_ctrl_csr u_dut (.*);')
    o.append('')
    o.append('  int unsigned errs = 0, checks = 0;')
    o.append('  logic last_err;')
    o.append('  logic [31:0] rd;')
    o.append('')
    o.append('  task automatic apb_wr(input logic [%d:0] a, input logic [31:0] d);' % (aw - 1))
    o.append('    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 1; paddr <= a; pwdata <= d;')
    o.append('    @(posedge pclk); penable <= 1;')
    o.append('    @(posedge pclk);')
    o.append('    chk(pready === 1\'b1, $sformatf("APB write PREADY @%04h", a));')
    o.append('    last_err = pslverr; psel <= 0; penable <= 0;')
    o.append('  endtask')
    o.append('')
    o.append('  task automatic apb_rd(input logic [%d:0] a, output logic [31:0] d);' % (aw - 1))
    o.append('    @(posedge pclk); psel <= 1; penable <= 0; pwrite <= 0; paddr <= a;')
    o.append('    @(posedge pclk); penable <= 1;')
    o.append('    @(posedge pclk);')
    o.append('    chk(pready === 1\'b1, $sformatf("APB read PREADY @%04h", a));')
    o.append('    d = prdata; last_err = pslverr; psel <= 0; penable <= 0;')
    o.append('  endtask')
    o.append('')
    o.append('  task automatic chk(input bit cond, input string msg);')
    o.append('    checks++;')
    o.append('    if (!cond) begin errs++; $display("FAIL: %s", msg); end')
    o.append('  endtask')
    o.append('')
    o.append('  task automatic rdchk(input logic [%d:0] a, input logic [31:0] exp, input string msg);'
             % (aw - 1))
    o.append('    apb_rd(a, rd);')
    o.append('    chk(!last_err && rd === exp, $sformatf("%s: got %08x exp %08x slverr=%b", msg, rd, exp, last_err));')
    o.append('  endtask')
    o.append('')

    # Count control pulses at the output ports.
    pulses = []
    for b, r in iter_live(blocks):
        n = b.impl_count if b.count > 1 else 1
        for f in r.fields:
            if f.kind == 'PULSE':
                pulses.append((b, r, f, n))
    for b, r, f, n in pulses:
        m = member(b, r, f)
        if n > 1:
            o.append('  int unsigned cnt_%s [%d];' % (m, n))
            o.append('  always @(posedge pclk) for (int k = 0; k < %d; k++) if (hwo.%s[k]) cnt_%s[k]++;'
                     % (n, m, m))
        else:
            o.append('  int unsigned cnt_%s;' % m)
            o.append('  always @(posedge pclk) if (hwo.%s) cnt_%s++;' % (m, m))
    o.append('')

    def addr(b, r, k=0):
        return b.base + (k * b.stride if b.count > 1 else 0) + r.offset

    body = []
    A = body.append

    # Reset values.
    A('    // P1: Reset values.')
    for b, r in iter_live(blocks):
        n = b.impl_count if b.count > 1 else 1
        for k in range(n):
            A('    rdchk(\'h%04X, 32\'h%08X, "rst %s[%d].%s");'
              % (addr(b, r, k), r.reset_val(), b.name, k, r.name))

    # RW readback and hardware outputs.
    A('')
    A('    // P2: RW readback and hardware outputs (FF/00/A5).')
    for b, r in iter_live(blocks):
        mask = r.rw_mask()
        if not mask:
            continue
        # Preserve non-RW bits; hardware RO inputs and W1C state are zero here.
        keep = r.reset_val() & ~mask & 0xFFFFFFFF
        n = b.impl_count if b.count > 1 else 1
        for k in range(n):
            a = addr(b, r, k)
            tagn = '%s[%d].%s' % (b.name, k, r.name)
            A('    apb_wr(\'h%04X, 32\'hFFFFFFFF);' % a)
            A('    rdchk(\'h%04X, 32\'h%08X, "wrFF %s");' % (a, (mask | keep) & 0xFFFFFFFF, tagn))
            A('    apb_wr(\'h%04X, 32\'h00000000);' % a)
            A('    rdchk(\'h%04X, 32\'h%08X, "wr00 %s");' % (a, keep, tagn))
            A('    apb_wr(\'h%04X, 32\'hA5A5A5A5);' % a)
            A('    rdchk(\'h%04X, 32\'h%08X, "wrA5 %s");' % (a, (0xA5A5A5A5 & mask) | keep, tagn))
            for f in r.fields:
                if f.kind != 'RW':
                    continue
                m = member(b, r, f)
                exp = (0xA5A5A5A5 >> f.lo) & ((1 << f.w) - 1)
                sfx = '[%d]' % k if n > 1 else ''
                A('    chk(hwo.%s%s === %d\'h%X, "hwo %s.%s");' % (m, sfx, f.w, exp, tagn, f.name or m))

    # W1C event latching, software clear and set priority.
    A('')
    A('    // P3: W1C event latching, software clear and set priority.')
    for b, r in iter_live(blocks):
        n = b.impl_count if b.count > 1 else 1
        for f in r.fields:
            if f.kind != 'W1C':
                continue
            m = member(b, r, f)
            fmask = ((1 << f.w) - 1) << f.lo
            for k in range(n):
                sfx = '[%d]' % k if n > 1 else ''
                a = addr(b, r, k)
                tagn = '%s[%d].%s.%s' % (b.name, k, r.name, f.name or m)
                A('    @(posedge pclk); hwi.%s_set%s <= \'1;' % (m, sfx))
                A('    @(posedge pclk); hwi.%s_set%s <= \'0;' % (m, sfx))
                A('    @(posedge pclk);')
                A('    apb_rd(\'h%04X, rd);' % a)
                A('    chk((rd & 32\'h%08X) === 32\'h%08X, "w1c set %s");' % (fmask, fmask, tagn))
                A('    apb_wr(\'h%04X, 32\'h%08X);' % (a, fmask))
                A('    apb_rd(\'h%04X, rd);' % a)
                A('    chk((rd & 32\'h%08X) === 32\'h0, "w1c clr %s");' % (fmask, tagn))
                A('    // Hardware set takes priority over software clear.')
                A('    hwi.%s_set%s <= \'1;' % (m, sfx))
                A('    apb_wr(\'h%04X, 32\'h%08X);' % (a, fmask))
                A('    apb_rd(\'h%04X, rd);' % a)
                A('    chk((rd & 32\'h%08X) === 32\'h%08X, "w1c set-wins %s");' % (fmask, fmask, tagn))
                A('    @(posedge pclk); hwi.%s_set%s <= \'0;' % (m, sfx))
                A('    @(posedge pclk);')
                A('    apb_wr(\'h%04X, 32\'h%08X);' % (a, fmask))
                A('    apb_rd(\'h%04X, rd);' % a)
                A('    chk((rd & 32\'h%08X) === 32\'h0, "w1c clr2 %s");' % (fmask, tagn))

    # Interrupt test injection and masked status.
    A('')
    A('    // P4: Interrupt test injection and masked status.')
    A('    apb_wr(\'h0100, 32\'hFFFFFFFF);  // Clear pending events.')
    A('    apb_wr(\'h010C, 32\'hF0F0A5A5);  // Inject test events.')
    A('    rdchk(\'h0100, 32\'hF0F0A5A5, "w1s raw");')
    A('    apb_wr(\'h0104, 32\'h00F000F0);  // Enable selected events.')
    A('    rdchk(\'h0108, 32\'h00F000A0, "irq sta = raw&en");')
    A('    chk(hwo.irq_sta === 32\'h00F000A0, "hwo irq_sta");')
    A('    apb_wr(\'h0100, 32\'hFFFFFFFF);')
    A('    apb_wr(\'h0104, 32\'h0);')
    A('    rdchk(\'h0108, 32\'h0, "irq sta clr");')

    # One-cycle control pulses.
    A('')
    A('    // P5: One pulse for a write of 1; no pulse for a write of 0.')
    for b, r, f, n in pulses:
        m = member(b, r, f)
        for k in range(n):
            a = addr(b, r, k)
            idx = '[%d]' % k if n > 1 else ''
            tagn = '%s[%d].%s' % (b.name, k, r.name)
            A('    pc = cnt_%s%s;' % (m, idx))
            A('    apb_wr(\'h%04X, 32\'h%08X);' % (a, 1 << f.lo))
            A('    repeat (3) @(posedge pclk);')
            A('    chk(cnt_%s%s === pc + 1, "pulse1 %s");' % (m, idx, tagn))
            A('    apb_wr(\'h%04X, 32\'h0);' % a)
            A('    repeat (3) @(posedge pclk);')
            A('    chk(cnt_%s%s === pc + 1, "pulse0 %s");' % (m, idx, tagn))

    # Exercise each RO hardware field independently.
    A('')
    A('    // P6: Read each RO hardware field with the other inputs held at zero.')
    for b, r in iter_live(blocks):
        if r.ro_expr:
            continue
        n = b.impl_count if b.count > 1 else 1
        ro = [f for f in r.fields if f.hw]
        if not ro:
            continue
        for k in range(n):
            sfx = '[%d]' % k if n > 1 else ''
            a = addr(b, r, k)
            exp = r.reset_val()
            for f in ro:
                v = (1 << f.w) - 1
                tag = '%s[%d].%s' % (b.name, k, r.name)
                if f.name:
                    tag += '.' + f.name
                A('    hwi.%s%s = %d\'h%X;' % (member(b, r, f), sfx, f.w, v))
                A('    #1;')
                A('    rdchk(\'h%04X, 32\'h%08X, "ro-hw %s");' % (a, exp | (v << f.lo), tag))
                A('    hwi.%s%s = \'0;' % (member(b, r, f), sfx))

    # Unmapped and reserved addresses.
    A('')
    A('    // P7: Unmapped and reserved addresses return PSLVERR and read as zero.')
    holes = [0x0014, 0x0440, 0x04C0, 0x0940, 0x1300, 0x2800, 0x3900, 0x7FFC, 0xFFFC]
    for h in holes:
        A('    apb_rd(\'h%04X, rd);' % h)
        A('    chk(last_err && rd === 32\'h0, "hole rd 0x%04X");' % h)
        A('    apb_wr(\'h%04X, 32\'hDEADBEEF);' % h)
        A('    chk(last_err, "hole wr 0x%04X");' % h)

    # Independent addresses for array instances.
    A('')
    A('    // P8: Array instances retain independent register values.')
    for b in blocks:
        if b.impl != 'v1' or b.count <= 1:
            continue
        r = next((x for x in b.live_regs() if x.rw_mask() == 0xFFFFFFFF), None)
        if r is None:
            continue
        for k in range(b.impl_count):
            A('    apb_wr(\'h%04X, 32\'h%08X);' % (addr(b, r, k), (0x11111111 * (k + 1)) & 0xFFFFFFFF))
        for k in range(b.impl_count):
            A('    rdchk(\'h%04X, 32\'h%08X, "alias %s[%d].%s");'
              % (addr(b, r, k), (0x11111111 * (k + 1)) & 0xFFFFFFFF, b.name, k, r.name))

    o.append('  int unsigned pc;')
    o.append('  initial begin')
    o.append('    psel = 0; penable = 0; pwrite = 0; paddr = \'0; pwdata = \'0; hwi = \'0;')
    o.append('    repeat (5) @(posedge pclk);')
    o.append('    presetn = 1\'b1;')
    o.append('    repeat (2) @(posedge pclk);')
    o.extend(body)
    o.append('')
    o.append('    if (errs == 0) $display("CSR TB PASS (%0d checks)", checks);')
    o.append('    else           $display("CSR TB FAIL (%0d/%0d checks failed)", errs, checks);')
    o.append('    $finish;')
    o.append('  end')
    o.append('')
    o.append('  initial begin #10ms; $display("CSR TB TIMEOUT"); $finish; end')
    o.append('')
    o.append('endmodule')
    return '\n'.join(o) + '\n'


# Command-line entry point.

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('yaml')
    ap.add_argument('--out-rtl', required=True)
    ap.add_argument('--out-doc', required=True)
    ap.add_argument('--out-tb', required=True)
    a = ap.parse_args()

    meta, blocks = load_model(a.yaml)

    live = list(iter_live(blocks))
    n_regs = sum((b.impl_count if b.count > 1 else 1) for b, r in live)
    outs = [
        ('%s/tj_ctrl_csr_pkg.sv' % a.out_rtl, emit_pkg(meta, blocks)),
        ('%s/tj_ctrl_csr.sv' % a.out_rtl, emit_rtl(meta, blocks)),
        ('%s/tj_ctrl_regmap.md' % a.out_doc, emit_doc(meta, blocks)),
        ('%s/tb_tj_ctrl_csr.sv' % a.out_tb, emit_tb(meta, blocks)),
    ]
    for directory in (a.out_rtl, a.out_doc, a.out_tb):
        os.makedirs(directory, exist_ok=True)
    for path, text in outs:
        with io.open(path, 'w', encoding='utf-8') as f:
            f.write(text)
    print('gen_csr: %d blocks, %d live reg instances, outputs:' % (len(blocks), n_regs))
    for path, _ in outs:
        print('  ' + path)


if __name__ == '__main__':
    main()
