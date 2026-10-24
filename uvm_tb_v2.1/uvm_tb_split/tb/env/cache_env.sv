//==============================================================================
//  File    : cache_env.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Builds every component and wires the analysis paths.
//
//                       +------------ cache_env -----------------------------+
//                       |                                                    |
//   cpu pins  <-------- | cpu_agt   (seqr -> drv)   mon.ap ----+             |
//   flush pins <------- | flush_agt (seqr -> drv)   mon.ap --+ |             |
//   mem pins  <-------> | mem_agt   (seqr -> drv)   mon.ap + | |             |
//                       |   mon.req_ap -> seqr.dut_req_fifo    | | |             |
//                       |                                  v v v             |
//                       |                          sb (scoreboard)           |
//                       |                            | cov_ap                |
//                       |   mem_agt.mon.ap ----->  cov <-+   <-- flush_agt   |
//                       |                                                    |
//                       | vseqr: handles to cpu/flush/mem seqr, cfg, sb      |
//                       +----------------------------------------------------+
//
//  CONNECTIONS (connect_phase)
//    cpu_agt.mon.ap    -> sb.cpu_imp
//    mem_agt.mon.ap    -> sb.mem_imp,   cov.mem_imp
//    flush_agt.mon.ap  -> sb.flush_imp, cov.flush_imp
//    sb.cov_ap         -> cov.cpu_imp
//    (mem_agt.mon.req_ap -> mem_agt.seqr.dut_req_fifo is inside mem_agent)
//==============================================================================
class cache_env extends uvm_env;

  `uvm_component_utils(cache_env)

  cpu_agent         cpu_agt;
  flush_agent       flush_agt;
  mem_agent         mem_agt;
  cache_scoreboard  sb;
  cache_cov         cov;
  cache_vseqr       vseqr;
  cache_cfg         cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("ENV", "no cache_cfg in config_db")
    cpu_agt   = cpu_agent::type_id::create("cpu_agt", this);
    flush_agt = flush_agent::type_id::create("flush_agt", this);
    mem_agt   = mem_agent::type_id::create("mem_agt", this);
    sb        = cache_scoreboard::type_id::create("sb", this);
    cov       = cache_cov::type_id::create("cov", this);
    vseqr     = cache_vseqr::type_id::create("vseqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    cpu_agt.mon.ap.connect(sb.cpu_imp);
    mem_agt.mon.ap.connect(sb.mem_imp);
    mem_agt.mon.ap.connect(cov.mem_imp);
    flush_agt.mon.ap.connect(sb.flush_imp);
    flush_agt.mon.ap.connect(cov.flush_imp);
    sb.cov_ap.connect(cov.cpu_imp);

    vseqr.cpu_sqr   = cpu_agt.seqr;
    vseqr.flush_sqr = flush_agt.seqr;
    vseqr.mem_sqr   = mem_agt.seqr;
    vseqr.cfg       = cfg;
    vseqr.sb        = sb;
  endfunction

endclass
