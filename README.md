# Tianjic Controller

面向两颗 Yawing04 芯片、共32个 die 的 FPGA 控制器，提供 Host 寄存器访问、
芯片 SPI 控制以及 DDR 与 LVDS 之间的数据收发。
当前顶层集成 CSR、SPI、SEND、RECV、配置链主机、时间戳和中断汇总。

## 模块与目录

| 目录 | 内容 |
|---|---|
| `csr/` | 寄存器 YAML 定义、生成器和生成入口 |
| `rtl/pkg/` | 常量、记录格式和数据类型 |
| `rtl/csr/` | 生成的寄存器 RTL |
| `rtl/top/` | 顶层连接、APB 分路、时间戳和中断汇总 |
| `rtl/spi/` | SPI 引擎、门铃、仲裁和 SPIWIN 窗口 |
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

该入口运行生成物一致性、CSR、SPI、顶层展开、APB冒烟、lint、镜像工具与格式、
初始化重放、LVDS链路、SEND和RECV检查。`SEEDS`、`EXTRA_SEEDS` 控制 SPI 种子，
`IMAGE_CASE` 选择镜像用例；`SKIP_APB_SMOKE`、`SKIP_SG`、`SKIP_LNK` 可跳过对应项目。
工具或用例不可用时，部分项目也会跳过，运行结果须结合日志中的跳过项查看。

镜像阶段先运行 Python CLI 测试，检查地址段、比较器和各核 CONFIG，再用 SV 核对记录及内存数据。
初始化重放测例执行 W/P 命令，F 标记跳过并计数，idle 由存储模型预置。
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
默认作业名自动生成，手工指定 `JOBNAME` 时，并发任务须使用不同名称。
`TJ_REPO` 选择芯片环境；Controller 和配套构建配置默认随脚本工作区，
`TJ_CTRL_HOME` 可指定同版 Controller 副本。模块回归的芯片源码位置则由
`YAWING_DESIGN`、`TIANJIC_A_DESIGN` 指定，未设置时使用当前仓库目录。

联合测例使用单 die 环境，核程序通过原生仿真后门装入，随后通过 Controller 配置、启动和收发数据。
该测例为每个接收环配置1024条记录的容量，当前不推进 RPTR；满环后仍有包等待接收时明确报错。
数据包与控制包都占环空间，结果数量只统计数据包。更大输出的联合测试需要加入持续消费。

## 相关文档

随源码提供：

- [寄存器手册](doc/tj_ctrl_regmap.md)：寄存器地址、位域和操作说明。
- [镜像工具](sw/README.md)：导出文件、比较模式、地址段和初始化命令清单。
- 各测试目录的 README：运行方式和具体覆盖范围，入口见上表。

本机参考资料另行维护，不随源码提交：

- [需求说明](../docs/controller/tianjic_controller_req.md)
- [南向协议分析](../docs/controller/southside_protocol_findings.md)
- [开发约定](../docs/controller/dev_guide.md)
- [项目进度](../docs/controller/worklog.md)
