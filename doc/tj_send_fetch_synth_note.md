# SEND 取数 FIFO 综合记录

`tj_send_fetch` 用 `mem_q` 缓冲 DDR 返回的记录。阵列有 256 项，每项 128 位，总容量 4 KiB。
`maxi_clk` 上升沿写入返回数据，读口用 `rptr_q` 选择发给 SEND 引擎的队首记录。

## FPGA 实现

同一份 `tj_send_fetch.sv` 在 Quartus Prime Pro 24.3 的两个 `tj_ctrl_top` 虚拟引脚工程中得到以下结果。
数据取自 2026-11-02 的 `controller.fit.rpt`，`Fitter RAM Summary` 中的 `u_send|u_fetch|mem_q_rtl_0`。

| 目标器件 | 综合后的深度 × 宽度 | 存储资源 |
|---|---|---|
| Cyclone 10 GX `10CX220YF672E5G` | 256 × 106 位 | 3 个 M20K |
| Agilex 7 `AGIB041R29D1E2VB` | 256 × 106 位 | 3 个 M20K |

逻辑接口传递 128 位记录；表中宽度是 Fitter 在该顶层保留下来的存储位。其他器件和顶层应以各自的 Fitter 报告为准。

## 仿真与综合工具

SpyGlass 回归将 `mthresh` 设为 131072，使该 32768 位阵列参与 lint 和 CDC 分析。
早期 Design Compiler U-2022.12-SP3 的通用标准单元试编将阵列映射为触发器，`u_fetch` 占当次顶层面积约 72.7%。
这个比例描述的是该次标准单元映射；Intel FPGA 上的存储资源见上表。

## Quartus 块级构建

从仓库根目录运行以下命令，默认在 `/data_8T_2/$USER/work/quartus-ooc/` 下为本次构建新建一个 `tjctrl-XXXXXX` 目录。
脚本会打印实际路径。也可以传入一个新目录或空目录。如果指定的目录已有内容，脚本会退出并保留原文件。

```sh
sh controller/scripts/run_quartus_ooc.sh
```

默认目标为 Cyclone 10 GX `10CX220YF672E5G`，顶层端口使用虚拟引脚。`FAM` 和 `DEV` 选择器件，
`PCLK_NS` 和 `MAXI_NS` 设置两个时钟周期，默认分别为 4 ns 和 10 ns。交付档使用 `MAXI_NS=20`。

在已安装 Agilex 7 器件库并具备编译许可的 Quartus 环境中，用以下命令按交付时钟构建 `AGIB041R29D1E2VB`。

```sh
FAM="Agilex 7" DEV=AGIB041R29D1E2VB PCLK_NS=4.0 MAXI_NS=20.0 \
  sh controller/scripts/run_quartus_ooc.sh
```

2026-08-12 的 Agilex 7 和 Cyclone 10 GX 块级工程均按 250/100 MHz 运行。
两款器件的综合、资源和时序摘要见[历史 Quartus 报告](evidence/README.md)。
