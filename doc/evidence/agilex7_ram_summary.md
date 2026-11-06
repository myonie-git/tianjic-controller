# agilex7 —— mem_q 落块与资源(原始报告摘录)

来源为 2026-08-12 的 `tjctrl.fit.place.rpt`，摘自 `Fitter Resource Usage Summary` 和 `Fitter RAM Summary`。

```
; Logic utilization (ALMs needed / total ALMs on device)      ; 7,255 / 1,356,160    ; < 1 % ;
; M20K blocks                                                 ; 3 / 17,136           ; < 1 % ;
; Total MLAB memory bits                                      ; 0                    ;       ;
; Total block memory bits                                     ; 27,136 / 350,945,280 ; < 1 % ;
; Name                                                                          ; Type ; Mode             ; Clock Mode   ; Port A Depth ; Port A Width ; Port B Depth ; Port B Width ; Port A Input Registers ; Port A Output Registers ; Port B Input Registers ; Port B Output Registers ; Logical Size ; Implementation Port A Depth ; Implementation Port A Width ; Implementation Port B Depth ; Implementation Port B Width ; Implementation Bits ; M20K blocks ; MLABs ; MIF  ; Location                                                ; Mixed Port RDW Mode ; Port A RDW Mode ; Port B RDW Mode ; ECC Mode ; ECC Pipeline Registers ; Fits in MLABs     ;
; u_send|u_fetch|mem_q_rtl_0|auto_generated|altera_syncram_impl1|ALTERA_SYNCRAM ; M20K ; Simple Dual Port ; Single Clock ; 256          ; 106          ; 256          ; 106          ; yes                    ; no                      ; yes                    ; no                      ; 27136        ; 256                         ; 106                         ; 256                         ; 106                         ; 27136               ; 3           ; 0     ; None ; M20K_X291_Y172_N0, M20K_X278_Y174_N0, M20K_X291_Y174_N0 ; Don't care          ; New data        ; New data        ; Off      ; No                     ; No - Size Too Big ;
```
