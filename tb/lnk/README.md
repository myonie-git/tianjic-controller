# LVDS链路测试

| 测例 | 覆盖 | 检查数 |
|---|---|---|
| `tb_tj_lnk.sv` | 两实例配置、4个逻辑口双向收发、随机反压、错误状态 | 348 |

从仓库根目录运行，需要VCS：

```sh
sh controller/tb/lnk/run_lnk_tb.sh
```

默认创建独立临时构建目录并打印路径。链路测试运行0x211F/0x210F两种配置，各使用种子1、31、166。

也可指定构建目录和种子：

```sh
lnk_build_dir=$(mktemp -d)
sh controller/tb/lnk/run_lnk_tb.sh "$lnk_build_dir" 1 7
```

源码和工具库位置：

- `YAWING_DESIGN`：默认使用本仓库的`soc/design`。在仅导出Controller的副本中运行时，指向对应版本的芯片设计目录。
- `DW_SIM_DIR`：包含`DW_ecc.v`的目录。未设置时按PATH中的`dc_shell`安装位置查找。

```sh
YAWING_DESIGN=/path/to/soc/design DW_SIM_DIR=/path/to/dw/sim_ver \
  sh controller/tb/lnk/run_lnk_tb.sh
```

编译日志和每个用例的运行日志分别保存在构建目录。脚本同时检查仿真进程退出码和非零检查数的PASS结果，任一失败即停止并返回非零。

链路测例通过公开端口驱动和观察，不使用内部force或层次探针；每个方向的4个逻辑口各发40包，共320包。

配置链共用时钟，链路两端的数据时钟和位时钟独立。`+SLOW_ACLK`保留为单独运行仿真程序时的负向时钟诊断选项，不属于正常回归。这里的结果不替代FPGA PHY或板级验证。
