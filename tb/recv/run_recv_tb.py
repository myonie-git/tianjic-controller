#!/usr/bin/env python3
"""Compile and run a receive testbench with an explicitly selected controller top."""
import argparse
from pathlib import Path
import re
import subprocess


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-root', type=Path, default=here.parents[1])
    parser.add_argument('--top', type=Path)
    parser.add_argument('--testbench', type=Path, default=here / 'tb_tj_recv.sv')
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--jitter', action='store_true')
    parser.add_argument('--pclk-hp', type=float, default=5.0)
    parser.add_argument('--maxi-hp', type=float, default=1.2)
    parser.add_argument('--seed', type=int, action='append')
    args = parser.parse_args()
    root = args.rtl_root.resolve()
    top = (args.top or root / 'rtl/top/tj_ctrl_top.sv').resolve()
    tb = args.testbench.resolve()
    if not top.is_file():
        parser.error('Controller top is unavailable; pass the test assembly with --top.')
    args.work = args.work.resolve()
    args.work.mkdir(parents=True)
    rtl = [
        'rtl/pkg/tj_ctrl_pkg.sv',
        'tb/common/tj_cdc_jit.sv' if args.jitter else 'rtl/common/tj_cdc.sv',
        'rtl/csr/tj_ctrl_csr_pkg.sv', 'rtl/csr/tj_ctrl_csr.sv',
        'rtl/spi/tj_spi_engine.sv', 'rtl/spi/tj_spi_subsys.sv',
        'rtl/lnk/tj_cfgchain_master.sv', 'rtl/dma/tj_send_fetch.sv',
        'rtl/dma/tj_send_engine.sv', 'rtl/dma/tj_send_subsys.sv',
        'rtl/dma/tj_axi_rd_backend.sv', 'rtl/dma/tj_recv_engine.sv',
        'rtl/dma/tj_recv_subsys.sv', 'rtl/dma/tj_axi_wr_backend.sv',
        'rtl/dma/tj_mem_rd_mux.sv', 'rtl/boot/tj_boot_engine.sv',
        'rtl/boot/tj_boot_subsys.sv',
    ]

    def step(name, command, simulation=False):
        log = args.work / (name + '.log')
        with log.open('wb') as out:
            result = subprocess.run([str(x) for x in command], cwd=str(args.work),
                                    stdout=out, stderr=subprocess.STDOUT, timeout=180)
        text = log.read_text(encoding='utf-8', errors='replace')
        failed = result.returncode or re.search(r'\b(?:FAIL|TIMEOUT)\b|Error-\[|(?:Error|Fatal):', text)
        passed = re.search(r'(?m)^.*\bTB PASS \([1-9][0-9]* checks\).*$', text)
        if failed or (simulation and not passed):
            print('{} FAILED: {}'.format(name, log), flush=True)
            return False
        print(passed.group(0) if passed else name + ' PASS', flush=True)
        return True

    if not step('compile', ['vlogan', '-full64', '-sverilog', '-nc', '-timescale=1ns/1ps'] +
                [root / f for f in rtl] + [top, tb]):
        return 1
    if not step('elaborate', ['vcs', '-full64', '-nc', tb.stem, '-o', 'simv']):
        return 1
    ok = True
    for seed in args.seed or [1]:
        ok = step('seed' + str(seed), ['./simv', '-nc', '+ntb_random_seed=' + str(seed),
                  '+TJ_PCLK_HP=' + str(args.pclk_hp), '+TJ_MAXI_HP=' + str(args.maxi_hp)],
                  simulation=True) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
