//==============================================================================
//  File    : flush_mon.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Watches the flush pins. Reports one flush_item per finished flush.
//            The scoreboard uses that report as its cue to compare all of
//            memory against the reference model.
//
//  INPUTS  : vif.mon_cb (flush_* and, for the race flag, cpu req_valid/ready)
//  OUTPUTS : ap -> scoreboard, coverage
//
//  TIMING
//    edge E0 : DUT accepts the flush (in IDLE).  We cannot see this directly,
//    edge E1 : ...but flush_busy is 1 from here on -> "start" = rising busy.
//              inv was held by the driver, so it is still valid here.
//              race = a CPU request was valid but not accepted at E0
//                     (we keep last edge's samples to look back at E0),
//                     OR a CPU request was held waiting at any edge while
//                     the flush ran (v2.1: the start-only check almost
//                     never fired, so flush coverage stayed at 83%).
//    edge En : flush_done pulse -> publish (err sampled on the same edge).
//
//  WATCH OUT:
//    - The race flag is only for coverage (did we really test a flush that
//      arrived while a CPU request was waiting?).
//==============================================================================
class flush_mon extends uvm_monitor;

  `uvm_component_utils(flush_mon)

  uvm_analysis_port #(flush_item) ap;

  cache_cfg              cfg;
  virtual cache_cpu_if   vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("FLUSH_MON", "no cache_cfg in config_db")
    vif = cfg.cpu_vif;
  endfunction

  task run_phase(uvm_phase phase);
    flush_item t;
    bit        prev_busy;
    bit        prev_cpu_waiting;      // last edge: req_valid && !req_ready
    wait (vif.rst_n === 1'b1);                                  // WAIT: reset released
    forever begin
      @(vif.mon_cb);                                            // WAIT: next edge, then read its samples

      if (vif.mon_cb.flush_busy === 1'b1 && !prev_busy) begin   // flush just started
        t         = flush_item::type_id::create("flush_mon_item");
        t.inv     = vif.mon_cb.flush_inv;
        t.race    = prev_cpu_waiting;
        t.t_start = $time;
      end

      // race: a CPU request is held off while this flush runs
      if (t != null && vif.mon_cb.req_valid === 1'b1 && vif.mon_cb.req_ready !== 1'b1)
        t.race = 1'b1;

      if (vif.mon_cb.flush_done === 1'b1) begin                 // flush finished
        if (t == null) begin
          `uvm_error("FLUSH_MON", "flush_done without a flush start")
        end
        else begin
          t.err    = vif.mon_cb.flush_err;
          t.t_done = $time;
          t.cycles = (t.t_done - t.t_start) / CLK_PERIOD;
          `uvm_info("FLUSH_MON", {"done       ", t.convert2string()}, UVM_HIGH)
          ap.write(t);
          t = null;
        end
      end

      prev_busy        = (vif.mon_cb.flush_busy === 1'b1);
      prev_cpu_waiting = (vif.mon_cb.req_valid === 1'b1) && (vif.mon_cb.req_ready !== 1'b1);
    end
  endtask

endclass
