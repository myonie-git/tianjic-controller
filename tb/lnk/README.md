# LVDS链路与配置链测试

| 测例 | 覆盖 | 检查数 |
|---|---|---|
| `tb_tj_lnk.sv` | 两实例配置、空闲即发令、4个逻辑口双向收发、随机反压、错误状态 | 354 |
| `tb_tj_lnk_tlast` / `tj_lnk_tlast_cfg` | 外部TLAST分组、四端口竞争、空隙/反压、原SOC收发互通 | 350 |
| `tb_tj_cfgchain.sv` | CC与CSR集成、两种轮询相位、KIND 2/3、超时恢复、忙时GO、写拍保持 | 2280 |

从仓库根目录运行，需要VCS：

```sh
sh controller/tb/lnk/run_lnk_tb.sh
```

默认创建独立临时构建目录并打印路径。默认模式和新增 tlast 档各运行0x211F/0x210F两种配置，各使用种子1、31、166；配置链测试运行100/250MHz两档时钟。

也可指定构建目录和种子：

```sh
lnk_build_dir=$(mktemp -d)
sh controller/tb/lnk/run_lnk_tb.sh "$lnk_build_dir" 1 7
```

使用 Questa 可通过同一 shell 入口选择，也可直接运行 Python（支持 Python 3.6+）：

```sh
LNK_SIMULATOR=questa sh controller/tb/lnk/run_lnk_tb.sh
python3 controller/tb/lnk/run_lnk_questa.py
```

`QUESTA` 指定 Questa 可执行文件目录，或将 `vsim` 加入 PATH。Python 入口也接受构建目录和种子，
以及相同的 `LNK_TESTS`、`LNK_CASES`、`CFGCHAIN_CASES`。仅运行 cfgchain 时无需技术模型。
Questa Starter 的推荐实例容量提示14408/16154被单独屏蔽，功能错误仍判失败。

源码和工具库位置：

- `TJ_CTRL_HOME`：由入口定位本次 controller，生产 LVDS 通过 `flist/tj_lvds.f` 编译该目录的副本。
- `YAWING_DESIGN`：默认使用本仓库的`soc/design`，提供 macro/PAD/标准单元仿真模型，并为 tlast 档提供原 SOC LVDS/core_cfg RTL。仅导出Controller时须另行提供这些依赖。
- `DW_SIM_DIR`：包含`DW_ecc.v`的目录。VCS 入口未设置时按PATH中的`dc_shell`安装位置查找；Questa 入口需显式设置。

```sh
YAWING_DESIGN=/path/to/soc/design DW_SIM_DIR=/path/to/dw/sim_ver \
  sh controller/tb/lnk/run_lnk_tb.sh
```

编译日志和每个用例的运行日志分别保存在构建目录。脚本同时检查仿真进程退出码和非零检查数的PASS结果，任一失败即停止并返回非零。

默认链路测例通过公开端口驱动和观察，不使用内部force或层次探针；每个方向的4个逻辑口各发40包，共320包。配置链测例连接真实Controller CSR、controller 副本中的配置链接收逻辑和APB寄存器模型。

配置链共用时钟，链路两端的数据时钟和位时钟独立。`+SLOW_ACLK`保留为单独运行仿真程序时的负向时钟诊断选项，不属于正常回归。这里的结果不替代FPGA PHY或板级验证。


## 选择性运行

不设置选择变量时，仍运行原有两种链路配置、全部种子及两个配置链时钟档。

~~~sh
LNK_TESTS=lnk LNK_CASES=T3 sh controller/tb/lnk/run_lnk_tb.sh /tmp/lnk_t3 1
LNK_TESTS=cfgchain CFGCHAIN_CASES=P3 sh controller/tb/lnk/run_lnk_tb.sh /tmp/cc_p3
~~~

LNK_TESTS可用lnk、tlast、cfgchain，空格分隔。LNK_CASES支持T1～T4，
CFGCHAIN_CASES支持P1～P4，以逗号分隔。T3会准备链路配置；T4会准备配置及流量，
日志以CASE SETUP注明。直接运行仿真程序时使用+TJ_CASES，手动编译TB需添加
+incdir+<controller路径>/tb/common。

## 外部TLAST与原芯片互通

`tlast` 档复用 `tb_tj_lnk.sv` 的时钟、配置链和错误检查，A端通过独立的
`tj_lnk_plug_tlast.sv` 开启 `USE_EXTERNAL_TLAST`。共享的 `tj_lnk_plugs.sv` 不修改，
芯片联仿继续使用原接口。`lvds_soc_files.f` 把原 SOC LVDS/core_cfg RTL 编译到
`tj_soc_lvds` 库，`tj_lnk_tlast_cfg.sv` 的嵌套配置把B端整个LVDS子树绑定到该库；
平台技术模型仍来自 `work`。因此B端接收逻辑、包定义和发送逻辑均来自原SOC，
不是另一份controller副本。仿真库和配置只用于测试。

每个逻辑端口发送1、2、3、4、7、17条记录的六个AXIS分组，共136条记录、24组。
四个端口并发争用三条物理链路，组内插入空隙（含末条记录前），接收端先暂停再随机反压，
另有16条原SOC发送的反向记录。检查每组的数据、记录数和顺序、反向记录恰好出现一次，
以及两端错误中断/ERR_ST。不同分组可能经不同物理链路而乱序；不要求跨组有序。

专用适配器另以只读层次引用观察 `u_axis_mimo_tx` 的AXIS输出端口：
逐条比对实际握手的数据和TLAST，检查同组固定在同一物理链路，累计分组闭合数。
这不会驱动或force内部信号；把TLAST错误地恒置1也不能通过。
覆盖计数必须证明发送/接收反压、并发竞争和组内间隙确实发生。
本档不接受 `LNK_CASES` 裁剪，以免只跑配置检查便误报TLAST通过。

```sh
LNK_SIMULATOR=questa LNK_TESTS=tlast sh controller/tb/lnk/run_lnk_tb.sh /tmp/tj_tlast 1 31 166
# VCS使用同一入口和独立库配置：
LNK_TESTS=tlast sh controller/tb/lnk/run_lnk_tb.sh /tmp/tj_tlast_vcs 1 31 166
# 总回归选择lnk时包含默认模式和tlast；也可单独选择tlast：
REGRESS_TESTS=tlast LNK_SIMULATOR=questa sh controller/scripts/run_regress.sh
```

该测试验证AXIS分组语义及原SOC RTL互通，不宣称AXIS分组边界与物理帧一一对应，
也不替代Agilex PHY实现后的时序签核和上板验证。
