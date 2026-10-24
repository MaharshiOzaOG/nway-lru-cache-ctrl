//==============================================================================
//  File    : flush_seq_lib.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : flush_seq = one flush (set `inv` before start). When start()
//            returns the flush is finished and `err` holds flush_err.
//            Standard start_item/finish_item; flush_drv uses
//            get_next_item/item_done, so finish_item waits for the whole flush.
//==============================================================================
class flush_seq extends uvm_sequence #(flush_item);

  `uvm_object_utils(flush_seq)

  bit inv;      // set before start()
  bit err;      // result

  function new(string name = "flush_seq");
    super.new(name);
  endfunction

  task body();
    flush_item it;
    it     = flush_item::type_id::create("flush");
    it.inv = inv;
    start_item(it);                                             // WAIT: flush_drv ready
    finish_item(it);                                            // WAIT: flush finished (item_done)
    err = it.err;
  endtask

endclass
