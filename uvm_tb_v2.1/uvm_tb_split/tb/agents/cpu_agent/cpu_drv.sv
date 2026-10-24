//==============================================================================
//  File    : cpu_drv.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Plays the CPU. Turns cpu_items into pin activity on the request
//            channel, collects the DUT's answers on the response channel and
//            hands each answer back to the sequence that asked.
//
//  INPUTS  : cpu_items from cpu_seqr;  DUT pins req_ready, rsp_*
//  OUTPUTS : DUT pins req_valid/id/we/addr/wdata/wstrb, rsp_ready;
//            the finished item back to the sequence (put)
//
//  TIMING (all through vif.drv_cb, see cache_if.sv)
//    request : @(cb) to land on an edge -> raise req_valid (+1ns) -> keep it
//              and the fields STABLE until an edge where req_ready was 1
//              (that edge IS the handshake) -> drop req_valid.
//    response: before every edge decide rsp_ready (random % from cfg) and
//              remember it in rsp_ready_now. After the edge, if rsp_valid was
//              1 AND we had rsp_ready_now = 1, the handshake happened there.
//    Why no race: we only ever look at values sampled AT the edge (#1step) and
//    only change pins 1ns AFTER the edge (#1). The DUT does the same thing.
//
//  WHY THIS IS DIFFERENT / OTHER WAY
//    1) TWO THREADS (request + response) instead of one loop.
//       The DUT has two independent channels, each with its own valid/ready.
//       One thread per channel means a stalled response never blocks the next
//       request. Not needed for the blocking v1 DUT (max_outstanding = 1 makes
//       it behave like a simple one-at-a-time driver), but it is exactly what
//       v2 (non-blocking, several requests in flight) needs.
//    2) seq_item_port.get() + seq_item_port.put(rsp)
//       instead of the classroom get_next_item() ... item_done().
//       get() = get_next_item + item_done in one call, so the sequence is free
//       again as soon as the request is taken; the answer comes back later with
//       put(). With get_next_item/item_done the sequence would be stuck until
//       the response arrived (fine for v1, wrong for v2).
//       The response object is the request object itself, filled in, so its
//       sequence/transaction ids already match.
//    3) The driver, not the sequence, assigns the request id, so ids are
//       always unique among requests in flight.
//
//  WATCH OUT:
//    - The sequence must call get_response() for every item (do_op() does).
//    - rsp_ready is random every cycle, even when no response is waiting.
//      That is the CPU-side backpressure. cfg.cpu_rsp_ready_pct = 0 hangs.
//
//  v2 (non-blocking): raise cfg.max_outstanding. Nothing else here changes.
//==============================================================================
class cpu_drv extends uvm_driver #(cpu_item);

  `uvm_component_utils(cpu_drv)

  cache_cfg              cfg;
  virtual cache_cpu_if   vif;

  cpu_item      inflight [id_t];   // accepted requests waiting for an answer
  int unsigned  outstanding;       // = inflight.num()
  id_t          next_id;
  bit           rsp_ready_now;     // rsp_ready value the DUT sees at the next edge

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CPU_DRV", "no cache_cfg in config_db")
    vif = cfg.cpu_vif;
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.rst_n === 1'b1);           // WAIT: reset released
    fork
      request_thread();
      response_thread();
    join
  endtask

  // --------------------------------------------------------------------------
  // REQUEST channel: one item at a time, hold until accepted
  // --------------------------------------------------------------------------
  task request_thread();
    cpu_item req;
    forever begin
      seq_item_port.get(req);                                   // WAIT: next item from the sequence

      while (outstanding >= cfg.max_outstanding) @(vif.drv_cb); // WAIT: a free slot (v1: previous answer back)
      repeat ($urandom_range(0, cfg.cpu_gap_max)) @(vif.drv_cb);// DELAY: random idle cycles between requests

      while (inflight.exists(next_id)) next_id++;               // pick an id not in flight
      req.id = next_id;
      next_id++;

      @(vif.drv_cb);                                            // WAIT: land on an edge before driving
      vif.drv_cb.req_valid <= 1'b1;
      vif.drv_cb.req_id    <= req.id;
      vif.drv_cb.req_we    <= req.we;
      vif.drv_cb.req_addr  <= req.addr;
      vif.drv_cb.req_wdata <= req.wdata;
      vif.drv_cb.req_wstrb <= req.wstrb;

      do @(vif.drv_cb);                                         // WAIT: until an edge where ready was 1
      while (vif.drv_cb.req_ready !== 1'b1);                    //       (DUT busy or flushing -> keep holding)

      // The handshake happened on this edge.
      req.t_accept       = $time;
      inflight[req.id]   = req;
      outstanding++;
      vif.drv_cb.req_valid <= 1'b0;
      `uvm_info("CPU_DRV", {"accepted   ", req.convert2string()}, UVM_HIGH)
    end
  endtask

  // --------------------------------------------------------------------------
  // RESPONSE channel: random rsp_ready, catch answers, return them
  // --------------------------------------------------------------------------
  task response_thread();
    cpu_item rsp;
    id_t     rid;
    @(vif.drv_cb);                                              // WAIT: land on an edge first
    forever begin
      rsp_ready_now = ($urandom_range(1, 100) <= cfg.cpu_rsp_ready_pct);
      vif.drv_cb.rsp_ready <= rsp_ready_now;                    // seen by the DUT at the next edge
      @(vif.drv_cb);                                            // WAIT: that edge

      if (vif.drv_cb.rsp_valid === 1'b1 && rsp_ready_now) begin // handshake on this edge
        rid = vif.drv_cb.rsp_id;
        if (!inflight.exists(rid)) begin
          `uvm_error("CPU_DRV", $sformatf("response with id %0d but no such request in flight", rid))
        end
        else begin
          rsp = inflight[rid];
          inflight.delete(rid);
          outstanding--;
          rsp.rdata      = vif.drv_cb.rsp_rdata;
          rsp.err        = vif.drv_cb.rsp_err;
          rsp.rsp_we     = vif.drv_cb.rsp_we;
          rsp.t_rsp      = $time;
          rsp.lat_cycles = (rsp.t_rsp - rsp.t_accept) / CLK_PERIOD;
          `uvm_info("CPU_DRV", {"answered   ", rsp.convert2string()}, UVM_HIGH)
          seq_item_port.put(rsp);                               // back to the sequence (get_response)
        end
      end
    end
  endtask

endclass
