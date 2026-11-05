# Tianjic Controller

面向两颗 Yawing04 芯片、共32个 die 的 FPGA 控制器，提供 Host 寄存器访问、
芯片 SPI 控制以及 DDR 与 LVDS 之间的数据收发。
当前顶层集成 CSR、SPI、BOOT、SEND、RECV、配置链主机、时间戳和中断汇总。

## 模块与目录

| 目录 | 内容 |
|---|---|
| `csr/` | 寄存器 YAML 定义、生成器和生成入口 |
| `rtl/pkg/` | 常量、记录格式和数据类型 |
| `rtl/csr/` | 生成的寄存器 RTL |
| `rtl/top/` | 顶层连接、APB 分路、时间戳和中断汇总 |
| `rtl/spi/` | SPI 引擎、门铃、SPIWIN/BOOT仲裁和 SPIWIN 窗口 |
| `rtl/boot/` | BOOT子系统封装、装载控制及64字节取数前端 |
| `rtl/dma/` | SEND 取数与分发、RECV 环形写入、AXI 后端及指针快照同步 |
| `rtl/lnk/` | FPGA 侧配置链主机，以及仿真用的直连和芯片 LVDS 适配模块 |
| `rtl/common/` | 电平、脉冲、事件及整字快照同步单元 |
| `flist/` | 生产 RTL 清单 `tj_ctrl.f`，仿真清单 `tj_ctrl_cosim.f` |
| `scripts/` | 回归、芯片仿真入口和跨域时序约束 |
| `tb/` | 模块测试、镜像检查、初始化重放和芯片联合仿真 |
| `sw/` | 镜像导出、结果比较和格式自检工具 |
| `doc/` | 随源码提供的寄存器手册 |

现有 RTL 模块通过平铺端口连接；`rtl/pkg/tj_ctrl_if.sv` 保留了接口声明，尚未用于这些连接。
生产清单包含 Controller RTL；仿真清单另加 `tj_lnk_plugs.sv`，芯片模型依赖由对应测试清单提供。
BOOT由`tj_boot_subsys`连接控制引擎和取数前端；共享读仲裁位于顶层，SPI仲裁位于SPI子系统。

## 主要接口约定

| 接口 | 当前约定 |
|---|---|
| Host APB | 32位数据，默认16位地址；访问 CSR 和 SPIWIN |
| DDR AXI4 | 默认48位地址、128位数据；SEND 使用 INCR 读突发，RECV 使用单拍写 |
| SPI | 8组引擎，每组选择4个 die；逻辑接口提供32路片选和32路 MISO |
| LVDS 包接口 | 每实例4个96位 `valid/ready/data` 端口；默认3个通道组、1个链路实例 |
| 配置链 | 33位输入、32位读回，配置 FPGA 侧 LVDS 实例，与 `pclk` 同域 |
| 板级控制 | 32路低有效 die 复位输出和4位时钟控制输出；具体引脚映射由外层集成完成 |

`pclk` 用于 CSR、SPI 和配置链，`maxi_clk` 用于 AXI、包收发和时间戳。
`presetn`、`maxi_rstn` 均低有效，必须同源、同时断言。
SPI 的周期参数按 `pclk <= 250 MHz` 设置，软件须选择分频使 SCLK 不超过25 MHz。

DDR 记录为16字节小端格式：`tag[127:112]`、`flags[111:104]`、`ch[103:96]`、`pkt[95:0]`。
SEND 的标志位为 LAST(bit0)、FENCE(bit1)、IRQ(bit2)，按记录中的逻辑通道号和 REMAP 配置分发；
SEND 表起始地址要求64字节对齐。RECV 按通道写入环形缓冲，Host 读取后更新 RPTR 归还空间。
跨域计数和指针通过快照读回，可能滞后于数据通路；具体操作顺序见寄存器及模块说明。

## CDC 时序约束

目标 FPGA 为 Intel Agilex 7 I-Series 的 `AGIB041R29D1E2VB` 或 `AGIB041R29D1E2VC`，两种型号共用 Quartus Prime Pro 的 TimeQuest 约束。
本次 Agilex 7 时序验证采用 `AGIB041R29D1E2VB` 的布线网表。Synopsys 和 Vivado 文件供参考。
先定义 `pclk` 和 `maxi_clk`，再从 `scripts/` 加载所选工具对应的六组约束。

