//==============================================================================
//  File    : cache_scoreboard.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The COMPARATOR. Receives what the monitors saw and checks it
//            against the predictor (cache_ref_model).
//
//  INPUTS  (three analysis imps, one per monitor)
//    write_sb_mem   : each finished memory transaction  (mem_mon.ap)
//    write_sb_cpu   : each finished CPU access          (cpu_mon.ap)
//    write_sb_flush : each finished flush               (flush_mon.ap)
//  OUTPUT
//    cov_ap         : the CPU access again, now tagged with its outcome
//                     (hit / clean miss / dirty miss) -> cache_cov
//
//  HOW A CPU ACCESS IS CHECKED  (also: traffic shape = at most 1 writeback
//  then 1 refill, refill address = the access's line, and no memory traffic
//  may fall outside every CPU access / flush)
//    1. Find "its" memory traffic: memory transactions that started after the
//       CPU request was accepted and ended before its response.
//       From that: outcome (no refill = hit; refill only = clean miss;
//       writeback + refill = dirty miss), refill error?, writeback error?
//    2. Error flag : rsp.err must be 1 exactly when its traffic had an error.
//    3. Echo       : rsp.we must equal the request's we.
//    4. Load       : if the refill did not fail, every predictable byte of
//                    rdata must equal the reference model.
//    5. Store      : the DUT really stores unless the refill failed (the line
//                    was never installed). If it stored, apply it to the model.
//  ON EVERY FLUSH
//    - flush.err must be 1 exactly when one of its writebacks failed.
//    - check_memory(): every byte of main memory must equal the model
//      (bytes made unknown by failed writebacks are skipped).
//  ON EVERY FAILED WRITEBACK
//    - that line becomes "unknown" in the model (see cache_ref_model).
//
//  WHY THIS IS DIFFERENT / OTHER WAY
//    - `uvm_analysis_imp_decl(_sb_cpu) etc. give this one class three write_*()
//      methods, one per input. OTHER WAY: three uvm_tlm_analysis_fifos and a
//      run_phase that get()s from them (easier to follow, more threads).
//    - Time-window matching of memory traffic to a CPU access only works
//      because the v1 DUT is blocking (one access at a time).
//      v2 (non-blocking): match by LINE ADDRESS instead (an MSHR entry owns
//      the refill of one line), and predict loads at ACCEPT time using
//      cpu_mon.req_ap, comparing at response time by id.
//
//  WATCH OUT:
//    - Hit/miss counts are printed for information only, not failed on
//      (the directed test checks exact counts on purpose).
//    - Analysis write()s are function calls in the monitor's thread: keep
//      them fast and never block in here.
//==============================================================================
`uvm_analysis_imp_decl(_sb_cpu)
`uvm_analysis_imp_decl(_sb_mem)
`uvm_analysis_imp_decl(_sb_flush)

class cache_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(cache_scoreboard)

  uvm_analysis_imp_sb_cpu   #(cpu_item,   cache_scoreboard) cpu_imp;
  uvm_analysis_imp_sb_mem   #(mem_item,   cache_scoreboard) mem_imp;
  uvm_analysis_imp_sb_flush #(flush_item, cache_scoreboard) flush_imp;
  uvm_analysis_port         #(cpu_item)                     cov_ap;

  cache_cfg        cfg;
  cache_ref_model  ref_m;

  mem_item         mem_hist[$];   // memory traffic not yet matched to a CPU access/flush

  // ---------------- counters (public: sequences read them) -----------------
  int unsigned n_loads, n_stores, n_hits, n_clean_miss, n_dirty_miss;
  int unsigned n_mem_rd, n_mem_wr, n_mem_rd_err, n_mem_wr_err;
  int unsigned n_rsp_err, n_data_checked, n_data_skipped, n_mismatch;
  int unsigned n_flush, n_flush_err, n_mem_checks, n_mem_bytes_checked, n_mem_byte_bad;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpu_imp   = new("cpu_imp",   this);
    mem_imp   = new("mem_imp",   this);
    flush_imp = new("flush_imp", this);
    cov_ap    = new("cov_ap",    this);
    ref_m     = cache_ref_model::type_id::create("ref_m");
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("SB", "no cache_cfg in config_db")
  endfunction

  // ==========================================================================
  // memory transaction finished
  // ==========================================================================
  function void write_sb_mem(mem_item t);
    mem_hist.push_back(t);
    if (t.we) begin
      n_mem_wr++;
      if (t.err) begin
        n_mem_wr_err++;
        ref_m.mark_line_unknown(t.addr);
        `uvm_info("SB", $sformatf("writeback of line %h FAILED -> line now unchecked", t.addr), UVM_MEDIUM)
      end
    end
    else begin
      n_mem_rd++;
      if (t.err) n_mem_rd_err++;
    end
  endfunction

  // ==========================================================================
  // CPU access finished
  // ==========================================================================
  function void write_sb_cpu(cpu_item t);
    int unsigned n_rd, n_wr;
    bit          rd_err, wr_err, exp_err;
    data_t       exp_data;
    strb_t       mask;
    mem_item     keep[$];

    // ---- 1. memory traffic that belongs to this access -----------------------
    foreach (mem_hist[i]) begin
      if (mem_hist[i].t_req > t.t_accept && mem_hist[i].t_rsp < t.t_rsp) begin
        if (mem_hist[i].we) begin
          n_wr++; wr_err |= mem_hist[i].err;
        end
        else begin
          n_rd++; rd_err |= mem_hist[i].err;
          if (mem_hist[i].addr !== line_base(t.addr))
            `uvm_error("SB", $sformatf("refill of line %h, but the access was to %h",
                                       mem_hist[i].addr, t.addr))
        end
      end
      else if (mem_hist[i].t_rsp > t.t_rsp) begin
        keep.push_back(mem_hist[i]);       // newer than this access, keep for later
      end
      else begin                           // blocking DUT: memory traffic outside any access
        `uvm_error("SB", {"memory transaction outside any CPU access or flush: ",
                          mem_hist[i].convert2string()})
      end
    end
    mem_hist = keep;

    // a blocking access does at most: one writeback, then one refill
    if (n_rd > 1 || n_wr > 1 || (n_wr == 1 && n_rd == 0))
      `uvm_error("SB", $sformatf("unexpected memory traffic for %s: %0d refill(s), %0d writeback(s)",
                                 t.convert2string(), n_rd, n_wr))

    if (n_rd == 0)      begin t.outcome = OUT_HIT;        n_hits++;       end
    else if (n_wr == 0) begin t.outcome = OUT_CLEAN_MISS; n_clean_miss++; end
    else                begin t.outcome = OUT_DIRTY_MISS; n_dirty_miss++; end

    // ---- 2. error flag --------------------------------------------------------
    exp_err = rd_err || wr_err;
    if (t.err) n_rsp_err++;
    if (t.err !== exp_err)
      `uvm_error("SB", $sformatf("err=%0d but expected %0d (refill err=%0d, writeback err=%0d): %s",
                                 t.err, exp_err, rd_err, wr_err, t.convert2string()))

    // ---- 3. echo --------------------------------------------------------------
    if (t.rsp_we !== t.we)
      `uvm_error("SB", $sformatf("rsp_we=%0d does not echo we=%0d: %s", t.rsp_we, t.we, t.convert2string()))

    // ---- 4/5. data ----------------------------------------------------------
    if (t.we) begin
      n_stores++;
      if (!rd_err) ref_m.apply_store(t.addr, t.wdata, t.wstrb);   // refill failed -> never stored
    end
    else begin
      n_loads++;
      if (rd_err) begin
        n_data_skipped++;                                     // no valid data on a failed refill
      end
      else begin
        ref_m.expected_word(t.addr, exp_data, mask);
        if (mask != '1) n_data_skipped++;
        if (mask != '0) begin
          n_data_checked++;
          for (int i = 0; i < STRB_W; i++) begin
            if (mask[i] && t.rdata[8*i +: 8] !== exp_data[8*i +: 8]) begin
              n_mismatch++;
              `uvm_error("SB", $sformatf("LOAD DATA MISMATCH addr=%h got=%h exp=%h (mask=%b) %s",
                                         t.addr, t.rdata, exp_data, mask, t.outcome.name()))
              break;
            end
          end
        end
      end
    end

    `uvm_info("SB", $sformatf("%s  %s", t.convert2string(), t.outcome.name()), UVM_HIGH)
    cov_ap.write(t);
  endfunction

  // ==========================================================================
  // flush finished
  // ==========================================================================
  function void write_sb_flush(flush_item f);
    bit      wb_err;
    mem_item keep[$];

    n_flush++;
    foreach (mem_hist[i]) begin
      if (mem_hist[i].t_req >= f.t_start && mem_hist[i].t_rsp <= f.t_done) begin
        if (mem_hist[i].we) wb_err |= mem_hist[i].err;
      end
      else if (mem_hist[i].t_rsp > f.t_done) begin
        keep.push_back(mem_hist[i]);
      end
      else begin
        `uvm_error("SB", {"memory transaction outside any CPU access or flush: ",
                          mem_hist[i].convert2string()})
      end
    end
    mem_hist = keep;

    if (f.err) n_flush_err++;
    if (f.err !== wb_err)
      `uvm_error("SB", $sformatf("flush_err=%0d but a writeback error was %0sseen",
                                 f.err, wb_err ? "" : "NOT "))

    check_memory($sformatf("after flush #%0d (inv=%0d)", n_flush, f.inv));
  endfunction

  // ==========================================================================
  // Compare every byte of main memory with the reference model.
  // Valid right after a flush: no line is dirty any more, so memory alone must
  // hold the right data.
  // ==========================================================================
  function void check_memory(string when);
    byte unsigned exp_b;
    int unsigned  checked, bad;

    n_mem_checks++;
    // bytes the CPU stored
    foreach (ref_m.ref_mem[a]) begin
      if (ref_m.expected_byte(a, exp_b)) begin
        checked++;
        if (cfg.mem.read_byte(a) !== exp_b) begin
          bad++;
          if (bad <= 5)
            `uvm_error("SB", $sformatf("MEMORY MISMATCH %s: addr=%h mem=%h exp=%h",
                                       when, a, cfg.mem.read_byte(a), exp_b))
        end
      end
    end
    // bytes memory holds that the CPU never stored (must still be init data)
    foreach (cfg.mem.mem[a]) begin
      if (!ref_m.ref_mem.exists(a) && ref_m.expected_byte(a, exp_b)) begin
        checked++;
        if (cfg.mem.mem[a] !== exp_b) begin
          bad++;
          if (bad <= 5)
            `uvm_error("SB", $sformatf("MEMORY MISMATCH %s: addr=%h mem=%h exp=%h (never stored)",
                                       when, a, cfg.mem.mem[a], exp_b))
        end
      end
    end
    n_mem_bytes_checked += checked;
    n_mem_byte_bad      += bad;
    `uvm_info("SB", $sformatf("memory check %s: %0d bytes compared, %0d bad, %0d unknown skipped",
                              when, checked, bad, ref_m.num_unknown()), UVM_LOW)
  endfunction

  // ==========================================================================
  function string summary();
    return $sformatf({"loads=%0d stores=%0d | hits=%0d clean_miss=%0d dirty_miss=%0d | ",
                      "mem rd=%0d (err %0d) wr=%0d (err %0d) | rsp_err=%0d | ",
                      "data checked=%0d skipped=%0d MISMATCH=%0d | ",
                      "flushes=%0d (err %0d) mem checks=%0d bad bytes=%0d"},
                     n_loads, n_stores, n_hits, n_clean_miss, n_dirty_miss,
                     n_mem_rd, n_mem_rd_err, n_mem_wr, n_mem_wr_err, n_rsp_err,
                     n_data_checked, n_data_skipped, n_mismatch,
                     n_flush, n_flush_err, n_mem_checks, n_mem_byte_bad);
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB", {"SUMMARY  ", summary()}, UVM_NONE)
    if (n_loads + n_stores == 0)
      `uvm_error("SB", "no CPU accesses were checked")
  endfunction

endclass
