#!/usr/bin/env python3
"""Build and run the SEND regression with VCS (Python 3.6+, standard library only)."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


RATIOS = (("default", 5.0, 1.2), ("delivery", 2.0, 10.0), ("boundary", 50.0, 5.0))
TESTS = ("system", "events", "count", "cdc", "engine", "axi")
FAILURE = re.compile(r"(?im)^.*(?:\bFAIL\b|\bTIMEOUT\b|\bFATAL\b|Error[-:]).*$")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def make_image(path):
    """Generate 300 little-endian records without importing DUT format constants."""
    with path.open("wb") as stream:
        for index in range(300):
            packet = (0x13579BDF << 64) | (index << 32) | 0x2468ACE0
            flags = 0x01 if index == 299 else 0
            record = (index << 112) | (flags << 104) | ((index % 3) << 96) | packet
            stream.write(record.to_bytes(16, "little"))


class Regression:
    def __init__(self, controller, output):
        self.controller = controller
        self.output = output
        self.results = []
        self.inputs = {}

    def step(self, name, command, work, pass_prefix=None, rejection=None):
        log = self.output / (name + ".log")
        with log.open("wb") as stream:
            try:
                process = subprocess.run([str(arg) for arg in command], cwd=str(work),
                                         stdout=stream, stderr=subprocess.STDOUT, timeout=300)
                status = process.returncode
            except subprocess.TimeoutExpired:
                status = 124
                stream.write(b"\nTIMEOUT: command exceeded 300 seconds\n")
        text = log.read_text(encoding="utf-8", errors="replace")
        errors = FAILURE.findall(text)
        passed = []
        if pass_prefix:
            expression = r"^" + re.escape(pass_prefix) + r" TB PASS \([1-9][0-9]* checks\)$"
            passed = re.findall(expression, text, re.M)
        ok = status == 0 and not errors and (bool(passed) if pass_prefix else True)
        if rejection:
            ok = status != 124 and rejection in text and bool(errors)
        self.results.append({"name": name, "command": [str(arg) for arg in command],
                             "returncode": status, "expected_rejection": rejection,
                             "ok": ok, "pass_lines": passed, "failure_lines": errors})
        write_json(self.output / "results.json", self.results)
        detail = " | ".join(passed) if passed else ("expected rejection" if rejection and ok else "")
        print("{}: {} {}".format(name, "PASS" if ok else "FAIL", detail).rstrip(), flush=True)
        if not ok:
            raise RuntimeError("{} failed; see {}".format(name, log))

    def build(self, name, top, files, width=None):
        work = self.output / name
        work.mkdir()
        for path in files:
            relative = str(path.relative_to(self.controller))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if relative in self.inputs and self.inputs[relative] != digest:
                raise RuntimeError("Input changed during regression: " + relative)
            self.inputs[relative] = digest
        write_json(self.output / "inputs.json", self.inputs)
        options = ["+define+TEST_DW=" + str(width)] if width is not None else []
        self.step(name + "_compile", ["vlogan", "-full64", "-sverilog", "-nc",
                  "-timescale=1ns/1ps"] + options + files, work)
        rejection = "tj_axi_rd_backend requires AXI_DW=128" if width in (256, 512) else None
        self.step(name + "_elaborate", ["vcs", "-full64", "-nc", top, "-o", "simv"],
                  work, rejection=rejection)
        return work

    def verify_inputs(self):
        for relative, expected in self.inputs.items():
            actual = hashlib.sha256((self.controller / relative).read_bytes()).hexdigest()
            if actual != expected:
                raise RuntimeError("Input changed during regression: " + relative)


def sources(controller, model):
    cdc = "tb/common/tj_cdc_jit.sv" if model == "jitter" else "rtl/common/tj_cdc.sv"
    return [controller / name for name in (
        "rtl/pkg/tj_ctrl_pkg.sv", cdc,
        "rtl/dma/tj_send_fetch.sv", "rtl/dma/tj_send_engine.sv",
        "rtl/dma/tj_send_subsys.sv", "rtl/dma/tj_axi_rd_backend.sv",
        "rtl/csr/tj_ctrl_csr_pkg.sv", "rtl/csr/tj_ctrl_csr.sv")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, help="New or empty build/log directory")
    parser.add_argument("--tests", nargs="+", choices=TESTS, default=list(TESTS))
    parser.add_argument("--model", choices=("both", "plain", "jitter"), default="both")
    parser.add_argument("--seeds", nargs="+", type=int, default=[1, 2, 3, 4])
    args = parser.parse_args()
    controller = Path(__file__).resolve().parents[2]
    output = args.out_dir.resolve() if args.out_dir else Path(tempfile.mkdtemp(prefix="tj_send_"))
    if output.exists() and any(output.iterdir()):
        parser.error("--out-dir must be empty: " + str(output))
    output.mkdir(parents=True, exist_ok=True)
    models = ("plain", "jitter") if args.model == "both" else (args.model,)
    cases = {
        "system": ("tb_tj_send", "tb/send/tb_tj_send.sv", "SEND"),
        "events": ("tb_tj_send_events", "tb/send/tb_tj_send_events.sv", "SEND EVENTS"),
        "count": ("tb_tj_send_count", "tb/send/tb_tj_send_count.sv", "SEND COUNT"),
        "cdc": ("tb_tj_cdc_startup", "tb/common/tb_tj_cdc_startup.sv", "CDC STARTUP"),
    }
    image = output / "records_300.bin"
    if "system" in args.tests:
        make_image(image)
    run = Regression(controller, output)
    print("Results: " + str(output), flush=True)
    try:
        for test in args.tests:
            if test == "engine":
                work = run.build("engine", "tb_tj_send_engine", [controller / name for name in (
                    "rtl/pkg/tj_ctrl_pkg.sv", "rtl/dma/tj_send_engine.sv",
                    "tb/send/tb_tj_send_engine.sv")])
                run.step("engine_run", ["./simv", "-nc"], work, pass_prefix="SEND ENGINE")
                continue
            if test == "axi":
                for width in (128, 256, 512):
                    name = "axi_" + str(width)
                    work = run.build(name, "tb_tj_axi_rd_backend", [controller / relative for relative in (
                        "rtl/dma/tj_axi_rd_backend.sv", "tb/send/tb_tj_axi_rd_backend.sv")], width)
                    if width == 128:
                        run.step(name + "_run", ["./simv", "-nc"], work,
                                 pass_prefix="AXI READ BACKEND")
                continue
            top, relative, prefix = cases[test]
            for model in models:
                files = sources(controller, model)
                if test == "cdc":
                    files = [files[1]]
                if test == "system":
                    files.append(controller / "tb/send/tj_send_verification_top.sv")
                files.append(controller / relative)
                name = test + "_" + model
                work = run.build(name, top, files)
                for ratio, pclk_hp, maxi_hp in RATIOS:
                    for seed in (args.seeds[:1] if model == "plain" else args.seeds):
                        command = ["./simv", "-nc", "+TJ_PCLK_HP=" + str(pclk_hp),
                                   "+TJ_MAXI_HP=" + str(maxi_hp), "+ntb_random_seed=" + str(seed)]
                        if test == "system":
                            command.append("+IMG=" + str(image))
                        run.step("{}_{}_{}".format(name, ratio, seed), command, work,
                                 pass_prefix=prefix)
        run.verify_inputs()
    except (RuntimeError, OSError) as error:
        print("SEND REGRESSION FAIL: " + str(error), file=sys.stderr)
        return 1
    count = sum(bool(row["pass_lines"]) for row in run.results)
    rejected = sum(bool(row["expected_rejection"]) for row in run.results)
    print("SEND REGRESSION PASS ({} simulations, {} expected rejections)".format(count, rejected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
