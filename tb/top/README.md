# Controller top tests

`tb_tj_ctrl_apb_smoke.sv` checks ID, SCRATCH, APB responses and chip reset outputs.
The shared-library stage of `controller/scripts/run_regress.sh` runs this test.
`run_top_tb.py` runs the separate timestamp and top-level control test below.

`tb_tj_ctrl_ts.sv` uses public APB and top-level ports. CASE 0 checks APB routing,
pin outputs, interrupt groups and configuration-chain readback. CASE 1 checks
continuous HI/LO/HI timestamp reads. CASE 2 checks all four prescalers, stopped
count retention, timestamp clear and GLB soft reset.

APB completion requires PREADY to be a known 1. The configuration-chain model
checks the full read request against the programmed address and instance.
Continuous timestamp reads must advance over the observation window; adjacent
reads may return the same snapshot.

```sh
python3 controller/tb/top/run_top_tb.py --work /tmp/tj_top_plain --seed 1
python3 controller/tb/top/run_top_tb.py --work /tmp/tj_top_jitter --jitter --seed 1 --seed 2
```

Each invocation requires a new work directory. `--case` selects 0, 1 or 2;
`--cdc-model` selects an additional simulation-only CDC model when required.
Clock half-period options are in ns:

| Clock ratio | `--pclk-hp` | `--maxi-hp` |
|---|---:|---:|
| Default | 5.0 | 1.2 |
| Delivery | 2.0 | 10.0 |
| Boundary | 50.0 | 5.0 |

The timestamp may lag its source counter. Stop/clear tests wait for control and
snapshot propagation; they do not treat APB write completion as snapshot completion.
The continuous-read test does not reach the low-32-bit natural wrap.

The production filelist is `controller/flist/tj_ctrl.f`. The separate
`tj_ctrl_cosim.f` adds optional link adapters; chip-link simulation also needs
the sources and models in `controller/tb/lnk/lvds_files.f`.

Load the tool-specific `controller/scripts/tj_ts_snapshot*` constraints after
defining clocks and `TJ_TS_PCLK_PERIOD` in ns. Check `u_ts_rd_syn` snapshot
endpoints after synthesis. Do not cut snapshot data with a blanket asynchronous
clock-group exception. RECV and SEND have their own snapshot constraint fragments.
