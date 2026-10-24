//==============================================================================
//  File    : mem_drv.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The pin side of main memory. It does NOT decide what to answer
//            (mem_resp_seq does); it only applies the timing:
//              - mem_req_ready backpressure (random, from cfg)
//              - wait the chosen latency, then drive the response and hold it
//                until the DUT takes it
//
//  INPUTS  : mem_items (answers) from mem_seqr;  DUT pins req_*, rsp_ready
//  OUTPUTS : DUT pins req_ready, rsp_valid, rsp_rdata, rsp_err
//
//  TIMING (vif.drv_cb, see cache_if.sv)
//    ready thread : every edge, choose req_ready for the NEXT edge
//                   (cfg.mem_req_ready_pct). Independent of everything else.
//    rsp thread   : the answer item arrives on the edge the request was
//                   accepted (monitor -> FIFO -> sequence -> here, zero time).
//                   repeat(latency + 1) @(cb)
//                       "+1" lands us on a clean edge before driving (see
//                       cache_if.sv: never drive between edges);
//                       "latency" models the DRAM access + burst beats.
//                   raise rsp_valid with data/err (+1ns), hold until an edge
//                   where rsp_ready = 1 (the DUT's WB_RSP / RF_RSP states),
//                   then drop it.
//
//  WHY THIS IS DIFFERENT
//    TWO THREADS: req_ready backpressure is unrelated to responses. Keeping it
//    in its own thread lets the DUT be stalled at random moments, which is
//    what flushes out timing bugs (SVA DUT_mem_req_stable checks the DUT holds
//    its request steady meanwhile).
//    The "beats" of a real DRAM/AXI burst are modelled only as latency; the
//    pins stay one whole line per transfer (the DUT's interface).
//
//  WATCH OUT:
//    - Rule checked by SVA ENV_mem_rsp_stable: once rsp_valid is up, data/err
//      must not change until accepted. We drive them once and hold.
//    - Rule ENV_mem_rsp_only_when_pending: never answer before a request was
//      accepted. Guaranteed because answers only come from the request FIFO.
//    - cfg.mem_req_ready_pct = 0 would stall the DUT forever.
//==============================================================================
class mem_drv extends uvm_driver #(mem_item);

  `uvm_component_utils(mem_drv)

  cache_cfg              cfg;
  virtual cache_mem_if   vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("MEM_DRV", "no cache_cfg in config_db")
    vif = cfg.mem_vif;
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.rst_n === 1'b1);                                  // WAIT: reset released
    fork
      ready_thread();
      response_thread();
    join
  endtask

  // --------------------------------------------------------------------------
  // mem_req_ready backpressure
  // --------------------------------------------------------------------------
  task ready_thread();
    forever begin
      @(vif.drv_cb);                                            // WAIT: next edge
      vif.drv_cb.req_ready <= ($urandom_range(1, 100) <= cfg.mem_req_ready_pct);
    end
  endtask

  // --------------------------------------------------------------------------
  // Responses, one at a time, in the order the requests were accepted
  // --------------------------------------------------------------------------
  task response_thread();
    mem_item rsp;
    forever begin
      seq_item_port.get_next_item(rsp);                         // WAIT: the responder's answer

      repeat (rsp.latency + 1) @(vif.drv_cb);                   // DELAY: memory access time (+1 = align to edge)

      vif.drv_cb.rsp_valid <= 1'b1;
      vif.drv_cb.rsp_rdata <= rsp.rdata;
      vif.drv_cb.rsp_err   <= rsp.err;

      do @(vif.drv_cb);                                         // WAIT: until the DUT accepts
      while (vif.drv_cb.rsp_ready !== 1'b1);

      vif.drv_cb.rsp_valid <= 1'b0;
      vif.drv_cb.rsp_err   <= 1'b0;
      `uvm_info("MEM_DRV", {"answered   ", rsp.convert2string()}, UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask

endclass
