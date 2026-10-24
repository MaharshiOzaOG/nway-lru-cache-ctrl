//==============================================================================
//  File    : mem_resp_seq.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The "brain" of main memory. Runs forever in the background
//            (the base test starts it once, before any traffic):
//              1. wait for a DUT request         (p_sequencer.dut_req_fifo.get)
//              2. decide the answer:
//                   latency  : random in [cfg.mem_lat_min, cfg.mem_lat_max]
//                   err      : forced (cfg.force_*_err) or random (cfg.*_err_pct)
//              3. do it to the memory contents (mem_model):
//                   writeback, no error -> write the line
//                   refill,    no error -> read the line into rdata
//                   any error           -> memory unchanged, rdata = junk
//              4. send the answer to mem_drv (start_item / finish_item)
//
//  WHY THIS IS DIFFERENT (reactive sequence)
//    Its items are answers to the DUT, not stimulus. See mem_seqr.sv for the
//    FIFO pattern. It never ends; the test simply stops when its own work is
//    done (run_phase objections), which kills this sequence too.
//
//  WATCH OUT:
//    - Knobs are read for EVERY request, so a knob changed during the run
//      (e.g. force_rd_err in directed T7) takes effect at once.
//    - memory is updated here, at request time, not when the response is
//      driven. Fine because only one memory request is outstanding.
//==============================================================================
class mem_resp_seq extends uvm_sequence #(mem_item);

  `uvm_object_utils(mem_resp_seq)
  `uvm_declare_p_sequencer(mem_seqr)

  function new(string name = "mem_resp_seq");
    super.new(name);
  endfunction

  task body();
    mem_item   dut_req;
    mem_item   rsp;
    cache_cfg  cfg;
    cfg = p_sequencer.cfg;

    forever begin
      p_sequencer.dut_req_fifo.get(dut_req);                        // WAIT: until the DUT asks

      rsp       = mem_item::type_id::create("mem_rsp");
      rsp.we    = dut_req.we;
      rsp.addr  = dut_req.addr;
      rsp.wdata = dut_req.wdata;

      // ---- latency and error ------------------------------------------------
      rsp.latency = $urandom_range(cfg.mem_lat_min, cfg.mem_lat_max);
      if (dut_req.we) begin
        if (cfg.force_wr_err > 0) begin rsp.err = 1'b1; cfg.force_wr_err--; end
        else rsp.err = ($urandom_range(1, 100) <= cfg.mem_wr_err_pct);
      end
      else begin
        if (cfg.force_rd_err > 0) begin rsp.err = 1'b1; cfg.force_rd_err--; end
        else rsp.err = ($urandom_range(1, 100) <= cfg.mem_rd_err_pct);
      end

      // ---- apply to memory contents -----------------------------------------
      if (rsp.err)          rsp.rdata = {(LINE_W/32){32'hBAD0_BAD0}};
      else if (dut_req.we)  cfg.mem.write_line(dut_req.addr, dut_req.wdata);
      else                  rsp.rdata = cfg.mem.read_line(dut_req.addr);

      `uvm_info("MEM_SEQ", $sformatf("%s addr=%h -> err=%0d latency=%0d",
                dut_req.we ? "WRITEBACK" : "REFILL", dut_req.addr, rsp.err, rsp.latency), UVM_HIGH)

      start_item(rsp);                                          // WAIT: mem_drv free
      finish_item(rsp);                                         // WAIT: mem_drv answered the DUT
    end
  endtask

endclass
