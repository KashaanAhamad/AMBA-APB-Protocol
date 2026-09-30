// =============================================================================
// File:    apb_assertions.sv
// Purpose: SVA (SystemVerilog Assertion) protocol checks for the APB bus.
//
//          This module contains concurrent assertions that continuously
//          monitor the APB bus signals and flag any protocol violations.
//          These are formal rules from the AMBA APB specification, encoded
//          as properties and assertions.
//
// Connection:
//          Instantiated in apb_tb_top.sv with internal DUT signals connected
//          via hierarchical references. The assertions fire on every posedge
//          of pclk and are disabled during reset (presetn=0).
//
// Assertion List:
//   APB_A01 — SETUP always followed by ACCESS (PENABLE rises)
//   APB_A02 — PADDR stable during wait states
//   APB_A03 — PWRITE stable during wait states
//   APB_A04 — PSELx stable during wait states
//   APB_A05 — PWDATA stable during write wait states
//   APB_A06 — PENABLE deasserted after transfer completion
//   APB_A07 — SETUP lasts exactly 1 clock cycle
//   APB_A08 — PSLVERR only valid when PSEL & PENABLE & PREADY
//   APB_A09 — No X/Z values on bus during active transfers
//   APB_A10 — Reset brings FSM to IDLE
//   APB_A11 — Decoder output is one-hot or zero (at most 1 slave selected)
//   APB_A12 — Back-to-back: ACCESS→SETUP when transfer_req during completion
//
// Statistics:
//   Pass/fail counts are tracked and reported at end of simulation.
// =============================================================================

