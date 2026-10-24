//==============================================================================
//  File    : cache_cov.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Basic functional coverage: "did the tests actually exercise the
//            cases we care about?"  Printed at the end of the run.
//
//  INPUTS
//    write_cov_cpu   : CPU accesses, already tagged with outcome by the scoreboard
//    write_cov_mem   : memory transactions          (mem_mon)
//    write_cov_flush : flushes                      (flush_mon)
//
//  COVERGROUPS
//    cg_cpu   : load/store x hit/clean miss/dirty miss, word offset, byte-enable
//               patterns, error responses, CPU response backpressure
//    cg_mem   : refill/writeback x error, memory backpressure, latency ranges
//    cg_flush : with/without invalidate, error, flush racing a waiting request
//
//  WHY THIS IS DIFFERENT / OTHER WAY
//    - CPU items come from the SCOREBOARD (cov_ap), not straight from cpu_mon,
//      because only the scoreboard knows whether an access hit or missed.
//      OTHER WAY: let coverage work out hit/miss itself (duplicate logic).
//    - Three inputs -> `uvm_analysis_imp_decl, same as the scoreboard.
//      OTHER WAY: three uvm_subscriber classes, one per covergroup.
//
//  MERGEABLE COVERAGE FILE (v2.1)
//    SystemVerilog only reports coverage PERCENTAGES, which cannot be merged
//    across runs. So this class also counts every bin itself (same bins as the
//    covergroups) and writes cov_<test>[_<RUN_ID>].csv  =  group,coverpoint,
//    bin,hits. tools/merge_cov.py adds those files up into the coverage of
//    ALL runs together. (With VCS/Questa you would merge the tools' own
//    databases instead: urg / vcover merge.)
//
//  WATCH OUT:
//    - Keep the counted bins (count_*) in step with the covergroup bins if
//      you change either one.
//    - cp_wstrb bins assume 4 byte lanes (DATA_W = 32). Adjust if you change it.
//    - The DUT-internal covers (COV_* in cache_ctrl_sva.sv) still run and are
//      reported by the simulator separately.
//==============================================================================
`uvm_analysis_imp_decl(_cov_cpu)
`uvm_analysis_imp_decl(_cov_mem)
`uvm_analysis_imp_decl(_cov_flush)

class cache_cov extends uvm_component;

  `uvm_component_utils(cache_cov)

  uvm_analysis_imp_cov_cpu   #(cpu_item,   cache_cov) cpu_imp;
  uvm_analysis_imp_cov_mem   #(mem_item,   cache_cov) mem_imp;
  uvm_analysis_imp_cov_flush #(flush_item, cache_cov) flush_imp;

  // ---------------- CPU accesses -------------------------------------------
  covergroup cg_cpu with function sample(cpu_item t);
    option.per_instance = 1;
    cp_op      : coverpoint t.we      { bins load = {0}; bins store = {1}; }
    cp_outcome : coverpoint t.outcome { bins hit   = {OUT_HIT};
                                        bins clean = {OUT_CLEAN_MISS};
                                        bins dirty = {OUT_DIRTY_MISS}; }
    x_op_outcome : cross cp_op, cp_outcome;
    cp_woff    : coverpoint t.addr[OFF_W-1:BYTE_W];          // word inside the line
    cp_wstrb   : coverpoint t.wstrb iff (t.we) {
                   bins one_byte[] = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
                   bins half[]     = {4'b0011, 4'b1100};
                   bins word       = {4'b1111};
                   bins other      = default; }
    cp_err     : coverpoint t.err     { bins ok = {0}; bins error = {1}; }
    cp_rsp_bp  : coverpoint t.rsp_bp_cycles { bins none = {0}; bins some = {[1:3]}; bins many = {[4:$]}; }
  endgroup

  // ---------------- memory transactions -----------------------------------
  covergroup cg_mem with function sample(mem_item t);
    option.per_instance = 1;
    cp_kind   : coverpoint t.we  { bins refill = {0}; bins writeback = {1}; }
    cp_err    : coverpoint t.err { bins ok = {0}; bins error = {1}; }
    x_kind_err: cross cp_kind, cp_err;
    cp_req_bp : coverpoint t.req_bp_cycles { bins none = {0}; bins some = {[1:3]}; bins many = {[4:$]}; }
    cp_lat    : coverpoint t.lat_cycles    { bins fast = {[0:3]}; bins mid = {[4:10]}; bins slow = {[11:$]}; }
  endgroup

  // ---------------- flushes ------------------------------------------------
  covergroup cg_flush with function sample(flush_item t);
    option.per_instance = 1;
    cp_inv  : coverpoint t.inv  { bins clean_only = {0}; bins invalidate = {1}; }
    cp_err  : coverpoint t.err  { bins ok = {0}; bins error = {1}; }
    cp_race : coverpoint t.race { bins alone = {0}; bins cpu_waiting = {1}; }
  endgroup

  // ---------------- own bin counters (for the mergeable CSV) ---------------
  int unsigned bin_hits [string];     // "group,coverpoint,bin" -> hits
  string       bin_order[$];          // all bins, in a fixed order (0-hit bins too)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_cpu   = new();
    cg_mem   = new();
    cg_flush = new();
    declare_bins();
  endfunction

  function void add_bin(string key);
    bin_order.push_back(key);
    bin_hits[key] = 0;
  endfunction

  function void bump(string key);
    if (!bin_hits.exists(key)) begin
      `uvm_error("COV", {"unknown bin ", key})
    end
    else begin
      bin_hits[key]++;
    end
  endfunction

  function void declare_bins();
    string ops[2]  = '{"load", "store"};
    string outs[3] = '{"hit", "clean", "dirty"};
    string kinds[2]= '{"refill", "writeback"};
    string errs[2] = '{"ok", "error"};
    foreach (ops[i])   add_bin({"cg_cpu,cp_op,", ops[i]});
    foreach (outs[i])  add_bin({"cg_cpu,cp_outcome,", outs[i]});
    foreach (ops[i]) foreach (outs[j]) add_bin({"cg_cpu,x_op_outcome,", ops[i], "_", outs[j]});
    for (int w = 0; w < WPL; w++) add_bin($sformatf("cg_cpu,cp_woff,%0d", w));
    add_bin("cg_cpu,cp_wstrb,one_byte_0001"); add_bin("cg_cpu,cp_wstrb,one_byte_0010");
    add_bin("cg_cpu,cp_wstrb,one_byte_0100"); add_bin("cg_cpu,cp_wstrb,one_byte_1000");
    add_bin("cg_cpu,cp_wstrb,half_0011");     add_bin("cg_cpu,cp_wstrb,half_1100");
    add_bin("cg_cpu,cp_wstrb,word_1111");
    foreach (errs[i])  add_bin({"cg_cpu,cp_err,", errs[i]});
    add_bin("cg_cpu,cp_rsp_bp,none"); add_bin("cg_cpu,cp_rsp_bp,some"); add_bin("cg_cpu,cp_rsp_bp,many");
    foreach (kinds[i]) add_bin({"cg_mem,cp_kind,", kinds[i]});
    foreach (errs[i])  add_bin({"cg_mem,cp_err,", errs[i]});
    foreach (kinds[i]) foreach (errs[j]) add_bin({"cg_mem,x_kind_err,", kinds[i], "_", errs[j]});
    add_bin("cg_mem,cp_req_bp,none"); add_bin("cg_mem,cp_req_bp,some"); add_bin("cg_mem,cp_req_bp,many");
    add_bin("cg_mem,cp_lat,fast");    add_bin("cg_mem,cp_lat,mid");     add_bin("cg_mem,cp_lat,slow");
    add_bin("cg_flush,cp_inv,clean_only"); add_bin("cg_flush,cp_inv,invalidate");
    foreach (errs[i])  add_bin({"cg_flush,cp_err,", errs[i]});
    add_bin("cg_flush,cp_race,alone"); add_bin("cg_flush,cp_race,cpu_waiting");
  endfunction

  function string range3(int unsigned v, int unsigned lo_max, int unsigned mid_max,
                         string a, string b, string c);
    if (v <= lo_max)  return a;
    if (v <= mid_max) return b;
    return c;
  endfunction

  function void count_cpu(cpu_item t);
    string op, out;
    op  = t.we ? "store" : "load";
    out = (t.outcome == OUT_HIT) ? "hit" : (t.outcome == OUT_CLEAN_MISS) ? "clean" : "dirty";
    bump({"cg_cpu,cp_op,", op});
    bump({"cg_cpu,cp_outcome,", out});
    bump({"cg_cpu,x_op_outcome,", op, "_", out});
    bump($sformatf("cg_cpu,cp_woff,%0d", t.addr[OFF_W-1:BYTE_W]));
    if (t.we) begin
      case (t.wstrb)
        4'b0001, 4'b0010, 4'b0100, 4'b1000: bump($sformatf("cg_cpu,cp_wstrb,one_byte_%b", t.wstrb));
        4'b0011, 4'b1100:                   bump($sformatf("cg_cpu,cp_wstrb,half_%b", t.wstrb));
        4'b1111:                            bump("cg_cpu,cp_wstrb,word_1111");
        default: ;                          // "other" is not a coverage goal
      endcase
    end
    bump({"cg_cpu,cp_err,", t.err ? "error" : "ok"});
    bump({"cg_cpu,cp_rsp_bp,", (t.rsp_bp_cycles == 0) ? "none" : (t.rsp_bp_cycles <= 3) ? "some" : "many"});
  endfunction

  function void count_mem(mem_item t);
    string kind, e;
    kind = t.we  ? "writeback" : "refill";
    e    = t.err ? "error" : "ok";
    bump({"cg_mem,cp_kind,", kind});
    bump({"cg_mem,cp_err,", e});
    bump({"cg_mem,x_kind_err,", kind, "_", e});
    bump({"cg_mem,cp_req_bp,", (t.req_bp_cycles == 0) ? "none" : (t.req_bp_cycles <= 3) ? "some" : "many"});
    bump({"cg_mem,cp_lat,", range3(t.lat_cycles, 3, 10, "fast", "mid", "slow")});
  endfunction

  function void count_flush(flush_item t);
    bump({"cg_flush,cp_inv,",  t.inv  ? "invalidate"  : "clean_only"});
    bump({"cg_flush,cp_err,",  t.err  ? "error"       : "ok"});
    bump({"cg_flush,cp_race,", t.race ? "cpu_waiting" : "alone"});
  endfunction

  function void write_csv();
    int    fd;
    string fname, tname;
    tname = uvm_root::get().get_child("uvm_test_top").get_type_name();
    fname = {"cov_", tname, run_suffix(), ".csv"};
    fd    = $fopen(fname, "w");
    if (fd == 0) begin
      `uvm_warning("COV", {"could not write ", fname})
      return;
    end
    $fdisplay(fd, "group,coverpoint,bin,hits");
    foreach (bin_order[i]) $fdisplay(fd, "%s,%0d", bin_order[i], bin_hits[bin_order[i]]);
    $fclose(fd);
    `uvm_info("COV", {"wrote ", fname}, UVM_NONE)
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpu_imp   = new("cpu_imp",   this);
    mem_imp   = new("mem_imp",   this);
    flush_imp = new("flush_imp", this);
  endfunction

  function void write_cov_cpu  (cpu_item   t); cg_cpu.sample(t);   count_cpu(t);   endfunction
  function void write_cov_mem  (mem_item   t); cg_mem.sample(t);   count_mem(t);   endfunction
  function void write_cov_flush(flush_item t); cg_flush.sample(t); count_flush(t); endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("COV", $sformatf("coverage: cpu=%0.1f%%  mem=%0.1f%%  flush=%0.1f%%",
                               cg_cpu.get_inst_coverage(), cg_mem.get_inst_coverage(),
                               cg_flush.get_inst_coverage()), UVM_NONE)
    write_csv();
  endfunction

endclass