| 工具 | 公共约束 | 五组配套文件的命名 |
|---|---|---|
| Quartus TimeQuest | `tj_ctrl_quartus.sdc` | `tj_<组名>_quartus.sdc` |
| Synopsys DC / PrimeTime | `tj_ctrl.sdc` | `tj_<组名>.sdc` |
| Vivado | `tj_ctrl_vivado.xdc` | `tj_<组名>_vivado.xdc` |

SEND 启动配置的延迟上界目前仅在 Quartus 版实现，预算为一个 `maxi_clk` 周期。

- Synopsys DC 需先设置下表的周期变量，再用 Tcl `source` 逐份加载。直接使用 `read_sdc` 会报错。PrimeTime 尚未验证。
- Vivado 已验证两级同步器的 `ASYNC_REG` 标记。BOOT 时序约束的对象查询还会选中 `CARRY4`，`blk_err` 的 CDC 报告仍待复核。

公共约束覆盖同步器首级和 BOOT 返回的块数据、错误标志。五个组名为 `send_snapshot`、
`ts_snapshot`、`recv_wptr_snapshot`、`recv_rptr_snapshot` 和 `boot_fetch_addr`。
在加载前设置各路径的目的时钟周期（ns）：

| 目的时钟 | 周期变量 |
|---|---|
| `pclk` | `TJ_BOOT_PCLK_PERIOD`、`TJ_SEND_PCLK_PERIOD`、`TJ_TS_PCLK_PERIOD`、`TJ_RECV_PCLK_PERIOD` |
| `maxi_clk` | `TJ_BOOT_MAXI_PERIOD`、`TJ_RECV_MAXI_PERIOD` |

交付时钟示例为 4 ns 和 20 ns。集成到更大的顶层时，将查询限定在 Controller 实例，核对综合后实际命中的寄存器。
两个时钟域之间按路径设置时序例外；整域异步分组会屏蔽这些数据路径的最大延迟约束。

BOOT 在 `maxi_clk` 收到请求时锁存 64 字节对齐的块地址。`boot_fetch_addr` 对请求同步器首级设置例外，
并约束 42 位地址从 `f_blk_addr[47:6]` 到 `addr_q[47:6]` 的最大延迟。
本次 Cyclone 10 GX 实现覆盖三档时钟，布线时采用 2.4 ns 地址预算和 0.30 ns 的
`TJ_BOOT_FIT_HOLD_MARGIN`。签核时取消这个布线裕量，按实际 `maxi_clk` 周期检查建立和保持。

在同一 Cyclone 10 GX 器件上，OOC 脚本将 RECV 读指针的布线最小延迟设为 0.30 ns
（`TJ_RECV_RPTR_FIT_HOLD_MARGIN`）。最终时序分析使用 0 ns 最小延迟和一个 `maxi_clk` 周期的最大延迟。

## 工具与测试入口

以下命令从仓库根目录执行，Shell 示例采用 sh/bash 语法。
Python 工具兼容 Python 3.6，仅使用标准库；RTL 仿真需要 VCS，lint 检查需要 SpyGlass。

修改寄存器定义后，重新生成 RTL、手册和自测代码：

```sh
sh controller/csr/regen.sh
```

模块回归使用本次独立的工作目录；脚本启动时会清空该目录：

```sh
regress_work=$(mktemp -d /tmp/tj_ctrl_regress.XXXXXX)
REGRESS_WORK="$regress_work" sh controller/scripts/run_regress.sh
```

该入口运行生成物一致性、CSR、SPI、顶层展开、APB冒烟、lint和CDC结构检查、镜像工具与格式、
初始化重放、LVDS链路、SEND、RECV和BOOT检查。`SEEDS`、`EXTRA_SEEDS` 控制 SPI 种子，
`DSEEDS` 控制 SEND、RECV、BOOT 种子，默认 `default 31 166 7`；BOOT 每档时钟都运行这些种子。
SEND 另用交付时钟（`pclk` 250 MHz、`maxi_clk` 50 MHz）和默认种子运行一次，跳过镜像重放。
SPI、初始化重放和 BOOT 仿真启用 `TJ_ASSERT_ON`，检查 SPI 引擎接受的命令是否选中本组的 die。
`IMAGE_CASE` 选择镜像格式检查用例，`INIT_CASE` 选择初始化回放用例；
`SKIP_APB_SMOKE`、`SKIP_SG`、`SKIP_LNK` 可跳过对应项目。`SKIP_SG`同时跳过lint与CDC。
CDC使用`controller/scripts/tj_ctrl.sgdc`，检查时钟为pclk=250MHz、maxi_clk=50MHz，不加载豁免文件。
工具或用例不可用时，部分项目也会跳过，运行结果须结合日志中的跳过项查看。

