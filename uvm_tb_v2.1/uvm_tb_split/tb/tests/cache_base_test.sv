//==============================================================================
//  File    : cache_base_test.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Parent of every test. Does everything that is the same for all:
//    build : create cache_cfg (via the FACTORY, so a child test's override
//            decides which variant you get) + mem_model, fetch the virtual
//            interfaces that tb_top put in config_db, share cfg with
//            everyone, build cache_env.
//    run   : 1. start the memory responder in the background (forever)
//            2. wait for reset to end
//            3. run_scenario()   <- the only thing a child test really changes
//            4. one last flush   -> the scoreboard compares all of memory
//            5. let the simulation end (drop the objection)
//    report: print *** TEST PASSED *** / *** TEST FAILED ***, and write
//            summary_<test>.txt (cache_cov writes cov_<test>.csv) for
//            tools/merge_cov.py
//
//  HOW A CHILD TEST CHANGES THINGS (factory overrides, v2.1)
//    function void build_phase(uvm_phase phase);
//      cache_cfg::type_id::set_type_override(cache_cfg_bp::get_type()); // 1. FIRST
//      super.build_phase(phase);                                        // 2. then build
//    endfunction
//    The override must be registered BEFORE super.build_phase(), because that
//    is where cfg (and the env below it) get created. Registering it after
//    would have no effect: the objects would already exist.
//
//  WATCH OUT:
//    - The memory responder never finishes. That is fine: the test ends when
//      this run_phase drops its objection; UVM then stops every sequence.
//    - PASS/FAIL counts UVM_ERROR/UVM_FATAL only. The SVA checks in
//      design/sva print "ENV: ..." / "DUT: ..." with $error, which UVM does
//      not count: also search the log for those.
//==============================================================================
class cache_base_test extends uvm_test;

  `uvm_component_utils(cache_base_test)

  cache_env  env;
  cache_cfg  cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Child tests override this to run their scenario.
  virtual task run_scenario();
  endtask

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg     = cache_cfg::type_id::create("cfg");
    cfg.mem = mem_model::type_id::create("mem");
    if (!uvm_config_db #(virtual cache_cpu_if)::get(this, "", "cpu_vif", cfg.cpu_vif))
      `uvm_fatal("TEST", "cpu_vif not found in config_db (set it in tb_top)")
    if (!uvm_config_db #(virtual cache_mem_if)::get(this, "", "mem_vif", cfg.mem_vif))
      `uvm_fatal("TEST", "mem_vif not found in config_db (set it in tb_top)")
    uvm_config_db #(cache_cfg)::set(this, "*", "cfg", cfg);
    env = cache_env::type_id::create("env", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_top.print_topology();
    `uvm_info("TEST", {"config: ", cfg.convert2string()}, UVM_NONE)
  endfunction

  task run_phase(uvm_phase phase);
    mem_resp_seq  mseq;
    flush_seq     fseq;

    phase.raise_objection(this);

    mseq = mem_resp_seq::type_id::create("mem_resp_seq");
    fork
      mseq.start(env.mem_agt.seqr);                             // memory answers, forever
    join_none

    wait (cfg.cpu_vif.rst_n === 1'b1);                          // WAIT: reset released
    repeat (2) @(cfg.cpu_vif.mon_cb);                           // DELAY: 2 quiet cycles after reset

    run_scenario();

    fseq     = flush_seq::type_id::create("final_flush");       // final memory compare
    fseq.inv = 1'b0;
    fseq.start(env.flush_agt.seqr);

    repeat (20) @(cfg.cpu_vif.mon_cb);                          // DELAY: let monitors finish
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server svr;
    int unsigned      n_err;
    super.report_phase(phase);
    svr   = uvm_report_server::get_server();
    n_err = svr.get_severity_count(UVM_ERROR) + svr.get_severity_count(UVM_FATAL);
    if (n_err == 0)
      `uvm_info("TEST", "\n\n    *** TEST PASSED ***   (also check: no 'ENV:'/'DUT:' assertion messages)\n", UVM_NONE)
    else
      `uvm_info("TEST", $sformatf("\n\n    *** TEST FAILED: %0d UVM error(s) ***\n", n_err), UVM_NONE)
    write_summary(n_err);
  endfunction

  // summary_<test>[_<RUN_ID>].txt : one small text file per run, for
  // tools/merge_cov.py.  Add +RUN_ID=<tag> to tell repeated runs apart.
  function void write_summary(int unsigned n_err);
    int    fd;
    string fname;
    fname = {"summary_", get_type_name(), run_suffix(), ".txt"};
    fd    = $fopen(fname, "w");
    if (fd == 0) begin
      `uvm_warning("TEST", {"could not write ", fname})
      return;
    end
    $fdisplay(fd, "test=%s", get_type_name());
    $fdisplay(fd, "run_id=%s", (run_suffix() == "") ? "none" : run_suffix().substr(1, run_suffix().len() - 1));
    $fdisplay(fd, "result=%s", (n_err == 0) ? "PASS" : "FAIL");
    $fdisplay(fd, "uvm_errors=%0d", n_err);
    $fdisplay(fd, "config=%s", cfg.convert2string());
    $fdisplay(fd, "scoreboard=%s", env.sb.summary());
    $fdisplay(fd, "sim_time_ns=%0t", $time);
    $fclose(fd);
    `uvm_info("TEST", {"wrote ", fname}, UVM_NONE)
  endfunction

endclass

