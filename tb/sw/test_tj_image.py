#!/usr/bin/env python3
"""Check image export and comparison through the public CLI (Python 3.6+)."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[2] / 'sw/tj_image.py'
WORK = None


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.work = WORK / self._testMethodName
        self.work.mkdir()
        self.calls = 0

    def write(self, relative, text):
        path = self.work / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path

    def cli(self, arguments, expected=0):
        self.calls += 1
        command = [sys.executable, str(TOOL)] + [str(x) for x in arguments]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=dict(os.environ, PYTHONIOENCODING='utf-8',
                                         PYTHONDONTWRITEBYTECODE='1'), timeout=30)
        (self.work / ('cli_{}.log'.format(self.calls))).write_bytes(result.stdout)
        (self.work / ('cli_{}.json'.format(self.calls))).write_text(
            json.dumps({'command': command, 'returncode': result.returncode}, indent=2)+'\n',
            encoding='utf-8')
        text = result.stdout.decode('utf-8', errors='replace')
        self.assertEqual(result.returncode, expected, text)
        return text

    def compare(self, golden, actual, expected, mode=None):
        g = self.write('golden.txt', golden)
        a = self.write('actual.txt', actual)
        arguments = ['compare', g, a]
        if mode:
            arguments += ['--mode', mode]
        return self.cli(arguments, expected)

    def export(self, directory='out', extra=()):
        out = self.work / directory
        self.cli(['export', self.work / 'case', '-o', out] + list(extra))
        manifest = json.loads((out / 'manifest.json').read_text(encoding='utf-8'))
        return out, manifest

    @staticmethod
    def restore(out, core):
        blob = (out / core['file']).read_bytes()
        restored = {}
        offset = 0
        for start, count in core['segments']:
            for address in range(start, start + count):
                word = blob[offset:offset + 32]
                if len(word) != 32 or address in restored:
                    raise AssertionError('Invalid image segment layout')
                restored[address] = int.from_bytes(word, 'little')
                offset += 32
        if offset != len(blob):
            raise AssertionError('Segments do not consume the complete blob')
        return restored

    @staticmethod
    def config_writes(out):
        values = []
        for line in (out / 'init_regs.txt').read_text(encoding='utf-8').splitlines():
            fields = line.split('#', 1)[0].split()
            if len(fields) == 3 and fields[0] == 'W' and int(fields[1], 16) == 0x02080008:
                values.append(int(fields[2], 16))
        return values

    def test_packet_exact_and_reordered(self):
        self.compare('@0 aa\n@1 bb\n', '@1 bb\n@0 aa\n', 0)

    def test_packet_missing_and_wrong(self):
        self.compare('@0 aa\n@1 bb\n', '@0 aa\n', 1)
        self.compare('@0 aa\n', '@0 ab\n', 1)

    def test_packet_extra(self):
        self.compare('@0 aa\n', '@0 aa\n@1 bb\n', 1)

    def test_packet_duplicate(self):
        self.compare('@0 aa\n', '@0 aa\n@0 aa\n', 1)

    def test_packet_wrong_prefix(self):
        self.compare('@0 aa\n', '@0 bb\n@0 aa\n', 1)

    def test_packet_multiplicity(self):
        self.compare('@0 aa\n@0 bb\n@0 aa\n', '@0 aa\n@0 aa\n@0 bb\n', 0)
        self.compare('@0 aa\n@0 bb\n@0 aa\n', '@0 aa\n@0 bb\n', 1)

    def test_memory_subset_and_final_value(self):
        self.compare('@0 aa\n', '@0 bb\n@0 aa\n@1 cc\n', 0, 'memory')
        self.compare('@0 aa\n', '@0 bb\n', 1, 'memory')
        self.compare('@0 aa\n@2 cc\n', '@0 aa\n', 1, 'memory')

    def test_dense_layout(self):
        self.write('case/core_list.txt', '0 0\n')
        first, second = bytes(range(32)), bytes(range(32, 64))
        self.write('case/0_0_mem_config.txt', '@0 {:064x}\n@1 {:064x}\n'.format(
            int.from_bytes(first, 'little'), int.from_bytes(second, 'little')))
        out, manifest = self.export()
        core = manifest['cores'][0]
        self.assertEqual(core['segments'], [[0, 2]])
        self.assertEqual(core['kind'], 'boot_chain')
        self.assertEqual((out / core['file']).read_bytes(), first + second)

    def test_sparse_layout(self):
        self.write('case/core_list.txt', '0 0\n')
        self.write('case/0_0_mem_config.txt', '@9 dd\n@0 aa\n@4 cc\n@3 bb\n')
        out, manifest = self.export()
        core = manifest['cores'][0]
        self.assertEqual(core['segments'], [[0, 1], [3, 2], [9, 1]])
        self.assertEqual(self.restore(out, core), {0: 0xaa, 3: 0xbb, 4: 0xcc, 9: 0xdd})

    def test_sparse_relocation(self):
        self.write('case/core_list.txt', '0 0\n')
        self.write('case/0_0_mem_config.txt', '@0 11\n@2 22\n')
        out_a, a = self.export('out_a')
        self.write('case/0_0_mem_config.txt', '@0 11\n@7 22\n')
        out_b, b = self.export('out_b')
        self.assertNotEqual(a['cores'], b['cores'])
        self.assertEqual((out_a / a['cores'][0]['file']).read_bytes(),
                         (out_b / b['cores'][0]['file']).read_bytes())
        self.assertEqual(self.restore(out_a, a['cores'][0]), {0: 0x11, 2: 0x22})
        self.assertEqual(self.restore(out_b, b['cores'][0]), {0: 0x11, 7: 0x22})

    def test_nonzero_base(self):
        self.write('case/core_list.txt', '0 0\n')
        self.write('case/0_0_mem_config.txt', '@100 11\n@101 22\n')
        out, manifest = self.export()
        self.assertEqual(manifest['cores'][0]['segments'], [[0x100, 2]])
        self.assertEqual(self.restore(out, manifest['cores'][0]), {0x100: 0x11, 0x101: 0x22})

    def test_per_core_config(self):
        self.write('case/core_list.txt', '0 0\n0 1\n1 2\n')
        for name, value in [('0_0', 6), ('0_1', 0), ('1_2', 0x45671)]:
            self.write('case/'+name+'_mem_config.txt', '@0 11\n')
            self.write('case/'+name+'_ctrl_config.txt', '@80008 {:x}\n'.format(value))
        out, _ = self.export()
        self.assertEqual(self.config_writes(out), [7, 6, 1, 0, 0x45671, 0x45670])

    def test_config_fallback(self):
        self.write('case/core_list.txt', '0 0\n0 1\n')
        self.write('case/0_0_mem_config.txt', '@0 11\n')
        self.write('case/0_1_mem_config.txt', '@0 22\n')
        self.write('case/0_1_ctrl_config.txt', '@80010 2\n')
        out, _ = self.export()
        self.assertEqual(self.config_writes(out), [5, 4, 5, 4])

    def test_die_scoped_config(self):
        for die, value in [('die_0_0', 6), ('die_0_1', 0)]:
            self.write('case/'+die+'/core_list.txt', '0 0\n')
            self.write('case/'+die+'/0_0_mem_config.txt', '@0 11\n')
            self.write('case/'+die+'/0_0_ctrl_config.txt', '@80008 {:x}\n'.format(value))
        out, _ = self.export()
        self.assertEqual(self.config_writes(out), [7, 6, 1, 0])

    def test_send_records_and_selftest(self):
        self.write('case/core_list.txt', '0 0\n')
        self.write('case/0_0_mem_config.txt', '@0 11\n')
        self.write('case/lvds_config.txt',
                   '0,0,0,0,0,5,1,0123456789abcdef\n1,-1,2,1,7,0,1,0\n')
        out, manifest = self.export(extra=['--ch', '2', '--irq-last'])
        expected = struct.pack('<IIII', 0x00140002, 0x89abcdef, 0x01234567, 2)
        expected += struct.pack('<IIII', 0x2fd4, 7, 0, 0x702)
        self.assertEqual((out / 'send_image.bin').read_bytes(), expected)
        self.assertEqual(manifest['send_records'], 2)
        text = self.cli(['selftest', self.work / 'case', '-o', self.work / 'selftest'])
        self.assertIn('selftest PASS', text)


def main():
    global TOOL, WORK
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool', type=Path, default=TOOL)
    parser.add_argument('--work', type=Path)
    args, remaining = parser.parse_known_args()
    TOOL = args.tool.resolve()
    temporary = None
    if args.work:
        WORK = args.work.resolve()
        WORK.mkdir(parents=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix='tj_image_tests_')
        WORK = Path(temporary.name)
    try:
        result = unittest.main(argv=[sys.argv[0]] + remaining, exit=False).result
        return 0 if result.wasSuccessful() else 1
    finally:
        if temporary:
            temporary.cleanup()


if __name__ == '__main__':
    raise SystemExit(main())
