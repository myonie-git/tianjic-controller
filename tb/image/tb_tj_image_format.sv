// File        : tb_tj_image_format.sv
// Module      : tb_tj_image_format
// Description : Check default SEND records and sorted core memory data against source files.
//               Address segments are checked by test_tj_image.py.
// Usage       : +CFG=<lvds_config.txt> +IMG=<send_image.bin>
//               Optional pair: +MEMCFG=<mem_config.txt> +BOOT=<boot_prim.bin>
module tb_tj_image_format;
  int unsigned errs = 0, checks = 0;

  task automatic chk(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errs++;
      $display("IMAGE FORMAT TB FAIL: %s", msg);
    end
  endtask

  function automatic logic [127:0] read16le(input int fd, output int got);
    byte unsigned b;
    logic [127:0] v = '0;
    got = 0;
    for (int i = 0; i < 16; i++) begin
      if ($fread(b, fd) != 1) return v;
      v |= 128'(b) << (8 * i);
      got++;
    end
    return v;
  endfunction

  initial begin
    string cfg_p, img_p, memcfg_p, boot_p, line, token;
    int fcfg, fimg, fmc, fbt, code, got, n_rec, n_end, n_last, line_no;
    int lvds, dy, dx, endp, endn, addr, mode, n_lines;
    int unsigned maddr;
    bit have_memcfg, have_boot;
    logic [63:0] body;
    logic [95:0] ref_pkt;
    logic [127:0] raw;
    logic [7:0] flags, expected_flags;
    logic [255:0] mline;
    logic [255:0] mem_words[int unsigned];

    if (!$value$plusargs("CFG=%s", cfg_p) || !$value$plusargs("IMG=%s", img_p))
      $fatal(1, "need +CFG= +IMG=");
    have_memcfg = $value$plusargs("MEMCFG=%s", memcfg_p);
    have_boot = $value$plusargs("BOOT=%s", boot_p);
    if (have_memcfg != have_boot)
      $fatal(1, "MEMCFG and BOOT must be supplied together");

    // Reconstruct NoC packets from source rows; use fixed record bit positions.
    fcfg = $fopen(cfg_p, "r");
    fimg = $fopen(img_p, "rb");
    if (fcfg == 0 || fimg == 0) $fatal(1, "cannot open cfg/img");
    n_rec = 0;
    n_end = 0;
    n_last = 0;
    line_no = 0;
    while ($fgets(line, fcfg)) begin
      line_no++;
      if ($sscanf(line, "%s", token) != 1) continue;
      code = $sscanf(line, "%d,%d,%d,%d,%d,%d,%d,%h %s",
                     lvds, dy, dx, endp, endn, addr, mode, body, token);
      if (code != 8 || mode != 1)
        $fatal(1, "%s:%0d: invalid LVDS configuration row", cfg_p, line_no);
      raw = read16le(fimg, got);
      if (got != 16) $fatal(1, "SEND record %0d is truncated", n_rec);
      flags = raw[111:104];
      if (endp) begin
        ref_pkt = {49'b0, endn[14:0], 14'b0, dx[5:0], dy[5:0], lvds[1:0], 4'b0100};
        expected_flags = 8'h02;
        n_end++;
      end else begin
        ref_pkt = {body, addr[13:0], dx[5:0], dy[5:0], lvds[1:0], 4'b0010};
        expected_flags = 8'h00;
      end
      // Default export: FENCE on END, IRQ and reserved bits clear; LAST checked below.
      chk((flags & 8'hFE) === expected_flags,
          $sformatf("record %0d non-LAST flags: %02h", n_rec, flags));
      chk(raw[95:0] === ref_pkt,
          $sformatf("record %0d packet: %h vs %h", n_rec, raw[95:0], ref_pkt));
      chk(raw[103:96] === 8'h0 && raw[127:112] === 16'h0,
          $sformatf("record %0d channel/tag must be zero", n_rec));
      if (flags[0]) n_last++;
      n_rec++;
    end
    if (n_rec == 0) $fatal(1, "CFG contains no SEND records");
    chk(flags[0] === 1'b1, "Final record has LAST set");
    chk(n_last == 1, $sformatf("Expected one LAST flag, got %0d", n_last));
    raw = read16le(fimg, got);
    chk(got == 0, "No extra bytes after the final SEND record");
    $fclose(fcfg);
    $fclose(fimg);
    $display("Checked %0d SEND records, including %0d END packets", n_rec, n_end);

    // Core rows are exported in ascending address order; the last value wins per address.
    if (have_memcfg) begin
      fmc = $fopen(memcfg_p, "r");
      fbt = $fopen(boot_p, "rb");
      if (fmc == 0 || fbt == 0) $fatal(1, "cannot open memcfg/boot");
      line_no = 0;
      while ($fgets(line, fmc)) begin
        line_no++;
        if ($sscanf(line, "%s", token) != 1) continue;
        code = $sscanf(line, " @%h %h %s", maddr, mline, token);
        if (code != 2)
          $fatal(1, "%s:%0d: invalid memory row", memcfg_p, line_no);
        mem_words[maddr] = mline;
      end
      $fclose(fmc);
      if (mem_words.num() == 0) $fatal(1, "MEMCFG contains no memory rows");
      n_lines = 0;
      foreach (mem_words[a]) begin
        for (int i = 0; i < 4; i++) begin
          raw = '0;
          for (int j = 0; j < 8; j++) begin
            byte unsigned b;
            if ($fread(b, fbt) != 1) $fatal(1, "Core memory image is truncated");
            raw |= 128'(b) << (8 * j);
          end
          chk(raw[63:0] === mem_words[a][64*i +: 64],
              $sformatf("memory @%h word %0d: %h vs %h", a, i,
                        raw[63:0], mem_words[a][64*i +: 64]));
        end
        n_lines++;
      end
      begin
        byte unsigned b;
        chk($fread(b, fbt) == 0, "No extra bytes after the core memory image");
      end
      $fclose(fbt);
      $display("Checked %0d core memory rows (256 bits each)", n_lines);
    end

    if (errs == 0 && checks > 0)
      $display("IMAGE FORMAT TB PASS (%0d checks)", checks);
    else
      $fatal(1, "IMAGE FORMAT TB FAIL (%0d/%0d)", errs, checks);
    $finish;
  end
endmodule
