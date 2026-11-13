#!/usr/bin/env python3
"""Run the controller-owned LVDS/link tests with Questa and external chip models."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

CTRL = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('work', nargs='?', type=Path, default=CTRL / 'build/lnk_questa')
    ap.add_argument('seeds', nargs='*', type=int, default=[1, 31, 166])
    args = ap.parse_args()
    selected = os.environ.get('LNK_TESTS', 'lnk tlast cfgchain').split()
    if not selected or set(selected) - {'lnk', 'tlast', 'cfgchain'}:
        ap.error('LNK_TESTS must select lnk, tlast and/or cfgchain')
    link = bool(set(selected) & {'lnk', 'tlast'})
    roots = dict(os.environ, TJ_CTRL_HOME=str(CTRL),
                 YAWING_DESIGN=os.environ.get('YAWING_DESIGN', str(CTRL.parent / 'soc/design')))
    if link and 'DW_SIM_DIR' not in roots:
        ap.error('Set DW_SIM_DIR to the directory containing the licensed DW_ecc.v model')
    binary = os.environ.get('QUESTA')
    if not binary:
        found = shutil.which('vsim')
        if not found:
            ap.error('Set QUESTA or put vsim on PATH')
        binary = str(Path(found).parent)
    suffix = '.exe' if os.name == 'nt' else ''
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)

    def run(tool, options, label, marker=None):
        command = [str(Path(binary) / (tool + suffix))] + [str(v) for v in options]
        result = subprocess.run(command, cwd=str(work), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, encoding='utf-8', errors='replace', timeout=600)
        (work / (label + '.log')).write_text(result.stdout, encoding='utf-8')
        bad = re.search(r'\*\* (?:Error|Fatal):|\b(?:FAIL|TIMEOUT)\b', result.stdout)
        if result.returncode or bad or (marker and not re.search(marker, result.stdout)):
            print(result.stdout[-6000:])
            raise SystemExit('Failed: ' + label)
        if marker:
            print(re.search(marker, result.stdout).group(0) + ' [' + label + ']', flush=True)

    def filelist(path):
        sources = []
        for line in path.read_text().splitlines():
            line = line.split('//', 1)[0].strip()
            if not line:
                continue
            def expand(match):
                name = match.group(1) or match.group(2)
                if name not in roots:
                    ap.error('Set source root ' + name)
                return roots[name]
            line = re.sub(r'\$\{(\w+)\}|\$(\w+)', expand, line)
            if line.startswith('-f '):
                sources.extend(filelist(Path(line[3:])))
            else:
                source = Path(line)
                if not source.is_file():
                    ap.error('Missing source: ' + line)
                sources.append(source)
        return sources

    if link:
        sources = filelist(CTRL / 'tb/lnk/lvds_files.f')
    else:
        sources = [CTRL / 'rtl/lvds/core_cfg/core_cfg_pp.sv',
                   CTRL / 'rtl/lvds/top/lvds_core_cfg_wrap.sv']
    sources += [CTRL / name for name in ('rtl/pkg/tj_ctrl_pkg.sv', 'rtl/pkg/tj_ctrl_if.sv',
                'rtl/csr/tj_ctrl_csr_pkg.sv', 'rtl/csr/tj_ctrl_csr.sv',
                'rtl/lnk/tj_cfgchain_master.sv')]
    if link:
        sources += [CTRL / 'tb/lnk/tj_lnk_plugs.sv', CTRL / 'tb/lnk/tj_lnk_plug_tlast.sv',
                    CTRL / 'tb/lnk/tb_tj_lnk.sv']
    if 'cfgchain' in selected:
        sources.append(CTRL / 'tb/lnk/tb_tj_cfgchain.sv')
    run('vmap', ['-c'], 'vmap')
    if not (work / 'work').exists():
        run('vlib', ['work'], 'vlib')
    run('vlog', ['-sv', '-timescale=1ps/1fs', '+define+FOR_SIM_ONLY', '+define+RTL',
                 '+incdir+' + str(CTRL / 'tb/common')] + sources, 'compile')
    if 'tlast' in selected:
        if not (work / 'tj_soc_lvds').exists():
            run('vlib', ['tj_soc_lvds'], 'soc_vlib')
        run('vmap', ['tj_soc_lvds', work / 'tj_soc_lvds'], 'soc_vmap')
        run('vlog', ['-work', 'tj_soc_lvds', '-sv', '-timescale=1ps/1fs',
                     '+define+FOR_SIM_ONLY', '+define+RTL'] +
            filelist(CTRL / 'tb/lnk/lvds_soc_files.f'), 'soc_compile')
        run('vlog', ['-sv', CTRL / 'tb/lnk/tj_lnk_tlast_cfg.sv'], 'tlast_config')
    tests = []
    if 'lnk' in selected:
        cases = ['+TJ_CASES=' + os.environ['LNK_CASES']] if os.environ.get('LNK_CASES') else []
        for mode in ('211f', '210f'):
            for seed in args.seeds:
                tests.append(('tb_tj_lnk', cases + ['-sv_seed', str(seed)] +
                              (['+GRP210F'] if mode == '210f' else []),
                              'lnk_%s_%d' % (mode, seed), r'LNK TB PASS \([1-9][0-9]* checks\)'))
    if 'tlast' in selected:
        # Always run all scenarios: a selected legacy case must not silently
        # remove the TLAST traffic/coverage checks.
        for mode in ('211f', '210f'):
            for seed in args.seeds:
                tests.append(('tj_lnk_tlast_cfg', ['-sv_seed', str(seed)] +
                              (['+GRP210F'] if mode == '210f' else []),
                              'tlast_%s_%d' % (mode, seed), r'TLAST TB PASS \([1-9][0-9]* checks\)'))
    if 'cfgchain' in selected:
        cases = ['+TJ_CASES=' + os.environ['CFGCHAIN_CASES']] if os.environ.get('CFGCHAIN_CASES') else []
        for hp in ('5.0', '2.0'):
            tests.append(('tb_tj_cfgchain', cases + ['+TJ_PCLK_HP=' + hp],
                          'cfgchain_' + hp, r'CFGCHAIN TB PASS \([1-9][0-9]* checks\)'))
    for top, extra, name, marker in tests:
        # Starter Edition reports its recommended instance capacity as a
        # suppressible performance diagnostic; functional errors remain fatal.
        run('vsim', ['-c', '-lic_noqueue', '-suppress', '14408,16154', 'work.' + top] + extra + ['-do',
            'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'], name, marker)


if __name__ == '__main__':
    main()