镜像阶段先运行 Python CLI 测试，检查地址段、比较器和各核 CONFIG，再用 SV 核对记录及内存数据。
初始化回放默认使用单 die 用例 `die_extern/resnet9_lvds`。
初始化重放测例执行 `W` 和 `P`，用 `D` 选择 die0或die1，分别核对每个die的AHB读写。
测例跳过 `B` 和 `F`，并统计跳过的 `F` 数量；两个存储模型均预置 `IDLE=1`。
BOOT 测例 [tb_tj_boot.sv](tb/boot/tb_tj_boot.sv) 通过 die 0 的 `spi2ahb` 比对 AHB 写入。
它检查等待 DDR 时中止、原语写入中止、首次通过 APB 读到 `BUSY=0` 时的 `DONE/ERR`、DST 边界和装载期间的 SPIWIN 读取。
回归的 BOOT 阶段共用一次编译，按三组 `pclk/maxi_clk` 频率运行（MHz）：100/416.7、250/50、10/100。
芯片模型的 AHB 时钟固定为 100 MHz。
专项测试及其时钟、抖动配置使用各自入口：

| 测试 | 说明 |
|---|---|
| SPI、门铃、仲裁和超时恢复 | [SPI 测试](tb/spi/README.md) |
| LVDS 链路及配置链 | [链路测试](tb/lnk/README.md) |
| SEND、计数、事件和中止 | [SEND 测试](tb/send/README.md) |
| RECV、环指针、重映射和中止 | [RECV 测试](tb/recv/README.md) |
| 顶层控制和时间戳 | [顶层测试](tb/top/README.md) |

芯片联合仿真单独运行，依赖原生芯片环境、VIP 和 RISC-V 工具链：

```sh
sh controller/scripts/run_chip_sim.sh /data_8T_2/Tianjic/all_cases/core_array/ann_sparse
LVDS_EXTRA_TESTS=1 sh controller/scripts/run_chip_sim.sh \
  /data_8T_2/Tianjic/all_cases/die_extern/resnet9_lvds
sh controller/scripts/run_chip_sim_batch.sh
```

单用例入口接受用例目录；批量入口的附加参数是测例根目录下的相对名称。
批量入口把两个运行脚本复制到本批的日志目录，所有用例使用这份副本。构建配置仍从启动批跑的仓库读取。
默认作业名自动生成，手工指定 `JOBNAME` 时，并发任务须使用不同名称。
`TJ_REPO` 选择芯片环境；Controller 和配套构建配置默认随脚本工作区，
`TJ_CTRL_HOME` 可指定同版 Controller 副本。模块回归的芯片源码位置则由
`YAWING_DESIGN`、`TIANJIC_A_DESIGN` 指定，未设置时使用当前仓库目录。

单 die 芯片联仿默认通过仿真后门装载核内存，随后通过 Controller 配置、启动和收发数据。
对于带有 `lvds_config.txt` 且每核模板从 `@0` 起连续排列 1～4 行的用例，设置 `BOOTSPI=1` 后，
测例在 `B` 标记处启动 BOOT 引擎，经 SPI 写入模板，并逐核回读 SRAM 与模板比对。
该测例为每个接收环配置1024条记录的容量。配方执行结束后，测例收集数据并推进 RPTR，
归还已消费的环空间。数据包与控制包都占环空间，结果数量只统计数据包。
配方执行期间的并发消费尚未接入。

## 相关文档

随源码提供：

- [寄存器手册](doc/tj_ctrl_regmap.md)：寄存器地址、位域和操作说明。
- [SEND 取数 FIFO 综合记录](doc/tj_send_fetch_synth_note.md)：FIFO 结构及工具报告中的存储器映射。
- [镜像工具](sw/README.md)：导出文件、比较模式、地址段和初始化命令清单。
- 各测试目录的 README：运行方式和具体覆盖范围，入口见上表。

本机参考资料另行维护，不随源码提交：

- [需求说明](../docs/controller/tianjic_controller_req.md)
- [南向协议分析](../docs/controller/southside_protocol_findings.md)
- [开发约定](../docs/controller/dev_guide.md)
- [项目进度](../docs/controller/worklog.md)
