//==============================================================================
//  File    : cpu_mon.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Watches the CPU pins (never drives them). Builds a cpu_item when a
//            request is accepted, completes it when its response is accepted,
//            and publishes the completed item.
//
//  INPUTS  : DUT pins through vif.mon_cb
//  OUTPUTS : ap     -> completed transactions  (scoreboard)
//            req_ap -> accepted requests only  (not connected in v1; a v2
//                      scoreboard predicts at accept time, see below)
//
//  TIMING
//    Once per edge, look at values sampled AT that edge:
//      rsp_valid && rsp_ready -> a response handshake on this edge
//      req_valid && req_ready -> a request  handshake on this edge
//    Responses are handled BEFORE requests in the same edge, so an id that is
//    freed and re-used on the same edge (possible in v2) is still matched right.
//
//  EXTRA CHECKS DONE HERE
//    - response with an id that has no request in flight  -> UVM_ERROR
//    - two requests in flight with the same id           -> UVM_ERROR
//    - a request with no answer after cfg.rsp_timeout cycles (hang) -> UVM_ERROR
//    - requests still waiting at the end of the test     -> UVM_ERROR
//
//  WHY BUILD ITS OWN ITEM (and not reuse the driver's):
//    A monitor must report what really happened on the pins, so it works even
//    if the driver is replaced (e.g. a real CPU model, or a passive agent).
//
//  v2 (non-blocking): already matches by id. Connect req_ap to the scoreboard
//    so it can predict load data in ACCEPT order (the order the DUT sees).
//==============================================================================
class cpu_mon extends uvm_monitor;

  `uvm_component_utils(cpu_mon)

  uvm_analysis_port #(cpu_item)  ap;
  uvm_analysis_port #(cpu_item)  req_ap;

  cache_cfg              cfg;
  virtual cache_cpu_if   vif;

  cpu_item  pending [id_t];     // accepted, not yet answered
  bit       reported_hang [id_t];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap     = new("ap", this);
    req_ap = new("req_ap", this);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CPU_MON", "no cache_cfg in config_db")
    vif = cfg.cpu_vif;
  endfunction

  task run_phase(uvm_phase phase);
    cpu_item t;
    id_t     rid;
    wait (vif.rst_n === 1'b1);                                  // WAIT: reset released
    forever begin
      @(vif.mon_cb);                                            // WAIT: next edge, then read its samples

      // ---- 1) response channel -------------------------------------------
      if (vif.mon_cb.rsp_valid === 1'b1) begin
        rid = vif.mon_cb.rsp_id;
        if (vif.mon_cb.rsp_ready === 1'b1) begin                // response handshake
          if (!pending.exists(rid)) begin
            `uvm_error("CPU_MON", $sformatf("response id %0d with no request in flight", rid))
          end
          else begin
            t = pending[rid];
            pending.delete(rid);
            if (reported_hang.exists(rid)) reported_hang.delete(rid);
            t.rdata      = vif.mon_cb.rsp_rdata;
            t.err        = vif.mon_cb.rsp_err;
            t.rsp_we     = vif.mon_cb.rsp_we;
            t.t_rsp      = $time;
            t.lat_cycles = (t.t_rsp - t.t_accept) / CLK_PERIOD;
            `uvm_info("CPU_MON", {"done       ", t.convert2string()}, UVM_HIGH)
            ap.write(t);
          end
        end
        else if (pending.exists(rid)) begin                    // response waiting on rsp_ready
          pending[rid].rsp_bp_cycles++;
        end
      end

      // ---- 2) request channel ----------------------------------------------
      if (vif.mon_cb.req_valid === 1'b1 && vif.mon_cb.req_ready === 1'b1) begin
        t = cpu_item::type_id::create("cpu_mon_item");
        t.id       = vif.mon_cb.req_id;
        t.we       = vif.mon_cb.req_we;
        t.addr     = vif.mon_cb.req_addr;
        t.wdata    = vif.mon_cb.req_wdata;
        t.wstrb    = vif.mon_cb.req_wstrb;
        t.t_accept = $time;
        if (pending.exists(t.id))
          `uvm_error("CPU_MON", $sformatf("id %0d re-used while still in flight", t.id))
        pending[t.id] = t;
        req_ap.write(t);
      end

      // ---- 3) hang check ---------------------------------------------------
      foreach (pending[i]) begin
        if (!reported_hang.exists(i) &&
            ($time - pending[i].t_accept) > cfg.rsp_timeout * CLK_PERIOD) begin
          `uvm_error("CPU_MON", $sformatf("no response after %0d cycles: %s",
                                          cfg.rsp_timeout, pending[i].convert2string()))
          reported_hang[i] = 1'b1;
        end
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pending.num() != 0)
      `uvm_error("CPU_MON", $sformatf("%0d request(s) never got a response", pending.num()))
  endfunction

endclass
