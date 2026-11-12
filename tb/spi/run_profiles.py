#!/usr/bin/env python3
"""Check both CSR/SPI profiles using Python 3.6 and VCS or Questa."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

CTRL = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', choices=('vcs', 'questa'), default='vcs')
    parser.add_argument('--work', type=Path, default=CTRL / 'build/profiles')
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)

    def run(cmd, cwd, name, marker=None):
        result = subprocess.run([str(v) for v in cmd], cwd=str(cwd),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                encoding='utf-8', errors='replace', timeout=300)
        (cwd / (name + '.log')).write_text(result.stdout, encoding='utf-8')
        bad = re.search(r'\*\* (?:Error|Fatal):|\b(?:FAIL|TIMEOUT)\b|Error-\[', result.stdout)
        if result.returncode or bad or (marker and marker not in result.stdout):
            print(result.stdout[-6000:])
            raise SystemExit('Failed: ' + name)
        print(name + ': PASS', flush=True)

    if args.simulator == 'questa':
        binary = os.environ.get('QUESTA')
        if not binary:
            found = shutil.which('vsim')
            if not found:
                parser.error('Set QUESTA or put vsim on PATH')
            binary = str(Path(found).parent)
        suffix = '.exe' if os.name == 'nt' else ''
        def exe(name):
            return str(Path(binary) / (name + suffix))

    for profile in ('default', 'agilex4'):
        out = work / profile
        out.mkdir(parents=True, exist_ok=True)
        run([sys.executable, CTRL / 'csr/gen_csr.py', CTRL / 'csr/tj_ctrl_csr.yaml',
             '--profile', profile, '--out-rtl', out / 'rtl', '--out-doc', out / 'doc',
             '--out-tb', out / 'tb'], out, 'generate')
        if profile == 'default':
            for a, b in [('rtl/tj_ctrl_csr_pkg.sv', 'rtl/csr/tj_ctrl_csr_pkg.sv'),
                         ('rtl/tj_ctrl_csr.sv', 'rtl/csr/tj_ctrl_csr.sv'),
                         ('tb/tb_tj_ctrl_csr.sv', 'tb/csr/tb_tj_ctrl_csr.sv'),
                         ('doc/tj_ctrl_regmap.md', 'doc/tj_ctrl_regmap.md')]:
                if (out / a).read_text(encoding='utf-8') != (CTRL / b).read_text(encoding='utf-8'):
                    raise SystemExit('Generated file drift: ' + b)
        sources = []
        for line in (CTRL / 'flist/tj_ctrl.f').read_text().splitlines():
            if line.startswith('${TJ_CTRL_HOME}'):
                path = Path(line.replace('${TJ_CTRL_HOME}', str(CTRL)))
                if path.parent == CTRL / 'rtl/csr':
                    path = out / 'rtl' / path.name
                sources.append(path)
        sources += [out / 'tb/tb_tj_ctrl_csr.sv', CTRL / 'tb/spi/tb_tj_spi_profile.sv',
                    CTRL / 'tb/spi/tb_tj_spi_profile_invalid.sv',
                    CTRL / 'tb/top/tb_tj_ctrl_apb_smoke.sv']
        tests = [('tb_tj_ctrl_csr', 'CSR TB PASS'),
                 ('tb_tj_spi_profile', 'SPI PROFILE TB PASS'),
                 ('tb_tj_ctrl_apb_smoke', 'CTRL APB SMOKE TB PASS')]
        if args.simulator == 'questa':
            run([exe('vmap'), '-c'], out, 'vmap')
            if not (out / 'work').exists():
                run([exe('vlib'), 'work'], out, 'vlib')
            run([exe('vlog'), '-sv', '-timescale=1ns/1ps',
                 '+incdir+' + str(CTRL / 'tb/common')] + sources, out, 'compile')
            for top, marker in tests:
                run([exe('vsim'), '-c', '-lic_noqueue', 'work.' + top,
                     '-do', 'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'],
                    out, top, marker)
        else:
            run(['vlogan', '-full64', '-sverilog', '-nc', '-timescale=1ns/1ps',
                 '+incdir+' + str(CTRL / 'tb/common')] + sources, out, 'compile')
            for top, marker in tests:
                run(['vcs', '-full64', '-nc', top, '-o', top], out, top + '_elaborate')
                run([out / top, '-nc'], out, top, marker)
        # A different parameter and CSR bank count must fail explicitly, instead
        # of allowing truncation, inaccessible dies, or reads of absent banks.
        top = 'tb_tj_spi_profile_invalid'
        commands = ([[exe('vsim'), '-c', '-lic_noqueue', 'work.' + top,
                      '-do', 'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0']]
                    if args.simulator == 'questa' else
                    [['vcs', '-full64', '-nc', top, '-o', top], [out / top, '-nc']])
        rejected = False
        for index, cmd in enumerate(commands):
            result = subprocess.run([str(v) for v in cmd], cwd=str(out),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    encoding='utf-8', errors='replace', timeout=300)
            (out / ('invalid_%d.log' % index)).write_text(result.stdout, encoding='utf-8')
            if 'N_SPI_GRP must match the CSR SPI bank count.' in result.stdout:
                rejected = True
                break
            if result.returncode:
                raise SystemExit('Unexpected invalid-profile failure: ' + result.stdout[-2000:])
        if not rejected:
            raise SystemExit('Mismatched SPI/CSR configuration was not rejected')
        print(profile + ' mismatch rejection: PASS', flush=True)
    print('CSR/SPI PROFILES PASS', flush=True)


if __name__ == '__main__':
    main()
