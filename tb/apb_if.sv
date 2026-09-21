// =============================================================================
// File:    apb_if.sv
// Purpose: SystemVerilog Interface for APB Protocol Verification.
//
//          Bundles ALL signals that connect the testbench to the DUT (apb_top),
//          plus internal APB bus signals that are exposed for monitoring and
//          protocol assertions.
//
// Signal Groups:
//   Group 1 — Transfer Request  (TB → DUT):  stimulus driven by the driver
//   Group 2 — Transfer Response (DUT → TB):  results observed by the monitor
//   Group 3 — Internal APB Bus  (observe-only): for protocol checking & coverage
//
// Clocking Blocks:
//   drv_cb  — used by the Driver  (outputs stimulus, samples responses)
//   mon_cb  — used by the Monitor (samples everything, drives nothing)
//
// Usage in TB Top:
//   1. Instantiate:  apb_if  apb_vif (.pclk(clk), .presetn(rst_n));
//   2. Connect DUT ports to apb_vif signals
//   3. Assign internal signals via hierarchical references:
//        assign apb_vif.paddr = u_dut.paddr;
//        assign apb_vif.current_state = u_dut.u_master.u_fsm.current_state;
//        ... etc.
// =============================================================================

interface apb_if (
    input logic pclk,
    input logic presetn
);

    // =========================================================================
    // Group 1: Transfer Request Signals (Testbench → DUT)
    // =========================================================================
    // These are the top-level inputs to apb_top. The Driver drives these
    // to initiate read/write transfers.
    // =========================================================================
    logic        transfer_req;
    logic [31:0] transfer_addr;
    logic        transfer_write;
    logic [31:0] transfer_wdata;

    // =========================================================================
    // Group 2: Transfer Response Signals (DUT → Testbench)
    // =========================================================================
    // These are the top-level outputs from apb_top. The Monitor observes
    // these to determine when a transfer completes and what the result is.
    // =========================================================================
    logic [31:0] transfer_rdata;
    logic        transfer_ready;
    logic        transfer_error;

    // =========================================================================
    // Group 3: Internal APB Bus Signals (Observe-Only)
    // =========================================================================
    // These are NOT ports of apb_top — they are internal wires within the DUT.
    // They are connected in apb_tb_top.sv using hierarchical references
    // (e.g., assign apb_vif.paddr = u_dut.paddr;).
    //
    // Purpose:
    //   - Monitor: observe actual APB protocol activity on the bus
    //   - Assertions: verify protocol rules (signal stability, timing, etc.)
    //   - Coverage: track FSM states, slave selection, wait states
    // =========================================================================

    // --- Master Bus Outputs (from apb_master) ---
    logic [31:0] paddr;           // Address bus
    logic        master_psel;     // Master's aggregate PSELx (1 during SETUP/ACCESS)
    logic        penable;         // HIGH during ACCESS phase
    logic        pwrite;          // 1=Write, 0=Read
    logic [31:0] pwdata;          // Write data bus

    // --- Decoder Output (from apb_decoder) ---
    logic [2:0]  decoded_psel;    // One-hot slave select: {slave2, slave1, slave0}

    // --- Muxed Slave Response (from apb_mux → apb_master) ---
    logic [31:0] prdata;          // Read data from selected slave
    logic        pready;          // Slave ready signal
    logic        pslverr;         // Slave error response

    // --- Master FSM State (from apb_master_fsm) ---
    logic [1:0]  current_state;   // 2'b00=IDLE, 2'b01=SETUP, 2'b10=ACCESS

    // =========================================================================
    // Clocking Block: Driver (drv_cb)
    // =========================================================================
    // Used by the Driver component to drive stimulus and sample responses.
    //
    // Timing:
    //   - Outputs are driven #1 AFTER the posedge (avoids race with DUT)
    //   - Inputs are sampled #1 BEFORE the posedge (setup time margin)
    //
    // The driver ONLY drives Group 1 (transfer request) signals.
    // The driver reads Group 2 (transfer response) signals to detect completion.
    // =========================================================================
    clocking drv_cb @(posedge pclk);
        default input #1 output #1;

        // Driven by the driver (stimulus)
        output transfer_req;
        output transfer_addr;
        output transfer_write;
        output transfer_wdata;

        // Sampled by the driver (response)
        input  transfer_rdata;
        input  transfer_ready;
        input  transfer_error;
    endclocking

    // =========================================================================
    // Clocking Block: Monitor (mon_cb)
    // =========================================================================
    // Used by the Monitor component — PURE observation, drives nothing.
    //
    // Samples ALL signals (external + internal) for protocol checking,
    // scoreboard comparison, and coverage collection.
    // =========================================================================
    clocking mon_cb @(posedge pclk);
        default input #1;

        // Group 1: Transfer request (observe what the driver sent)
        input transfer_req;
        input transfer_addr;
        input transfer_write;
        input transfer_wdata;

        // Group 2: Transfer response (observe DUT output)
        input transfer_rdata;
        input transfer_ready;
        input transfer_error;

        // Group 3: Internal APB bus signals
        input paddr;
        input master_psel;
        input penable;
        input pwrite;
        input pwdata;
        input decoded_psel;
        input prdata;
        input pready;
        input pslverr;
        input current_state;
    endclocking

    // =========================================================================
    // Modports
    // =========================================================================
    // Enforce access control — the Driver can only use drv_cb,
    // the Monitor can only use mon_cb. Both get access to pclk and presetn
    // for synchronization and reset detection.
    // =========================================================================
    modport DRIVER (
        clocking drv_cb,
        input    pclk,
        input    presetn
    );

    modport MONITOR (
        clocking mon_cb,
        input    pclk,
        input    presetn
    );

endinterface