module apb_assertions (
    // Clock & Reset
    input logic        pclk,
    input logic        presetn,

    // Master bus outputs
    input logic [31:0] paddr,
    input logic        master_psel,      // Master's aggregate PSELx
    input logic        penable,
    input logic        pwrite,
    input logic [31:0] pwdata,

    // Decoder output
    input logic [2:0]  decoded_psel,     // One-hot slave select

    // Muxed slave response
    input logic [31:0] prdata,
    input logic        pready,
    input logic        pslverr,

    // FSM state
    input logic [1:0]  current_state,

    // Transfer request (from testbench)
    input logic        transfer_req
);

    // =========================================================================
    // State Encoding (must match apb_master_fsm parameters)
    // =========================================================================
    localparam logic [1:0] IDLE   = 2'b00;
    localparam logic [1:0] SETUP  = 2'b01;
    localparam logic [1:0] ACCESS = 2'b10;

    // =========================================================================
    // Helper Signals
    // =========================================================================
    // Derived signals to make properties more readable.
    // =========================================================================
    wire setup_phase   = master_psel & ~penable;    // SETUP:  PSELx=1, PENABLE=0
    wire access_phase  = master_psel &  penable;    // ACCESS: PSELx=1, PENABLE=1
    wire access_wait   = access_phase & ~pready;    // ACCESS with wait state
    wire access_done   = access_phase &  pready;    // ACCESS complete
    wire write_access  = access_phase &  pwrite;    // Write in ACCESS phase

    // =========================================================================
    // Statistics Tracking
    // =========================================================================
    int unsigned assert_pass_count = 0;
    int unsigned assert_fail_count = 0;


    // =========================================================================
    //  APB_A01 — SETUP Must Be Followed By ACCESS
    // =========================================================================
    // APB Spec Rule: After the master asserts PSELx (enters SETUP phase),
    // PENABLE must be asserted on the very next clock cycle (ACCESS phase).
    //
    // In other words: if we see SETUP (psel=1, penable=0), then on the
    // next posedge pclk, penable MUST be HIGH (with psel still HIGH).
    // =========================================================================
    property p_setup_followed_by_access;
        @(posedge pclk) disable iff (!presetn)
        setup_phase |=> access_phase;
    endproperty

    APB_A01: assert property (p_setup_followed_by_access)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A01] FAIL @ %0t: SETUP not followed by ACCESS. psel=%0b penable=%0b",
               $time, master_psel, penable);
    end


    // =========================================================================
    //  APB_A02 — PADDR Must Be Stable During Wait States
    // =========================================================================
    // APB Spec Rule: Once a transfer enters ACCESS phase, PADDR must not
    // change until the transfer completes (PREADY=1). If the slave inserts
    // wait states (PREADY=0), PADDR must remain stable.
    // =========================================================================
    property p_paddr_stable_during_wait;
        @(posedge pclk) disable iff (!presetn)
        access_wait |=> $stable(paddr);
    endproperty

    APB_A02: assert property (p_paddr_stable_during_wait)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A02] FAIL @ %0t: PADDR changed during wait state. paddr=0x%08h",
               $time, paddr);
    end


    // =========================================================================
    //  APB_A03 — PWRITE Must Be Stable During Wait States
    // =========================================================================
    // APB Spec Rule: PWRITE must not change once the ACCESS phase begins,
    // until the transfer completes.
    // =========================================================================
    property p_pwrite_stable_during_wait;
        @(posedge pclk) disable iff (!presetn)
        access_wait |=> $stable(pwrite);
    endproperty

    APB_A03: assert property (p_pwrite_stable_during_wait)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A03] FAIL @ %0t: PWRITE changed during wait state. pwrite=%0b",
               $time, pwrite);
    end


    // =========================================================================
    //  APB_A04 — PSELx Must Be Stable During Wait States
    // =========================================================================
    // APB Spec Rule: The slave select (PSELx) must not change during
    // the ACCESS phase while PREADY=0.
    // =========================================================================
    property p_psel_stable_during_wait;
        @(posedge pclk) disable iff (!presetn)
        access_wait |=> $stable(master_psel);
    endproperty

    APB_A04: assert property (p_psel_stable_during_wait)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A04] FAIL @ %0t: PSELx changed during wait state. psel=%0b",
               $time, master_psel);
    end


    // =========================================================================
    //  APB_A05 — PWDATA Must Be Stable During Write Wait States
    // =========================================================================
    // APB Spec Rule: During a write transfer, PWDATA must remain stable
    // throughout the ACCESS phase until PREADY=1.
    // =========================================================================
    property p_pwdata_stable_during_write_wait;
        @(posedge pclk) disable iff (!presetn)
        (access_wait && pwrite) |=> $stable(pwdata);
    endproperty

    APB_A05: assert property (p_pwdata_stable_during_write_wait)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A05] FAIL @ %0t: PWDATA changed during write wait state. pwdata=0x%08h",
               $time, pwdata);
    end


    // =========================================================================
    //  APB_A06 — PENABLE Deasserted After Transfer Completion
    // =========================================================================
    // APB Spec Rule: When a transfer completes (ACCESS with PREADY=1),
    // PENABLE must be deasserted on the next cycle — either returning to
    // IDLE (penable=0, psel=0) or starting a new SETUP (penable=0, psel=1).
    // =========================================================================
    property p_penable_deassert_after_done;
        @(posedge pclk) disable iff (!presetn)
        access_done |=> !penable;
    endproperty

    APB_A06: assert property (p_penable_deassert_after_done)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A06] FAIL @ %0t: PENABLE not deasserted after transfer completion.",
               $time);
    end


    // =========================================================================
    //  APB_A07 — SETUP Phase Lasts Exactly 1 Clock Cycle
    // =========================================================================
    // APB Spec Rule: The SETUP phase (PSELx=1, PENABLE=0) always lasts
    // exactly one clock cycle. The FSM must transition to ACCESS on the
    // very next cycle. There is no "extended SETUP" in the APB protocol.
    //
    // This is essentially the same check as APB_A01 viewed from the FSM
    // state perspective.
    // =========================================================================
    property p_setup_one_cycle;
        @(posedge pclk) disable iff (!presetn)
        (current_state == SETUP) |=> (current_state == ACCESS);
    endproperty

    APB_A07: assert property (p_setup_one_cycle)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A07] FAIL @ %0t: SETUP state lasted more than 1 cycle. state=%0b",
               $time, current_state);
    end


    // =========================================================================
    //  APB_A08 — PSLVERR Only Valid When PSEL & PENABLE & PREADY
    // =========================================================================
    // APB Spec Rule: PSLVERR is only meaningful (and should only be asserted)
    // when all three conditions are true: PSELx=1, PENABLE=1, PREADY=1.
    // At all other times, the master ignores PSLVERR.
    //
    // We check the converse: if PSLVERR is HIGH, then PSEL, PENABLE, and
    // PREADY must all be HIGH.
    // =========================================================================
    property p_pslverr_valid_window;
        @(posedge pclk) disable iff (!presetn)
        pslverr |-> (master_psel && penable && pready);
    endproperty

    APB_A08: assert property (p_pslverr_valid_window)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A08] FAIL @ %0t: PSLVERR asserted outside valid window. psel=%0b penable=%0b pready=%0b",
               $time, master_psel, penable, pready);
    end


    // =========================================================================
    //  APB_A09 — No X/Z Values On Bus During Active Transfers
    // =========================================================================
    // Design Rule: During any active transfer (PSELx=1), there must be no
    // unknown (X) or high-impedance (Z) values on the bus control signals.
    // This catches simulation-only issues like uninitialized registers or
    // unconnected ports.
    // =========================================================================
    property p_no_unknown_paddr;
        @(posedge pclk) disable iff (!presetn)
        master_psel |-> !$isunknown(paddr);
    endproperty

    property p_no_unknown_pwrite;
        @(posedge pclk) disable iff (!presetn)
        master_psel |-> !$isunknown(pwrite);
    endproperty

    property p_no_unknown_penable;
        @(posedge pclk) disable iff (!presetn)
        master_psel |-> !$isunknown(penable);
    endproperty

    property p_no_unknown_pwdata_on_write;
        @(posedge pclk) disable iff (!presetn)
        (master_psel && pwrite) |-> !$isunknown(pwdata);
    endproperty

    APB_A09_ADDR: assert property (p_no_unknown_paddr)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A09] FAIL @ %0t: X/Z detected on PADDR during active transfer.", $time);
    end

    APB_A09_WRITE: assert property (p_no_unknown_pwrite)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A09] FAIL @ %0t: X/Z detected on PWRITE during active transfer.", $time);
    end

    APB_A09_EN: assert property (p_no_unknown_penable)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A09] FAIL @ %0t: X/Z detected on PENABLE during active transfer.", $time);
    end

    APB_A09_WDATA: assert property (p_no_unknown_pwdata_on_write)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A09] FAIL @ %0t: X/Z detected on PWDATA during write transfer.", $time);
    end


    // =========================================================================
    //  APB_A10 — Reset Brings FSM To IDLE
    // =========================================================================
    // Design Rule: When PRESETn is deasserted (active-low reset), the
    // FSM must be in the IDLE state on the very next rising clock edge.
    // =========================================================================
    property p_reset_to_idle;
        @(posedge pclk)
        !presetn |=> (current_state == IDLE);
    endproperty

    APB_A10: assert property (p_reset_to_idle)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A10] FAIL @ %0t: FSM not in IDLE after reset. state=%0b",
               $time, current_state);
    end


    // =========================================================================
    //  APB_A11 — Decoder Output Must Be One-Hot or Zero
    // =========================================================================
    // Design Rule: The address decoder output (decoded_psel) must select
    // at most ONE slave at any time. Multiple slaves selected simultaneously
    // would cause bus contention.
    //
    // $onehot0() returns true if at most one bit is set (including all-zero).
    // =========================================================================
    property p_psel_onehot0;
        @(posedge pclk) disable iff (!presetn)
        $onehot0(decoded_psel);
    endproperty

    APB_A11: assert property (p_psel_onehot0)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A11] FAIL @ %0t: decoded_psel not one-hot! decoded_psel=%03b",
               $time, decoded_psel);
    end


    // =========================================================================
    //  APB_A12 — Back-to-Back: ACCESS Completion With Pending Request
    // =========================================================================
    // Design Rule: When a transfer completes (ACCESS with PREADY=1) and
    // there is a pending transfer_req, the FSM must go directly to SETUP
    // (back-to-back) rather than returning to IDLE.
    //
    // This verifies the ACCESS→SETUP shortcut path in the master FSM.
    // =========================================================================
    property p_back_to_back_transition;
        @(posedge pclk) disable iff (!presetn)
        (access_done && transfer_req) |=> (current_state == SETUP);
    endproperty

    APB_A12: assert property (p_back_to_back_transition)
        assert_pass_count++;
    else begin
        assert_fail_count++;
        $error("[APB_A12] FAIL @ %0t: Back-to-back failed. Expected SETUP after ACCESS+req, got state=%0b",
               $time, current_state);
    end


    // =========================================================================
    // Cover Properties (for coverage, not checking)
    // =========================================================================
    // These are NOT assertions — they track whether specific interesting
    // protocol scenarios were observed during simulation. Useful for
    // confirming that the testbench actually exercised these paths.
    // =========================================================================

    // Cover: A normal write transfer completed successfully
    cover_write_done: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && pwrite && !pslverr
    );

    // Cover: A normal read transfer completed successfully
    cover_read_done: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && !pwrite && !pslverr
    );

    // Cover: A transfer completed with an error
    cover_error_transfer: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && pslverr
    );

    // Cover: A wait state was inserted (slave held PREADY=0)
    cover_wait_state: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_wait
    );

    // Cover: Back-to-back transfer occurred (ACCESS→SETUP)
    cover_back_to_back: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && transfer_req
    );

    // Cover: Transfer to each slave
    cover_slave0: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && decoded_psel == 3'b001
    );

    cover_slave1: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && decoded_psel == 3'b010
    );

    cover_slave2: cover property (
        @(posedge pclk) disable iff (!presetn)
        access_done && decoded_psel == 3'b100
    );


    // =========================================================================
    // End-of-Simulation Report
    // =========================================================================
    // Called via $finish or final block — prints assertion pass/fail summary.
    // =========================================================================
    final begin
        $display("");
        $display("╔══════════════════════════════════════════════════════╗");
        $display("║          SVA Assertion Summary                       ║");
        $display("╠══════════════════════════════════════════════════════╣");
        $display("║  Assertion Passes : %8d                              ║", assert_pass_count);
        $display("║  Assertion Fails  : %8d                              ║", assert_fail_count);
        $display("╠══════════════════════════════════════════════════════╣");

        if (assert_fail_count == 0)
            $display("║   ALL ASSERTIONS PASSED                            ║");
        else
            $display("║   %0d ASSERTION(S) FAILED                         ║", assert_fail_count);

        $display("╚══════════════════════════════════════════════════════╝");
        $display("");
    end

endmodule

