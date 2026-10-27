# SEND回归

运行需要VCS及Python 3.6以上，Python脚本仅使用标准库。入口根据自身位置查找源码，可在任意工作目录执行，不依赖本机文档仓库或旧构建目录。

```sh
python3 controller/tb/send/run_send_tb.py --out-dir /tmp/send_regression
```

输出目录应为新目录或空目录；不传`--out-dir`时自动建立临时目录。默认运行以下六组测试：

| 选项 | 测试内容 |
|---|---|
| system | CSR→SEND→AXI读后端→LVDS公开端口；P1～P9及4 KiB切分、空表、挂起AR中止和LAST后排空 |
| events | 连续错误表、恢复、忙时GO、配置后立即启动、启动中止及DONE/ERR/AXI事件逐笔计数 |
| count | SENT在31→32、63→64、127→128、255→256边界的整字一致性和新任务清零 |
| cdc | 复位后首事件、无事件、稳定后脉冲、事件合并及共同复位 |
| engine | 同口每拍替换、载荷/IRQ对应、反压、中止同拍握手及多口排空 |
| axi | 128位读适配和RRESP映射；256/512位配置必须在展开期被拒绝 |

`system/events/count/cdc`默认运行普通模型三档及抖动模型三档×四种子：

| 档位 | TJ_PCLK_HP | TJ_MAXI_HP | pclk / maxi_clk |
|---|---:|---:|---|
| default | 5.0 | 1.2 | 100 / 416.7 MHz |
| delivery | 2.0 | 10.0 | 250 / 50 MHz |
| boundary | 50.0 | 5.0 | 10 / 100 MHz |

半周期单位为ns；普通模型用所选第一个种子，抖动模型使用全部种子，默认1、2、3、4。engine为单时钟周期行为测试，axi为接口映射及展开检查，各独立执行一次，不将其重复计作三档CDC覆盖。

```sh
python3 controller/tb/send/run_send_tb.py --out-dir /tmp/send_system \
  --tests system events --model jitter --seeds 1 31
```

抖动模型对同步器首级随机增加一拍采样延迟，不代表晶体管级亚稳态仿真。系统TB的实际时钟、等待和超时随参数变化；记录标志位LAST=0x01、FENCE=0x02、IRQ=0x04及三通道预期值独立于DUT常量。

## 系统测试装配

`tb_tj_send.sv`通过测试专用的`tj_send_verification_top`连接当前真实CSR、SEND子系统和AXI读后端，地址宽度为48位；只观察公开APB、AXI和LVDS端口。无需尚未引入的生产`tj_ctrl_top`，也不代表完整Controller、die或板级集成。

| 相位 | 检查内容 |
|---|---|
| P1～P2 | 混合通道发送及二进制记录重放；P1单独检查完成IRQ |
| P3～P7 | FENCE、LAST、中途记录IRQ、禁用/非法通道及重映射 |
| P8～P9 | 读错误恢复；中止保持VALID/数据、逐口排空、SENT/IRQ及重启 |
| P10 | 4+64+64+9条的4 KiB切分、多笔在途及空表不发请求 |
| P11 | 中止时保留挂起AR，接受后排空64拍响应且不发送包 |
| P12 | 首突发第5条LAST，只输出5包并排空后续在途读数 |

回归入口生成300条合成二进制记录用于P2，不依赖D1导出器或真实AI模型文件。需要自有镜像时可在构建完成后向系统仿真程序传入`+IMG=<path>`。

系统和事件测试在写完配置后立即写GO。SEND硬件在冻结配置前多等待一个maxi_clk周期，准备阶段计入BUSY；软中止可取消尚未启动的任务，旧事件在实际启动时清理。软件仍须保持配置到任务结束。DONE后允许SENT快照更新，再有界轮询已知的预期计数；连续两次读值相同不作为终值证明。事件测试还交替执行错误任务和短间隔GO/SRST，检查取消启动或在途排空后没有旧错误重报；GO/SRST间隔保持至少三个maxi_clk周期。

## 结果与重跑

输出目录保存每次编译/展开/仿真的日志、输入指纹`inputs.json`和命令结果`results.json`。普通测试必须退出成功、没有FAIL/FATAL/ERROR/TIMEOUT并打印非零检查数的完整PASS行；AXI非法位宽只接受指定参数守卫错误。任一步失败，入口返回非零状态；结束前再次核对源码指纹。

已有的计数专用入口仍可使用：

```sh
sh controller/tb/send/run_send_count_tb.sh /tmp/send_count_plain
CDC_JITTER=1 sh controller/tb/send/run_send_count_tb.sh /tmp/send_count_jitter
```

# 快照集成约束

SENT在maxi_clk域取完整副本，经过请求/确认握手在pclk域更新。副本在接收期间保持，实际计数器继续运行。两侧复位应同时断言；源域清零或计数变化不会立即出现在CSR。DONE与最终SENT刷新相互独立，连续两次读到相同数值不足以证明已取得最终值。

快照数据必须在目的域采样前到达。当前约束将`snap_q`到`q`的数据路径限制为一个pclk周期，并只对握手同步器首级设置false path。Quartus片段还按CE型跨域规则限制总线偏斜及网络延迟。集成时使用实际pclk周期，例如：

```tcl
set TJ_SEND_PCLK_PERIOD 4.0
source controller/scripts/tj_send_snapshot_quartus.sdc
```

三个约束文件分别用于Quartus TimeQuest、Synopsys SDC和Vivado：`tj_send_snapshot_quartus.sdc`、`tj_send_snapshot.sdc`、`tj_send_snapshot_vivado.xdc`。它们仅覆盖SEND计数快照；其余跨域路径需由所在系统约束。

实例名匹配`u_sent_syn`。每个实例应匹配32个快照寄存器、32个目的寄存器及请求/确认首级各1个寄存器；重命名或综合改名后须复核。禁止用全局异步时钟组或更宽的false path覆盖快照数据的max_delay约束。
