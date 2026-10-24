// =============================================================================
//  filelist.f  -  compile order for the split UVM testbench (Synopsys VCS)
//  Author : Maharshi Oza (mmoza@ncsu.edu)
//
//  vcs -f filelist.f
//  ./simv +UVM_TESTNAME=cache_smoke_test
// =============================================================================
-sverilog
-ntb_opts uvm-1.2
-timescale=1ns/1ps
+incdir+tb

// ---- design (unchanged) ----
design/rtl/cache_pkg.sv
design/rtl/sram_sp.sv
design/rtl/cache_tag_cmp.sv
design/rtl/cache_lru.sv
design/rtl/cache_lfu.sv
design/rtl/cache_repl.sv
design/rtl/cache_dirty.sv
design/rtl/cache_ctrl.sv
design/sva/cache_ctrl_sva.sv

// ---- testbench ----
tb/common/cache_tb_defs.sv
tb/top/cache_if.sv
tb/pkg/cache_tb_pkg.sv
tb/top/tb_top.sv
