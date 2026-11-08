# Quartus 块级构建结果

日期：2026-11-08。RTL基线：devs-0926的65b24eaa。工具：Quartus Prime Pro 24.3.0 Build 212。
顶层tj_ctrl_top使用虚拟引脚，pclk=250MHz、maxi_clk=50MHz。

| 器件 | ALM | 寄存器 | Setup余量 pclk / maxi_clk（ns） | Hold余量 pclk / maxi_clk（ns） |
|---|---:|---:|---:|---:|
| AGIB041R29D1E2VB | 7,341 | 10,627 | +0.699 / +13.192 | +0.012 / +0.000 |
| 10CX220YF672E5G | 5,763 | 10,162 | +0.232 / +10.667 | +0.016 / +0.016 |

两工程综合、布局布线、STA及脚本路径审计均完成，时序摘要没有负余量。
SEND FIFO均映射为3个M20K、27,136位。Agilex结果复用同日已完成的构建，输入与本版仅有注释差异；
Cyclone按本版输入重新构建，布线采用脚本中已有的BOOT地址及RECV RPTR保持余量，最终STA使用正常约束。

| 器件 | 综合 | 布局布线 | 时序 | RAM实例 |
|---|---|---|---|---|
| Agilex 7 | [摘要](agilex7.syn.summary) | [摘要](agilex7.fit.summary) | [摘要](agilex7.sta.summary) | [摘录](agilex7_ram_summary.md) |
| Cyclone 10 GX | [摘要](cyclone10gx.syn.summary) | [摘要](cyclone10gx.fit.summary) | [摘要](cyclone10gx.sta.summary) | [摘录](cyclone10gx_ram_summary.md) |

运行方法见[SEND FIFO综合记录](../tj_send_fetch_synth_note.md)。
北向旁路不在tj_ctrl_top中例化，其独立开启配置见[旁路SPI OOC结果](bypass_ooc_agilex7.md)。

本页结论限于该时钟和器件下已约束的块内路径；系统APB/AXI/LVDS接口及板级SPI/CPLD时序须在实际集成工程检查。
