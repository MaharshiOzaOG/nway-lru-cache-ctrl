//==============================================================================
//  File    : mem_mon.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Watches the memory pins (never drives them).
//
//  OUTPUTS : req_ap -> mem_seqr.dut_req_fifo   a copy of each ACCEPTED request,
//                                          so the responder can answer it
//            ap     -> scoreboard, cov     each COMPLETED transaction
//                                          (request + response + timing)
//
//  TIMING (vif.mon_cb, once per edge)
//    req_valid && req_ready  -> request handshake on this edge
//    req_valid && !req_ready -> the DUT is being held off (backpressure count)
//    rsp_valid && rsp_ready  -> response handshake on this edge
//    Responses are handled before requests on the same edge.
//
//  WHY TWO PORTS:
//    The responder needs the request as soon as it is accepted (to start the
//    latency count). The scoreboard wants the whole thing once it is done
//    (it needs to know whether it errored). Different moments, two ports.
//
//  WATCH OUT:
//    - Responses are matched to requests in ORDER (queue). True today (one
//      outstanding memory request). If v2 lets memory answer out of order,
//      the memory interface needs an id and this becomes an id lookup.
//    - req_ap gets a CLONE, so nothing the responder does can change the
//      object the scoreboard will later receive.
//==============================================================================
class mem_mon extends uvm_monitor;

  `uvm_component_utils(mem_mon)

  uvm_analysis_port #(mem_item)  req_ap;
  uvm_analysis_port #(mem_item)  ap;

  cache_cfg              cfg;
  virtual cache_mem_if   vif;

  mem_item      pend_q[$];       // accepted, not yet answered (in order)
  int unsigned  bp_count;        // cycles the current request waited for ready

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    req_ap = new("req_ap", this);
    ap     = new("ap", this);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("MEM_MON", "no cache_cfg in config_db")
    vif = cfg.mem_vif;
  endfunction

  task run_phase(uvm_phase phase);
    mem_item t;
    mem_item c;
    wait (vif.rst_n === 1'b1);                                  // WAIT: reset released
    forever begin
      @(vif.mon_cb);                                            // WAIT: next edge, then read its samples

      // ---- 1) response handshake ---------------------------------------------
      if (vif.mon_cb.rsp_valid === 1'b1 && vif.mon_cb.rsp_ready === 1'b1) begin
        if (pend_q.size() == 0) begin
          `uvm_error("MEM_MON", "memory response with no request outstanding")
        end
        else begin
          t            = pend_q.pop_front();
          t.rdata      = vif.mon_cb.rsp_rdata;
          t.err        = vif.mon_cb.rsp_err;
          t.t_rsp      = $time;
          t.lat_cycles = (t.t_rsp - t.t_req) / CLK_PERIOD;
          `uvm_info("MEM_MON", {"done       ", t.convert2string()}, UVM_HIGH)
          ap.write(t);
        end
      end

      // ---- 2) request channel --------------------------------------------------
      if (vif.mon_cb.req_valid === 1'b1) begin
        if (vif.mon_cb.req_ready === 1'b1) begin               // request handshake
          t               = mem_item::type_id::create("mem_mon_item");
          t.we            = vif.mon_cb.req_we;
          t.addr          = vif.mon_cb.req_addr;
          t.wdata         = vif.mon_cb.req_wdata;
          t.t_req         = $time;
          t.req_bp_cycles = bp_count;
          bp_count        = 0;
          pend_q.push_back(t);
          $cast(c, t.clone());
          req_ap.write(c);                                      // -> responder FIFO
        end
        else begin
          bp_count++;                                           // DUT held off by req_ready = 0
        end
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pend_q.size() != 0)
      `uvm_error("MEM_MON", $sformatf("%0d memory request(s) never answered", pend_q.size()))
  endfunction

endclass
