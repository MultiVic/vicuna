// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_top import vproc_pkg::*; #(
        parameter int unsigned     MEM_W         = 32,  // memory bus width in bits
        parameter int unsigned     VMEM_W        = 32,  // vector memory interface width in bits
        parameter vreg_type        VREG_TYPE     = VREG_GENERIC,
        parameter mul_type         MUL_TYPE      = MUL_GENERIC,
        parameter bit              DbgTriggerEn     = 1'b0,
        parameter int unsigned     DbgHwBreakNum    = 1,
        parameter int unsigned     DmHaltAddr       = 32'h1A110800,
        parameter int unsigned     DmExceptionAddr  = 32'h1A110808,
        parameter ibex_pkg::regfile_e RegFile        = ibex_pkg::RegFileFPGA
    )(
        input  logic               clk_i,
        input  logic               rst_ni,

        // Instruction memory interface
        output logic               instr_req_o,
        input  logic               instr_gnt_i,
        input  logic               instr_rvalid_i,
        output logic [31:0]        instr_addr_o,
        input  logic [31:0]        instr_rdata_i,
        input  logic [6:0]         instr_rdata_intg_i,
        input  logic               instr_err_i,

        // Data memory interface
        output logic               data_req_o,
        input  logic               data_gnt_i,
        input  logic               data_rvalid_i,
        output logic               data_we_o,
        output logic [3:0]         data_be_o,
        output logic [31:0]        data_addr_o,
        output logic [31:0]        data_wdata_o,
        output logic [6:0]         data_wdata_intg_o,
        input  logic [31:0]        data_rdata_i,
        input  logic [6:0]         data_rdata_intg_i,
        input  logic               data_err_i,

        // Interrupt inputs
        input  logic               irq_software_i,
        input  logic               irq_timer_i,
        input  logic               irq_external_i,
        input  logic [14:0]        irq_fast_i,
        input  logic               irq_nm_i,

        // Debug interface
        input  logic               debug_req_i
    );

    // Reset synchronizer (sync reset is used for Vicuna by default, async reset for the core)
    logic [3:0] rst_sync_qn;
    logic sync_rst_n;
    always_ff @(posedge clk_i) begin
        rst_sync_qn[0] <= rst_ni;
        for (int i = 1; i < 4; i++) begin
            rst_sync_qn[i] <= rst_sync_qn[i-1];
        end
    end
    assign sync_rst_n = rst_sync_qn[3];


    ///////////////////////////////////////////////////////////////////////////
    // MAIN CORE INTEGRATION

    // Data load & store interface
    logic        sdata_req;
    logic [31:0] sdata_addr;
    logic        sdata_we;
    logic  [3:0] sdata_be;
    logic [31:0] sdata_wdata;
    logic        sdata_gnt;
    logic        sdata_rvalid;
    logic        sdata_err;
    logic [31:0] sdata_rdata;

    // Vector Unit Interface
    localparam X_NUM_RS = 2;
    localparam X_ID_WIDTH = 3;
    localparam X_RFR_WIDTH = 32;
    localparam X_RFW_WIDTH = 32;
    localparam X_MISA = 0;
    vproc_xif #(
        .X_NUM_RS    ( X_NUM_RS    ),
        .X_ID_WIDTH  ( X_ID_WIDTH  ),
        .X_MEM_WIDTH ( VMEM_W      ),
        .X_RFR_WIDTH ( X_RFR_WIDTH ),
        .X_RFW_WIDTH ( X_RFW_WIDTH ),
        .X_MISA      ( X_MISA      )
    ) vcore_xif ();
    logic        vect_pending_load;
    logic        vect_pending_store;

    // CSR register interface for Vector Unit
    localparam int unsigned VECT_CSR_CNT = 7;
    logic [11:0] vect_csr_addr [VECT_CSR_CNT];
    logic [31:0] vect_csr_rdata[VECT_CSR_CNT];
    logic        vect_csr_we   [VECT_CSR_CNT];
    logic [31:0] vect_csr_wdata[VECT_CSR_CNT];
    assign vect_csr_addr = '{
        12'h008, // vstart
        12'h009, // vxsat
        12'h00A, // vxrm
        12'h00F, // vcsr
        12'hC20, // vl
        12'hC21, // vtype
        12'hC22  // vlenb
    };


    localparam bit USE_XIF_MEM = '0;

    logic        cpi_instr_valid;
    logic [31:0] cpi_instr;
    logic [31:0] cpi_x_rs1;
    logic [31:0] cpi_x_rs2;
    logic        cpi_instr_gnt;
    logic        cpi_instr_illegal;
    logic        cpi_misaligned_ls;
    logic        cpi_xreg_wait;
    logic        cpi_result_valid;
    logic        cpi_xreg_valid;
    logic [31:0] cpi_xreg;

    ibex_top #(
        .RegFile                ( RegFile                            ),
        .MHPMCounterNum         ( 10                                 ),
        .RV32M                  ( ibex_pkg::RV32MFast                ),
        .RV32B                  ( ibex_pkg::RV32BNone                ),
        .ExternalCSRs           ( VECT_CSR_CNT                       ),
        .DbgTriggerEn           ( DbgTriggerEn                       ),
        .DbgHwBreakNum          ( DbgHwBreakNum                      ),
        .DmHaltAddr             ( DmHaltAddr                         ),
        .DmExceptionAddr        ( DmExceptionAddr                    ),

        // LOAD-FP, STORE-FP and VECTOR opcodes
        .CoprocOpcodes          ( 32'h00200202                       )
    ) u_core (
        .clk_i                  ( clk_i                              ),
        .rst_ni                 ( rst_ni                             ),

        .test_en_i              ( 'b0                                ),
        .scan_rst_ni            ( 1'b1                               ),
        .ram_cfg_i              ( 'b0                                ),

        .hart_id_i              ( 32'b0                              ),
        .boot_addr_i            ( 32'h00000000                       ),

        .instr_req_o            ( instr_req_o                        ),
        .instr_gnt_i            ( instr_gnt_i                        ),
        .instr_rvalid_i         ( instr_rvalid_i                     ),
        .instr_addr_o           ( instr_addr_o                       ),
        .instr_rdata_i          ( instr_rdata_i                      ),
        .instr_rdata_intg_i     ( instr_rdata_intg_i                 ),
        .instr_err_i            ( instr_err_i                        ),

        .data_req_o             ( sdata_req                          ),
        .data_gnt_i             ( sdata_gnt                          ),
        .data_rvalid_i          ( sdata_rvalid                       ),
        .data_we_o              ( sdata_we                           ),
        .data_be_o              ( sdata_be                           ),
        .data_addr_o            ( sdata_addr                         ),
        .data_wdata_o           ( sdata_wdata                        ),
        .data_wdata_intg_o      ( data_wdata_intg_o                  ), // only used by scalar unit
        .data_rdata_i           ( sdata_rdata                        ),
        .data_rdata_intg_i      ( data_rdata_intg_i                  ), // only used by scalar unit
        .data_err_i             ( sdata_err                          ),

        .cpi_req_o              ( cpi_instr_valid                    ),
        .cpi_instr_o            ( cpi_instr                          ),
        .cpi_rs1_o              ( cpi_x_rs1                          ),
        .cpi_rs2_o              ( cpi_x_rs2                          ),
        .cpi_gnt_i              ( cpi_instr_gnt                      ),
        .cpi_instr_illegal_i    ( cpi_instr_illegal                  ),
        .cpi_wait_i             ( cpi_xreg_wait                      ),
        .cpi_res_valid_i        ( cpi_result_valid                   ),
        .cpi_res_i              ( cpi_xreg                           ),

        .irq_software_i         ( irq_software_i                     ),
        .irq_timer_i            ( irq_timer_i                        ),
        .irq_external_i         ( irq_external_i                     ),
        .irq_fast_i             ( irq_fast_i                         ),
        .irq_nm_i               ( irq_nm_i                           ),

        .ecsr_addr_i            ( vect_csr_addr                      ),
        .ecsr_rdata_i           ( vect_csr_rdata                     ),
        .ecsr_we_o              ( vect_csr_we                        ),
        .ecsr_wdata_o           ( vect_csr_wdata                     ),

        .scramble_key_valid_i   ('0                                  ),
        .scramble_key_i         ('0                                  ),
        .scramble_nonce_i       ('0                                  ),
        .scramble_req_o         (                                    ),

        .debug_req_i            ( debug_req_i                        ),
        .crash_dump_o           (                                    ),
        .double_fault_seen_o    (                                    ),

        .fetch_enable_i         ( 1'b1                               ),
        .alert_minor_o          (                                    ),
        .alert_major_internal_o (                                    ),
        .alert_major_bus_o      (                                    ),
        .core_sleep_o           (                                    )
    );

    logic [X_ID_WIDTH-1:0] cpi_instr_id_q, cpi_instr_id_q2, cpi_instr_id_d;
    logic                  cpi_commit_q,                    cpi_commit_d;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            cpi_instr_id_q  <= '0;
            cpi_instr_id_q2 <= '0;
            cpi_commit_q    <= '0;
        end else begin
            cpi_instr_id_q  <= cpi_instr_id_d;
            cpi_instr_id_q2 <= cpi_instr_id_q;
            cpi_commit_q    <= cpi_commit_d;
        end
    end
    always_comb begin
        cpi_instr_id_d = cpi_instr_id_q;
        if (vcore_xif.issue_ready & vcore_xif.issue_valid) begin
            cpi_instr_id_d = cpi_instr_id_q + {{X_ID_WIDTH-1{1'b0}}, 1'b1};
        end
    end
    assign cpi_commit_d = vcore_xif.issue_valid & vcore_xif.issue_ready & vcore_xif.issue_resp.accept;

    assign vcore_xif.issue_valid        = cpi_instr_valid;
    assign vcore_xif.issue_req.instr    = cpi_instr;
    assign vcore_xif.issue_req.mode     = '0;
    assign vcore_xif.issue_req.id       = cpi_instr_id_q;
    assign vcore_xif.issue_req.rs[0]    = cpi_x_rs1;
    assign vcore_xif.issue_req.rs[1]    = cpi_x_rs2;
    assign vcore_xif.issue_req.rs_valid = 2'b11;

    assign cpi_instr_gnt     = vcore_xif.issue_ready;
    assign cpi_instr_illegal = ~vcore_xif.issue_resp.accept;
    assign cpi_xreg_wait     = vcore_xif.issue_resp.writeback;

    assign vcore_xif.commit_valid       = cpi_commit_q;
    assign vcore_xif.commit.id          = cpi_instr_id_q2;
    assign vcore_xif.commit.commit_kill = 1'b0;

    assign vcore_xif.result_ready = 1'b1;
    assign cpi_result_valid       = vcore_xif.result_valid & vcore_xif.result.we;
    assign cpi_xreg               = vcore_xif.result.data;


    ///////////////////////////////////////////////////////////////////////////
    // VECTOR CORE INTEGRATION

    // Vector CSR read/write conversion
    logic [31:0] csr_vtype;
    logic [31:0] csr_vl;
    logic [31:0] csr_vlenb;
    logic [31:0] csr_vstart_rd;
    logic [31:0] csr_vstart_wr;
    logic        csr_vstart_wren;
    logic        csr_vxsat_rd;
    logic        csr_vxsat_wr;
    logic        csr_vxsat_wren;
    logic [1:0]  csr_vxrm_rd;
    logic [1:0]  csr_vxrm_wr;
    logic        csr_vxrm_wren;
    assign vect_csr_rdata[0] = csr_vstart_rd;
    assign vect_csr_rdata[1] = {31'b0, csr_vxsat_rd};
    assign vect_csr_rdata[2] = {30'b0, csr_vxrm_rd};
    assign vect_csr_rdata[3] = {29'b0, csr_vxrm_rd, csr_vxsat_rd};
    assign vect_csr_rdata[4] = csr_vl;
    assign vect_csr_rdata[5] = csr_vtype;
    assign vect_csr_rdata[6] = csr_vlenb;
    assign csr_vstart_wr     = vect_csr_wdata[0];
    assign csr_vstart_wren   = vect_csr_we[0];
    assign csr_vxsat_wr      = vect_csr_we[1] ? vect_csr_wdata[1][0]   : vect_csr_wdata[3][0];
    assign csr_vxsat_wren    = vect_csr_we[1] | vect_csr_we[3];
    assign csr_vxrm_wr       = vect_csr_we[2] ? vect_csr_wdata[2][1:0] : vect_csr_wdata[3][2:1];
    assign csr_vxrm_wren     = vect_csr_we[2] | vect_csr_we[3];

    // Data read/write for Vector Unit
    logic                vdata_gnt;
    logic                vdata_rvalid;
    logic                vdata_err;
    logic [VMEM_W-1:0]   vdata_rdata;
    logic                vdata_req;
    logic [31:0]         vdata_addr;
    logic                vdata_we;
    logic [VMEM_W/8-1:0] vdata_be;
    logic [VMEM_W-1:0]   vdata_wdata;
    logic [X_ID_WIDTH-1:0] vdata_req_id;
    logic [X_ID_WIDTH-1:0] vdata_res_id;

    localparam bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS = (VLSU_FLAGS_W'(1) << VLSU_ALIGNED_UNITSTRIDE);

    localparam bit [BUF_FLAGS_W -1:0] BUF_FLAGS  = (BUF_FLAGS_W'(1) << BUF_DEQUEUE  ) |
                                                   (BUF_FLAGS_W'(1) << BUF_VREG_PEND);

    vproc_core #(
        .XIF_ID_W           ( X_ID_WIDTH         ),
        .XIF_MEM_W          ( VMEM_W             ),
        .VREG_TYPE          ( VREG_TYPE          ),
        .MUL_TYPE           ( MUL_TYPE           ),
        .VLSU_FLAGS         ( VLSU_FLAGS         ),
        .BUF_FLAGS          ( BUF_FLAGS          ),
        .DONT_CARE_ZERO     ( 1'b0               ),
        .ASYNC_RESET        ( 1'b0               )
    ) v_core (
        .clk_i              ( clk_i              ),
        .rst_ni             ( sync_rst_n         ),

        .xif_issue_if       ( vcore_xif          ),
        .xif_commit_if      ( vcore_xif          ),
        .xif_mem_if         ( vcore_xif          ),
        .xif_memres_if      ( vcore_xif          ),
        .xif_result_if      ( vcore_xif          ),

        .pending_load_o     ( vect_pending_load  ),
        .pending_store_o    ( vect_pending_store ),

        .csr_vtype_o        ( csr_vtype          ),
        .csr_vl_o           ( csr_vl             ),
        .csr_vlenb_o        ( csr_vlenb          ),
        .csr_vstart_o       ( csr_vstart_rd      ),
        .csr_vstart_i       ( csr_vstart_wr      ),
        .csr_vstart_set_i   ( csr_vstart_wren    ),
        .csr_vxrm_o         ( csr_vxrm_rd        ),
        .csr_vxrm_i         ( csr_vxrm_wr        ),
        .csr_vxrm_set_i     ( csr_vxrm_wren      ),
        .csr_vxsat_o        ( csr_vxsat_rd       ),
        .csr_vxsat_i        ( csr_vxsat_wr       ),
        .csr_vxsat_set_i    ( csr_vxsat_wren     )
    );

    // Extract vector unit memory signals from extension interface
    if (USE_XIF_MEM) begin
        assign vdata_req                  = '0;
        assign vdata_addr                 = '0;
        assign vdata_we                   = '0;
        assign vdata_be                   = '0;
        assign vdata_wdata                = '0;
        assign vdata_req_id               = '0;
    end else begin
        assign vdata_req                  = vcore_xif.mem_valid;
        assign vcore_xif.mem_ready        = vdata_gnt;
        assign vdata_addr                 = vcore_xif.mem_req.addr;
        assign vdata_we                   = vcore_xif.mem_req.we;
        assign vdata_be                   = vcore_xif.mem_req.be;
        assign vdata_wdata                = vcore_xif.mem_req.wdata;
        assign vdata_req_id               = vcore_xif.mem_req.id;
        assign vcore_xif.mem_resp.exc     = '0;
        assign vcore_xif.mem_resp.exccode = '0;
        assign vcore_xif.mem_resp.dbg     = '0;
        assign vcore_xif.mem_result_valid = vdata_rvalid;
        assign vcore_xif.mem_result.id    = vdata_res_id;
        assign vcore_xif.mem_result.rdata = vdata_rdata;
        assign vcore_xif.mem_result.err   = vdata_err;
        assign vcore_xif.mem_result.dbg   = '0;
    end

    // Data arbiter for main core and vector unit
    logic                sdata_hold;
    logic                data_req;
    logic [31:0]         data_addr;
    logic                data_we;
    logic [VMEM_W/8-1:0] data_be;
    logic [VMEM_W  -1:0] data_wdata;
    logic                data_gnt;
    logic                data_rvalid;
    logic                data_err;
    logic [VMEM_W  -1:0] data_rdata;
    logic                sdata_waiting, vdata_waiting;
    logic [31:0]         sdata_wait_addr;
    logic [X_ID_WIDTH-1:0] vdata_wait_id;

    // Vector unit stores are always prioritized over all scalar transactions
    // Vector unit loads are prioritized over scalar stores
    assign sdata_hold = ~USE_XIF_MEM & (vdata_req | vect_pending_store | (vect_pending_load & sdata_we));
    // Combine vector and scalar signals into the output data signals
    always_comb begin
        data_req   = vdata_req | (sdata_req & ~sdata_hold);
        data_addr  = sdata_addr;
        data_we    = sdata_we;
        data_be    = {{(VMEM_W-32){1'b0}}, sdata_be} << (sdata_addr[$clog2(VMEM_W/8)-1:0] & {{$clog2(VMEM_W/32){1'b1}}, 2'b00});
        data_wdata = '0;
        for (int i = 0; i < VMEM_W / 32; i++) begin
            data_wdata[32*i +: 32] = sdata_wdata;
        end
        if (vdata_req) begin
            data_addr  = vdata_addr;
            data_we    = vdata_we;
            data_be    = vdata_be;
            data_wdata = vdata_wdata;
        end
    end

    // Data arbiter state machine
    // Vector requests are always granted when memory access is granted
    // Scalar requests are granted when no vector request is pending (~sdata_hold)
    assign sdata_gnt = data_gnt & sdata_req & ~sdata_hold;
    assign vdata_gnt = data_gnt & vdata_req;

    // Number of words transmitted per vector transaction (Vector Register length / Vector Memory width (usually 32 bit))
    localparam int WordsPerVTrans = vproc_config::VREG_W / VMEM_W;
    logic [5:0] vdata_counter;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        // Reset state machine on reset
        if (~rst_ni) begin
            sdata_waiting   <= 1'b0;
            vdata_waiting   <= 1'b0;
            sdata_wait_addr <= '0;
            vdata_wait_id   <= '0;
            vdata_counter   <= 2'b0;
        end else begin
            if (sdata_gnt) begin
                sdata_waiting   <= 1'b1;
                sdata_wait_addr <= sdata_addr;
            end
            else if (sdata_rvalid) begin
                sdata_waiting <= 1'b0;
            end

            // Vector transaction is started directly when granted
            if (vdata_gnt & ~vdata_waiting) begin
                vdata_waiting <= 1'b1;
                vdata_wait_id <= vdata_req_id;
            end
            if (vdata_rvalid & vdata_waiting) begin
                // Count the number of words received for vector reads
                vdata_counter <= vdata_counter + 1;

                // Reset counter, when all words are received
                // If granted start the next transaction immediately
                if (vdata_counter == (WordsPerVTrans-1)) begin
                    vdata_waiting <= vdata_gnt;
                    if (vdata_gnt) begin
                        vdata_wait_id <= vdata_req_id;
                    end
                    vdata_counter <= 2'b0;
                end
            end
        end
    end

    // If not waiting for vector data, received data is scalar
    assign sdata_rvalid = ~vdata_waiting & data_rvalid;
    // Received data is vector data when vdata_waiting
    assign vdata_rvalid = vdata_waiting & data_rvalid;
    assign sdata_err    = data_err;
    assign vdata_err    = data_err;
    assign sdata_rdata  = data_rdata[(sdata_wait_addr[$clog2(VMEM_W)-1:0] & {3'b000, {($clog2(VMEM_W/8)-2){1'b1}}, 2'b00})*8 +: 32];
    assign vdata_rdata  = data_rdata;
    assign vdata_res_id = vdata_wait_id;


    assign data_req_o    = data_req;
    assign data_addr_o   = data_addr;
    assign data_we_o     = data_we;
    assign data_be_o     = data_be;
    assign data_wdata_o  = data_wdata;
    assign data_gnt      = data_gnt_i;
    assign data_rvalid   = data_rvalid_i;
    assign data_rdata    = data_rdata_i;
    assign data_err      = data_err_i;
endmodule
