# agilex7：SEND FIFO RAM实现

日期：2026-11-08。RTL基线65b24eaa，器件AGIB041R29D1E2VB，pclk/maxi_clk=250/50MHz。
来源为本次tjctrl.fit.place.rpt的Fitter RAM Summary；顶层资源见[布局布线摘要](agilex7.fit.summary)。

| 项目 | 结果 |
|---|---|
| 实例 | u_send/u_fetch/mem_q_rtl_0 |
| 类型 | M20K，简单双口、单时钟 |
| 深度 × 实现宽度 | 256 × 106位 |
| 实现位数 | 27,136 |
| M20K数量 | 3 |

原始实例行：

```text
; u_send|u_fetch|mem_q_rtl_0|auto_generated|altera_syncram_impl1|ALTERA_SYNCRAM ; M20K ; Simple Dual Port ; Single Clock ; 256          ; 106          ; 256          ; 106          ; yes                    ; no                      ; yes                    ; no                      ; 27136        ; 256                         ; 106                         ; 256                         ; 106                         ; 27136               ; 3           ; 0     ; None ; M20K_X178_Y173_N0, M20K_X178_Y176_N0, M20K_X178_Y178_N0 ; Don't care          ; New data        ; New data        ; Off      ; No                     ; No - Size Too Big ;
```

源代码的记录宽度为128位，106位是该顶层综合后保留的宽度。
