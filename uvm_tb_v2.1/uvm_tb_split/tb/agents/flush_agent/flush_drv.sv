//==============================================================================
//  File    : flush_drv.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Drives one flush at a time: flush_req + flush_inv. Touches NO
//            other signal, so it can run at the same time as cpu_drv (that is
//            how a flush can arrive while a CPU request is waiting).
//
//  INPUTS  : flush_items from flush_seqr;  DUT pins flush_busy/done/err
//  OUTPUTS : DUT pins flush_req, flush_inv;  item.err filled in
//
//  TIMING (vif.flush_cb, see cache_if.sv)
//    1) @(cb), raise flush_req (+1ns) with flush_inv.
//    2) Hold flush_req until an edge where flush_busy = 1.
//         The DUT only starts a flush in IDLE. If a CPU access is in progress
//         this can take many cycles. A flush wins over a CPU request that
//         arrives in the same cycle.
//         busy = 1 means the DUT has started; it no longer looks at
//         flush_req, so it is safe (and required) to drop it now. If we kept
//         it high, the DUT would start a SECOND flush when it returns to IDLE.
//    3) Wait for the flush_done pulse (1 cycle). flush_err is valid on that
//       same edge.
//
//  WATCH OUT:
//    - Rule checked by SVA ENV_flush_hold: flush_req must not drop before the
//      flush starts. Step 2 guarantees it.
//    - Standard get_next_item()/item_done() here (one flush at a time, the
//      sequence waits for the result). Nothing unusual.
//==============================================================================
class flush_drv extends uvm_driver #(flush_item);

  `uvm_component_utils(flush_drv)

  cache_cfg              cfg;
  virtual cache_cpu_if   vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("FLUSH_DRV", "no cache_cfg in config_db")
    vif = cfg.cpu_vif;
  endfunction

  task run_phase(uvm_phase phase);
    flush_item req;
    wait (vif.rst_n === 1'b1);                                  // WAIT: reset released
    forever begin
      seq_item_port.get_next_item(req);                         // WAIT: next flush from the sequence

      @(vif.flush_cb);                                          // WAIT: land on an edge before driving
      vif.flush_cb.flush_req <= 1'b1;
      vif.flush_cb.flush_inv <= req.inv;

      do @(vif.flush_cb);                                       // WAIT: until the DUT has started
      while (vif.flush_cb.flush_busy !== 1'b1);                 //       (only happens in IDLE)
      vif.flush_cb.flush_req <= 1'b0;                           // started -> drop, or it would re-flush

      do @(vif.flush_cb);                                       // WAIT: the 1-cycle flush_done pulse
      while (vif.flush_cb.flush_done !== 1'b1);
      req.err = vif.flush_cb.flush_err;                         // valid together with flush_done

      `uvm_info("FLUSH_DRV", $sformatf("finished   FLUSH inv=%0d err=%0d", req.inv, req.err), UVM_MEDIUM)
      seq_item_port.item_done();
    end
  endtask

endclass
