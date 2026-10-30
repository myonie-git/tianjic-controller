#!/usr/bin/env python3
"""Run public-port controller top checks with Python 3.6 and VCS."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-root', type=Path, default=here.parents[1])
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--jitter', action='store_true')
    parser.add_argument('--cdc-model', type=Path)
    parser.add_argument('--pclk-hp', type=float, default=5.0)
    parser.add_argument('--maxi-hp', type=float, default=1.2)
    parser.add_argument('--seed', type=int, action='append')
    parser.add_argument('--case', type=int, choices=(0, 1, 2), action='append')
    args = parser.parse_args()
    root = args.rtl_root.resolve()
    work = args.work.resolve()
    work.mkdir(parents=True)
    env = dict(os.environ, TJ_CTRL_HOME=str(root))
    filelist = root / 'flist/tj_ctrl.f'
    if args.jitter or args.cdc_model:
        model = (args.cdc_model or root / 'tb/common/tj_cdc_jit.sv').resolve()
        content = filelist.read_text(encoding='utf-8')
        old = '${TJ_CTRL_HOME}/rtl/common/tj_cdc.sv'
        if content.count(old) != 1:
            parser.error('Expected exactly one CDC source in the production filelist.')
        filelist = work / 'input.f'
        filelist.write_text(content.replace(old, str(model)), encoding='utf-8')
    results = []

    def step(name, command, simulation=False):
        with (work / (name + '.log')).open('wb') as out:
            result = subprocess.run([str(x) for x in command], cwd=str(work), env=env,
                                    stdout=out, stderr=subprocess.STDOUT, timeout=300)
        text = (work / (name + '.log')).read_text(encoding='utf-8', errors='replace')
        fail = re.findall(r'(?im)^.*(?:\bFAIL\b|\bTIMEOUT\b|\bFATAL\b|Error[-:]).*$', text)
        passed = re.findall(r'(?m)^CTRL TOP TB PASS \([1-9][0-9]* checks\)$', text)
        ok = result.returncode == 0 and not fail and (bool(passed) or not simulation)
        results.append({'name': name, 'command': [str(x) for x in command],
                        'returncode': result.returncode, 'ok': ok,
                        'pass_lines': passed, 'failure_lines': fail})
        (work / 'results.json').write_text(json.dumps(results, indent=2)+'\n', encoding='utf-8')
        print('{}: {} {}'.format(name, 'PASS' if ok else 'FAIL', ' | '.join(passed)), flush=True)
        return ok

    if not step('compile', ['vlogan', '-full64', '-sverilog', '-nc', '-timescale=1ns/1ps',
                           '-f', filelist, here / 'tb_tj_ctrl_ts.sv']):
        return 1
    if not step('elaborate', ['vcs', '-full64', '-nc', 'tb_tj_ctrl_ts', '-o', 'simv']):
        return 1
    ok = True
    for case in args.case or [0, 1, 2]:
        for seed in args.seed or [1]:
            ok = step('case{}_seed{}'.format(case, seed), ['./simv', '-nc',
                      '+CASE='+str(case), '+ntb_random_seed='+str(seed),
                      '+TJ_PCLK_HP='+str(args.pclk_hp), '+TJ_MAXI_HP='+str(args.maxi_hp)],
                      simulation=True) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
