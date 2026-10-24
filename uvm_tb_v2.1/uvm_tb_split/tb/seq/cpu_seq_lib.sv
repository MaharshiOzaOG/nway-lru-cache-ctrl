//==============================================================================
//  File    : cpu_seq_lib.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : CPU sequences (run on cpu_seqr).
//    cpu_base_seq : do_op() = send one item AND wait for its answer.
//                   Every CPU sequence extends this.
//    cpu_op_seq   : exactly one load or store with fixed fields. Virtual
//                   sequences use it to do directed accesses and read the
//                   answer (rsp_item).
//    cpu_rand_seq : n random loads/stores from the address pool in cache_cfg
//                   (many tags on few sets -> conflicts, evictions, writebacks).
//
//  WHY get_response() IN do_op (the "blocking" lives HERE, not in the driver)
//    The driver takes an item with get() and answers later with put(). The
//    sequence decides whether to wait for that answer. v1 waits every time
//    (one access at a time, like the DUT).
//    v2 (non-blocking): do not wait here; call use_response_handler(1) and
//    override response_handler() to collect answers as they come back, and
//    send several items before the first answer.
//
//  WATCH OUT:
//    - Never send an item without collecting its response, or cpu_seqr's
//      response queue overflows (UVM error).
//==============================================================================

//------------------------------------------------------------------------------
class cpu_base_seq extends uvm_sequence #(cpu_item);

  `uvm_object_utils(cpu_base_seq)
  `uvm_declare_p_sequencer(cpu_seqr)

  function new(string name = "cpu_base_seq");
    super.new(name);
  endfunction

  // Send one item and wait for its answer. The answer comes back in the same
  // object (the driver fills rdata/err/lat_cycles in), so after this returns
  // `it` holds the result.
  task do_op(cpu_item it);
    cpu_item rsp;
    start_item(it);                                             // WAIT: driver ready to take an item
    finish_item(it);                                            // returns as soon as the driver get()s it
    get_response(rsp, it.get_transaction_id());                 // WAIT: the DUT's answer
  endtask

endclass


//------------------------------------------------------------------------------
class cpu_op_seq extends cpu_base_seq;

  `uvm_object_utils(cpu_op_seq)

  // fields to set before start()
  bit      op_we;
  addr_t   op_addr;
  data_t   op_wdata;
  strb_t   op_wstrb = '1;

  // result after start() returns
  cpu_item rsp_item;

  function new(string name = "cpu_op_seq");
    super.new(name);
  endfunction

  task body();
    rsp_item       = cpu_item::type_id::create("op");
    rsp_item.we    = op_we;
    rsp_item.addr  = op_addr;
    rsp_item.wdata = op_we ? op_wdata : '0;
    rsp_item.wstrb = op_we ? op_wstrb : '0;
    do_op(rsp_item);
  endtask

endclass


//------------------------------------------------------------------------------
class cpu_rand_seq extends cpu_base_seq;

  `uvm_object_utils(cpu_rand_seq)

  int unsigned n_ops = 100;

  function new(string name = "cpu_rand_seq");
    super.new(name);
  endfunction

  task body();
    cpu_item    it;
    cache_cfg   cfg;
    addr_t      a;
    bit         w;
    cfg = p_sequencer.cfg;

    repeat (n_ops) begin
      // pick an address from the pool (re-read each time: knobs may change)
      a = mk_addr(cfg.pool_tag_base + $urandom_range(0, cfg.pool_n_tags - 1),
                  cfg.pool_set_base + $urandom_range(0, cfg.pool_n_sets - 1),
                  $urandom_range(0, WPL - 1));
      w = ($urandom_range(1, 100) <= cfg.store_pct);

      it = cpu_item::type_id::create("it");
      if (!it.randomize() with { addr == a; we == w; })
        `uvm_fatal("CPU_SEQ", "randomize failed")
      do_op(it);
    end
  endtask

endclass
