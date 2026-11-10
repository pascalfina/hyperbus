// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "hyperbus/typedef.svh"
`include "common_cells/assertions.svh"

module hyperbus_synchronous #(
    parameter int unsigned  NumPhys               = 2,
    parameter int unsigned HostAddrWidth          = 32,
    parameter int unsigned HostDataWidth          = 32,
    parameter type         host_req_t             = logic,
    parameter type         host_rsp_t              = logic,
    parameter int unsigned  RegDataWidth          = 32,
    parameter int unsigned  RegAddrWidth          = 32,
    parameter type          reg_req_t             = logic,
    parameter type          reg_rsp_t             = logic,
    parameter type          rule_t                = logic,
    parameter int unsigned  HostWriteBufferBytes  = 64,
    parameter int unsigned  PhyStartupCycles      = 300 * 200,
    parameter int unsigned  SyncStages            = 2
) (
    input  logic                        clk_sys_i,
    input  logic                        rst_sys_ni,
`ifdef TARGET_XILINX
    input  logic                        clk_ref200_i,
`endif
    input  logic                        test_mode_i,

    input  host_req_t host_req_i,
    output host_rsp_t host_rsp_o,

    output logic drain_o,
    input  logic host_idle_i,

    input  reg_req_t                    reg_req_i,
    output reg_rsp_t                    reg_rsp_o,

    output logic [NumPhys-1:0][hyperbus_pkg::HyperNumChips-1:0] hyper_cs_no,
    output logic [NumPhys-1:0]               hyper_ck_o,
    output logic [NumPhys-1:0]               hyper_ck_no,
    output logic [NumPhys-1:0]               hyper_rwds_o,
    input  logic [NumPhys-1:0]               hyper_rwds_i,
    output logic [NumPhys-1:0]               hyper_rwds_oe_o,
    input  logic [NumPhys-1:0][7:0]          hyper_dq_i,
    output logic [NumPhys-1:0][7:0]          hyper_dq_o,
    output logic [NumPhys-1:0]               hyper_dq_oe_o,
    output logic [NumPhys-1:0]               hyper_reset_no

);
    typedef type(host_req_i.cmd)  host_cmd_t;
    typedef type(host_req_i.w)    host_w_t;
    typedef type(host_rsp_o.r)    host_r_t;
    typedef type(host_rsp_o.wrsp) host_wrsp_t;

    `HYPERBUS_TYPEDEF_LINK_ALL_CT(hyper, NumPhys)

    /////////////////////
    // Clock and reset //
    /////////////////////

    logic clk_backend;
    logic rst_backend_n;

    ////////////////////////
    // Configuration path //
    ////////////////////////

    hyperbus_pkg::phy_cfg_t    frontend_cfg_apply;
    logic                      frontend_cfg_apply_valid;
    logic                      frontend_cfg_apply_ready;
    logic                      frontend_cfg_apply_done;
    logic                      frontend_clock_div_apply_valid;
    hyperbus_pkg::phy_cfg_t    backend_cfg_apply;
    logic                      backend_cfg_apply_valid;
    logic                      backend_cfg_apply_ready;

    hyperbus_pkg::frontend_cfg_t frontend_cfg;
    rule_t [hyperbus_pkg::HyperNumChips-1:0] frontend_chip_rules;

    ////////////////////
    // Dataflow links //
    ////////////////////

    hyper_req_t               midend_req;
    hyper_rsp_t               midend_rsp;
    logic                     midend_trans_active;
    logic                     midend_decode_error;
    hyper_req_t               backend_req;
    hyper_rsp_t               backend_rsp;

    assign clk_backend = clk_sys_i;
    assign rst_backend_n = rst_sys_ni;

    // The synchronous top keeps the frontend/backend boundary visible without a bridge module.
    assign backend_cfg_apply        = frontend_cfg_apply;
    assign backend_cfg_apply_valid  = frontend_cfg_apply_valid;
    assign frontend_cfg_apply_ready = backend_cfg_apply_ready;
    assign frontend_cfg_apply_done  = frontend_cfg_apply_valid && backend_cfg_apply_ready;
    assign backend_req = midend_req;
    assign midend_rsp  = backend_rsp;

    ////////////////////////////
    // Configuration frontend //
    ////////////////////////////

    hyperbus_cfg_frontend #(
        .NumPhys       ( NumPhys       ),
        .reg_req_t     ( reg_req_t     ),
        .reg_rsp_t     ( reg_rsp_t     ),
        .host_rule_t   ( rule_t    ),
        .RegDataWidth  ( RegDataWidth  ),
        .RegAddrWidth  ( RegAddrWidth  )
    ) i_cfg_frontend (
        .clk_i              ( clk_sys_i                ),
        .rst_ni             ( rst_sys_ni               ),
        .reg_req_i          ( reg_req_i                ),
        .reg_rsp_o          ( reg_rsp_o                ),
        .drain_o            ( drain_o                  ),
        .host_idle_i        ( host_idle_i              ),
        .trans_active_i     ( midend_trans_active      ),
        .cfg_apply_o        ( frontend_cfg_apply       ),
        .cfg_apply_valid_o  ( frontend_cfg_apply_valid ),
        .cfg_apply_ready_i  ( frontend_cfg_apply_ready ),
        .cfg_apply_done_i   ( frontend_cfg_apply_done  ),
        .clock_div_apply_o       (                                ),
        .clock_div_apply_valid_o ( frontend_clock_div_apply_valid ),
        .clock_div_apply_ready_i ( 1'b1                           ),
        .clock_div_apply_done_i  ( frontend_clock_div_apply_valid ),
        .frontend_cfg_o     ( frontend_cfg             ),
        .chip_rules_o       ( frontend_chip_rules      ),
        .decode_error_i     ( midend_decode_error      )
    );


    ////////////
    // Midend //
    ////////////

    hyperbus_midend #(
        .HostAddrWidth        ( HostAddrWidth        ),
        .HostDataWidth        ( HostDataWidth        ),
        .NumPhys              ( NumPhys             ),
        .HostWriteBufferBytes ( HostWriteBufferBytes ),
        .host_cmd_t            ( host_cmd_t          ),
        .host_w_t              ( host_w_t            ),
        .host_r_t              ( host_r_t            ),
        .host_wrsp_t           ( host_wrsp_t         ),
        .host_req_t            ( host_req_t          ),
        .host_rsp_t            ( host_rsp_t          ),
        .hyper_rx_t            ( hyper_rx_t          ),
        .hyper_tx_t            ( hyper_tx_t          ),
        .hyper_cmd_t           ( hyper_cmd_t         ),
        .hyper_req_t           ( hyper_req_t         ),
        .hyper_rsp_t           ( hyper_rsp_t         ),
        .rule_t                ( rule_t              )
    ) i_midend (
        .clk_i             ( clk_sys_i              ),
        .rst_ni            ( rst_sys_ni             ),
        .host_link_req_i   ( host_req_i              ),
        .host_link_rsp_o   ( host_rsp_o              ),
        .frontend_cfg_i    ( frontend_cfg           ),
        .chip_rules_i      ( frontend_chip_rules    ),
        .trans_active_o    ( midend_trans_active    ),
        .decode_error_o    ( midend_decode_error    ),
        .hyper_link_req_o  ( midend_req             ),
        .hyper_link_rsp_i  ( midend_rsp             )
    );

    /////////////
    // Backend //
    /////////////

    hyperbus_backend #(
        .NumPhys          ( NumPhys           ),
        .StartupCycles    ( PhyStartupCycles  ),
        .SyncStages       ( SyncStages        ),
        .hyper_rx_t       ( hyper_rx_t        ),
        .hyper_tx_t       ( hyper_tx_t        ),
        .hyper_req_t      ( hyper_req_t       ),
        .hyper_rsp_t      ( hyper_rsp_t       )
    ) i_backend (
        .clk_i                  ( clk_backend           ),
        .rst_ni                 ( rst_backend_n         ),
`ifdef TARGET_XILINX
        .clk_ref200_i           ( clk_ref200_i          ),
`endif
        .test_mode_i            ( test_mode_i           ),
        .cfg_apply_i            ( backend_cfg_apply     ),
        .cfg_apply_valid_i      ( backend_cfg_apply_valid ),
        .cfg_apply_ready_o      ( backend_cfg_apply_ready ),
        .busy_o                 (                       ),
        .req_i                  ( backend_req           ),
        .rsp_o                  ( backend_rsp           ),
        .hyper_cs_no            ( hyper_cs_no           ),
        .hyper_ck_o             ( hyper_ck_o            ),
        .hyper_ck_no            ( hyper_ck_no           ),
        .hyper_rwds_o           ( hyper_rwds_o          ),
        .hyper_rwds_i           ( hyper_rwds_i          ),
        .hyper_rwds_oe_o        ( hyper_rwds_oe_o       ),
        .hyper_dq_i             ( hyper_dq_i            ),
        .hyper_dq_o             ( hyper_dq_o            ),
        .hyper_dq_oe_o          ( hyper_dq_oe_o         ),
        .hyper_reset_no         ( hyper_reset_no        )
    );

endmodule
