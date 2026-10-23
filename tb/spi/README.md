# SPI 测例

- `tb_tj_spi.sv`：SPI 引擎和子系统回归，与芯片 spi2ahb 对接，共520项检查。每笔门铃事务独立检查完成/错误计数；T12检查未取读数时的命令接收，T13检查die31门铃/窗口交叉读写，T14检查组0/7的独立分频和超时配置。
- `tb_tj_spi_status.sv`：门铃状态回归，pclk=100MHz。P1 检查执行及完成/超时事件周期的 GO 忽略行为；P2 通过 APB 检查 WR1、RD1、超时和 KIND=2 的状态一致性，每项覆盖两种轮询相位。
- `tb_tj_spi_arb2.sv`：仲裁器回归。P1检查优先级与授权保持；P2覆盖A/B在done或err同拍续接读写任务，以及无新命令时释放后另一方接管；P3检查READY为0时不能将请求误当作已接收。
- `tb_tj_spi_timeout.sv`：超时恢复回归，45项检查。P1单写/单读中止；P2块写断供；P3块读请求后的排空阶段；P4块读取数阶段。检查CS高间隔、错误事件、BUSY/READY及后续读写；芯片AHB每拍固定4个等待。

从仓库根目录运行状态回归（需要 VCS 环境）：

```sh
spi_ctrl_dir=$(realpath controller)
spi_build_dir=$(mktemp -d)
cd "$spi_build_dir"
vlogan -full64 -sverilog -nc +define+TJ_ASSERT_ON -timescale=1ns/1ps \
  "$spi_ctrl_dir/rtl/pkg/tj_ctrl_pkg.sv" \
  "$spi_ctrl_dir/rtl/csr/tj_ctrl_csr_pkg.sv" \
  "$spi_ctrl_dir/rtl/csr/tj_ctrl_csr.sv" \
  "$spi_ctrl_dir/rtl/spi/tj_spi_engine.sv" \
  "$spi_ctrl_dir/rtl/spi/tj_spi_subsys.sv" \
  "$spi_ctrl_dir/tb/spi/tb_tj_spi_status.sv"
vcs -full64 -nc tb_tj_spi_status -o simv
./simv -nc
```

通过时输出 `SPI STATUS TB PASS`。状态测例不依赖芯片模型，MISO 固定为 0；SPI 协议与读写数据仍由原有测例检查。

运行仲裁器回归时，将上述TB文件替换为`tb_tj_spi_arb2.sv`，展开顶层改为`tb_tj_spi_arb2`；通过时输出`SPI ARB2 TB PASS`。该测例通过公开端口模拟引擎响应，不依赖芯片模型。

运行超时恢复回归（需要芯片 `spi2ahb.v`）：

```sh
spi_repo_dir=$(pwd)
spi_timeout_build=$(mktemp -d)
cd "$spi_timeout_build"
vlogan -full64 -sverilog -nc +define+TJ_ASSERT_ON -timescale=1ns/1ps \
  "$spi_repo_dir/controller/rtl/pkg/tj_ctrl_pkg.sv" \
  "$spi_repo_dir/controller/rtl/spi/tj_spi_engine.sv" \
  "$spi_repo_dir/soc/design/rtl/mcu_subsys/spi/spi2ahb.v" \
  "$spi_repo_dir/controller/tb/spi/tb_tj_spi_timeout.sv"
vcs -full64 -nc tb_tj_spi_timeout -o simv
./simv -nc
./simv -nc +TJ_PCLK_HP=2.0 +SPI_DIV=4
```

以上命令从仓库根目录开始执行。两档pclk分别为100/250MHz，芯片hclk固定100MHz，SCLK均为25MHz；通过时输出 `SPI TIMEOUT TB PASS (45 checks)`。
该回归检查超时后的恢复，不保证被截断写操作没有副作用。

运行完整SPI回归时，在上面的状态回归编译列表中加入 `soc/design/rtl/mcu_subsys/spi/spi2ahb.v` 的绝对路径，并将TB替换为 `tb_tj_spi.sv`、展开顶层改为 `tb_tj_spi`。通过时输出 `SPI TB PASS (520 checks)`。
