# 旁路 SPI OOC 历史记录

日期：2026-08-19。原始摘要随 `9c252bb` 加入，对应当时的 `tj_bypass_spi`，不是当前审核分支的验证结果。

使用 Quartus Prime Pro 24.3，器件为 Agilex 7 AGIB041，顶层为 `tj_bypass_spi`，所有端口设为虚拟引脚。
pclk 为 250 MHz（4 ns）；外部 SPI 输入至同步器的路径设为异步路径。
历史工程入口为 `/projects/yicheng/quartus-work/bypass_ooc/run.sh`。

| 项目 | 原报告结果 |
|---|---|
| 综合、布局布线、时序分析 | 均返回 0 |
| 推断锁存器 | 0 |
| 资源 | 292 ALM、299 个专用寄存器 |
| Setup | +2.596 ns，TNS 0，Slow vid2 100C |
| Hold | +0.095 ns，TNS 0，原摘要记录两个工作角 |
| 最小脉宽 | +1.731 ns |

以上为块级 out-of-context（OOC）结果，不包含板级 SPI/CPLD 时序。当前分支增加了旁路开关并修改了逻辑，需要按当前版本另行验证，不能直接沿用这些数值。
