# 旁路SPI OOC构建结果

日期：2026-11-08。RTL基线：devs-0926的65b24eaa。
工具为Quartus Prime Pro 24.3，器件为Agilex 7 AGIB041R29D1E2VB，pclk=250MHz。

使用[tj_bypass_static_top](../../tb/bypass/tj_bypass_static_top.sv)封装，
显式设置ENABLE_BYPASS_SPI=1。输入包括该封装、tj_bypass_spi.sv和tj_cdc.sv，端口均为虚拟引脚。
外部SCLK、MOSI和SS_N按异步输入处理。

| 项目 | 结果 |
|---|---|
| 综合、布局布线、STA | 均成功完成 |
| ALM | 300 |
| 专用寄存器 | 313 |
| RAM块 | 0 |
| Setup余量 | +2.546ns |
| Hold余量 | +0.092ns |

结果对应开启的旁路功能，当前顶层tj_ctrl_top不包含该模块。这里只验证已约束的内部路径，
不包含外部APB时序及SPI经过CPLD、PCB后的输入输出时序。
