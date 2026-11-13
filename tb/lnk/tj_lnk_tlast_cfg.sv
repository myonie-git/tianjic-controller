// Compile the unmodified SOC LVDS tree in tj_soc_lvds, technology models in work.
// Nested configuration keeps the entire reference subtree in the SOC library.
config tj_lnk_soc_cfg;
  design tj_soc_lvds.lvds_subsys;
  default liblist tj_soc_lvds work;
endconfig

module tb_tj_lnk_tlast;
  tb_tj_lnk #(.EXTERNAL_TLAST_TEST(1'b1)) test();
endmodule

config tj_lnk_tlast_cfg;
  design work.tb_tj_lnk_tlast;
  default liblist work;
  instance tb_tj_lnk_tlast.test.u_b.u_lvds use work.tj_lnk_soc_cfg:config;
endconfig
