# Controller 镜像工具

`tj_image.py` 将芯片用例导出为 SEND 记录、核内存镜像和初始化配方，
并提供结果比较及格式自检。需要 Python 3.6 或更高版本，无第三方依赖。

## 使用

从仓库根目录执行：

```sh
python3 controller/sw/tj_image.py export /path/to/case -o /path/to/output
python3 controller/sw/tj_image.py compare golden.txt received.txt
python3 controller/sw/tj_image.py compare golden.txt memory_dump.txt --mode memory
python3 controller/sw/tj_image.py selftest /path/to/case -o /path/to/selftest_output
```

`export --ch N` 设置 SEND 记录的通道号，默认为0；`--irq-last` 在最后一条记录上设置 IRQ 标志。

## 输出文件

| 文件 | 内容 |
|---|---|
| `send_image.bin` | 16字节小端 SEND 记录流；用例包含 `lvds_config.txt` 时生成 |
| `boot_prim_*.bin` | 各核内存镜像，每行32字节、小端编码 |
| `manifest.json` | 镜像文件、die及核坐标、行数和地址段 |
| `init_regs.txt` | 初始化配方：`W` 写寄存器，`P` 轮询寄存器，`D` 切换目标 die，`B` 标记 BOOT 装载位置，`F` 标记 SEND 投递位置 |

文件装载、寄存器访问和任务启动由 Host 软件或仿真环境执行。
多 die 用例通过 `D <die_id>` 切换目标 die，编号为 `die_row * 4 + die_col`，使用十进制。
后续 `W`、`P` 命令作用于选中的 die。

## 比较模式

默认 `packets` 模式比较完整包流的 `(地址, 数据)` 及出现次数，允许顺序不同。
缺包、多包、重复次数不符或数据错误均判为失败。

`--mode memory` 比较 golden 指定地址的最终值。同一地址出现多次时取最后一个值，
允许 dump 包含其它地址，适用于内存转储。

比较一致时退出码为0，不一致时为1。

## 核镜像布局与初始化

BOOT-SPI 每核只装载 1～4 行，每行 32 字节。源文件须按 `@0` 起连续排列，
符合时 `manifest.json` 将其标为 `boot_chain`。其它布局按 `full_image` 导出。
在芯片测例中选择 BOOT-SPI 装载这类镜像会报错。

核内存镜像按目标行地址升序排列。同一地址在源文件中出现多次时，使用最后一个值。
`manifest.json` 中每个核的 `segments` 描述地址段，每项为 `[起始行, 行数]`，例如：

```json
{"segments": [[0, 2], [256, 8]]}
```

镜像的前两行对应目标行0、1，后八行对应256～263。加载方按段顺序读取镜像数据，
写到相应目标行；地址间隙不占镜像文件空间。

各核 CONFIG 初值来自 `*_ctrl_config.txt` 的 `@80008`。初始化时将 bit0 先置1再清0，
其它位保留；文件或条目缺失时使用基值 `0x4`。

## 测试

```sh
python3 controller/tb/sw/test_tj_image.py --work /tmp/tj_image_tests -v
```

`--work` 必须指定新的目录，用于保存各次 CLI 调用的输入、输出和日志；
省略该参数时，测试使用临时目录并在结束后清理。`--tool` 可指定待测导出器路径。
测试覆盖包流比较、内存最终值、稀疏地址恢复、各核 CONFIG 和 SEND 记录编码。

内置 `selftest` 只检查 SEND 记录的导出与逆解析；用例没有 `lvds_config.txt` 时报告跳过。
