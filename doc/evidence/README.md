# Quartus 块级构建报告

2026-08-12 的两个工程使用 Quartus Prime Pro 24.3.0 Build 212，顶层为虚拟引脚的 `tj_ctrl_top`。
两组报告的时钟均为 `pclk=250 MHz`、`maxi_clk=100 MHz`。

| 目标器件 | 综合 | 布局布线 | 时序 |
|---|---|---|---|
| Agilex 7 `AGIB041R29D1E2VB` | [报告](agilex7.syn.summary) | [报告](agilex7.fit.summary) | [报告](agilex7.sta.summary) |
| Cyclone 10 GX `10CX220YF672E5G` | [报告](cyclone10gx.syn.summary) | [报告](cyclone10gx.fit.summary) | [报告](cyclone10gx.sta.summary) |

Agilex 7 的 `pclk` 建立余量为 +1.363 ns，保持余量为 0.000 ns（TNS 为 0）。
该次 Fitter 报告将器件状态标为 `Preliminary`，时序模型标为 `Final`。
