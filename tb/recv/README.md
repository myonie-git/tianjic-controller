# RECV tests

| Testbench | Coverage |
|---|---|
| `tb_tj_recv.sv` | Three-channel reception, ring wrap, watermark/END events, overflow policies, disabled channels, write errors, abort and SEND loopback. |
| `tb_tj_recv_end_remap.sv` | Four END encodings and negative controls, identity/swap/rotation mapping, logical ring tags, mapped backpressure and old-ring address retention. |
| `tb_tj_recv_abort.sv` | Both policies during abort/drain, OVF and interrupt reporting, W1C, recovery and the exact abort sampling edge. |
| `tb_tj_recv_pointers.sv` | Continuous write-progress checks and multi-bit host read-pointer updates through the public subsys ports. |

Tests use public module ports without reading DUT internal state. System tests
use APB, AXI and LVDS. The pointer test drives the subsys configuration and record
write interface; the abort suite also has a separate engine port probe.

The comprehensive test models both AXI directions. It checks read/write beat
attributes and write strobes, returns captured transaction IDs, and verifies
records against independently constructed expectations. P8 holds its input packet
until handshake. P9 gives every ring room for all 30 loopback records and checks
the exact completed-write count. END codes and record flags do not use DUT constants.

Run the comprehensive test with Python 3.6 and VCS available in PATH:

```sh
python3 controller/tb/recv/run_recv_tb.py --top /path/to/tj_ctrl_top.sv \
  --work /tmp/tj_recv_main_1 --seed 1 --seed 2
```

Select a focused test with `--testbench`, for example:

```sh
python3 controller/tb/recv/run_recv_tb.py --top /path/to/tj_ctrl_top.sv \
  --testbench controller/tb/recv/tb_tj_recv_abort.sv \
  --work /tmp/tj_recv_abort_1 --seed 1 --seed 2
```

If `controller/rtl/top/tj_ctrl_top.sv` exists, `--top` may be omitted. Before that
integration commit is reviewed, supply an isolated top with RECV REMAP connected
to `hwo.lnk_remap0/1`. The runner does not silently load another checkout's top.
Each invocation requires a new work directory.

All tests accept these clock half-periods, in ns:

| Ratio | `--pclk-hp` | `--maxi-hp` |
|---|---:|---:|
| Default | 5.0 | 1.2 |
| Delivery | 2.0 | 10.0 |
| Boundary | 50.0 | 5.0 |

Add `--jitter` for the shared CDC sampling-delay model. The runner checks exit
status, error/fatal/timeout text and a nonzero PASS count. A PASS line does not
override an error later in the same log.

Configuration is allowed to settle before traffic starts. The comprehensive test
changes ring parameters only after previous writes finish; active ring switching
is not covered by those setup operations. It also runs Host consumption while
receiving. Pointer snapshots may lag the engine or CSR updates; tests wait for final progress
when required without allowing incoherent values. Timestamp rollover is not exercised.

The END/REMAP test also checks buffered write addresses during reconfiguration:
P4 changes the low/high base address and capacity while an old record waits behind
another channel's AXI write; P5 changes only capacity. Both check the old record's
original address and the next record's address under the new configuration.
These checks do not provide or validate a software-visible drain acknowledgment.

## Pointer snapshots

RPTR crosses from pclk to maxi_clk; WPTR crosses in the opposite direction.
LEVEL is calculated in pclk from the visible WPTR snapshot and CSR RPTR.
`tb_tj_recv_pointers.sv` checks write progress at each pclk edge and repeats a
3-to-4 RPTR update while two new records still fit in the ring.

The common snapshot cell and its CDC jitter substitute are reused. Physical
snapshot-data paths require the matching constraints in `controller/scripts/`:
source both `tj_recv_rptr_snapshot*` and `tj_recv_wptr_snapshot*` after defining
clocks and setting `TJ_RECV_MAXI_PERIOD` / `TJ_RECV_PCLK_PERIOD` in ns. Use the
Synopsys, Quartus or Vivado variant for the integration tool. Do not cut the
snapshot data paths with a blanket asynchronous clock-group exception.

RPTR snapshot latency can extend the time the receiver considers a ring full.
With drop policy, packets sent before the update arrives can still be discarded.
P1 waits after its initial Host consumption before starting the next drop-mode
burst; P5 checks continuous consumption with backpressure and no such extra wait.
