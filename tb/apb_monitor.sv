// =============================================================================
// File:    apb_monitor.sv
// Purpose: APB Testbench Monitor — passively observes bus activity.
//
//          The Monitor is a PASSIVE component — it NEVER drives any signal.
//          It watches the internal APB bus signals through the interface's
//          monitor clocking block (mon_cb) and reconstructs completed
//          transactions by detecting the SETUP and ACCESS protocol phases.
//
// How It Works:
//   1. Continuously sample all APB bus signals every posedge pclk
//   2. Detect SETUP phase:  master_psel=1, penable=0
//      → Capture address, write direction, write data
//   3. Detect ACCESS phase: master_psel=1, penable=1
//      → Count wait cycles (pready=0 cycles)
//   4. Detect Transfer Completion: master_psel=1, penable=1, pready=1
//      → Capture read data, error status
//      → Package into apb_transaction and send to scoreboard & coverage
//   5. Track statistics (total transfers, wait cycles, errors, etc.)
//
// Outputs (via Mailboxes):
//   scb_mbx → Scoreboard: for correctness checking
//   cov_mbx → Coverage:   for functional coverage sampling
//
// Key Design Decision: The monitor observes INTERNAL bus signals (paddr,
//   penable, pready, etc.) rather than the external transfer interface.
//   This allows protocol-level verification — we check what the DUT actually
//   puts on the APB bus, not just what it reports back.
// =============================================================================

class apb_monitor;

    // =========================================================================
    // Interface Handle
    // =========================================================================
    // Virtual interface — connects to the actual apb_if instance.
    // Uses the MONITOR modport (read-only access via mon_cb).
    // =========================================================================
    virtual apb_if.MONITOR vif;

    // =========================================================================
    // Mailboxes: Transaction Output
    // =========================================================================
    // Captured transactions are forwarded to two consumers:
    //   scb_mbx → Scoreboard (checks correctness)
    //   cov_mbx → Coverage collector (samples functional coverage)
    //
    // Both mailboxes receive a COPY of the transaction (via txn.copy())
    // to prevent downstream components from corrupting the monitor's data.
    // =========================================================================
    mailbox #(apb_transaction) scb_mbx;
    mailbox #(apb_transaction) cov_mbx;

    // =========================================================================
    // Statistics
    // =========================================================================
    int unsigned num_transfers;          // Total completed transfers observed
    int unsigned num_writes;             // Write transfers observed
    int unsigned num_reads;              // Read transfers observed
    int unsigned num_errors;             // Transfers with PSLVERR=1
    int unsigned total_wait_cycles;      // Sum of all wait cycles observed
    int unsigned max_wait_observed;      // Maximum wait cycles in a single transfer
    int unsigned num_b2b_transfers;      // Back-to-back transitions detected

    // =========================================================================
    // Internal State
    // =========================================================================
    int unsigned transfer_counter;       // Sequential ID assigned to each transfer
    bit          prev_was_access_done;   // Track back-to-back detection

    // =========================================================================
    // Constructor
    // =========================================================================
    function new(virtual apb_if.MONITOR vif,
                 mailbox #(apb_transaction) scb_mbx,
                 mailbox #(apb_transaction) cov_mbx);
        this.vif                = vif;
        this.scb_mbx            = scb_mbx;
        this.cov_mbx            = cov_mbx;
        this.num_transfers      = 0;
        this.num_writes         = 0;
        this.num_reads          = 0;
        this.num_errors         = 0;
        this.total_wait_cycles  = 0;
        this.max_wait_observed  = 0;
        this.num_b2b_transfers  = 0;
        this.transfer_counter   = 0;
        this.prev_was_access_done = 0;
    endfunction

    // =========================================================================
    // Task: run()
    // =========================================================================
    // Main monitor loop — runs forever (typically forked in the environment).
    //
    // State Machine (mirrors the DUT's APB protocol):
    //
    //   [WAIT_SETUP] ──(psel=1, penable=0)──→ [IN_SETUP]
    //                                              │
    //                                      capture addr/write/wdata
    //                                              │
    //                                              ▼
    //                                        [IN_ACCESS]
    //                                          │       │
    //                            (pready=0)────┘       └────(pready=1)
    //                            count wait              capture rdata/error
    //                                                    send to scb & cov
    //                                                          │
    //                                                          ▼
    //                                                   [WAIT_SETUP]
    // =========================================================================
    task run();
        apb_transaction txn;
        int unsigned    wait_count;
        bit             in_transfer;

        // ---------------------------------------------------------------
        // Wait for reset to deassert
        // ---------------------------------------------------------------
        $display("[MON] [%0t] Waiting for reset to deassert...", $time);
        @(posedge vif.presetn);
        @(vif.mon_cb);
        $display("[MON] [%0t] Reset deasserted. Monitor starting.", $time);

        // ---------------------------------------------------------------
        // Main observation loop
        // ---------------------------------------------------------------
        in_transfer = 0;
        wait_count  = 0;

        forever begin
            @(vif.mon_cb);

            // ===========================================================
            // Detect SETUP Phase: master_psel=1, penable=0
            // ===========================================================
            // This is the first cycle of a new APB transfer. The master
            // has asserted PSELx and driven PADDR, PWRITE, PWDATA.
            // PENABLE is still LOW (will go HIGH next cycle in ACCESS).
            // ===========================================================
            if (vif.mon_cb.master_psel && !vif.mon_cb.penable) begin

                // Create new transaction and capture SETUP-phase signals
                txn = new();
                txn.transfer_id = transfer_counter++;
                txn.start_time  = $time;
                txn.addr        = vif.mon_cb.paddr;
                txn.write       = vif.mon_cb.pwrite;
                txn.wdata       = vif.mon_cb.pwdata;

                // Determine which slave is selected from decoded PSELx
                case (vif.mon_cb.decoded_psel)
                    3'b001:  txn.slave_id = 0;
                    3'b010:  txn.slave_id = 1;
                    3'b100:  txn.slave_id = 2;
                    default: txn.slave_id = -1;   // No slave or invalid
                endcase

                // Detect back-to-back: if previous transfer just completed
                // and we immediately see a new SETUP, it's back-to-back
                if (prev_was_access_done) begin
                    num_b2b_transfers++;
                end

                in_transfer = 1;
                wait_count  = 0;
                prev_was_access_done = 0;

                $display("[MON] [%0t] SETUP detected: TXN #%0d %s addr=0x%08h slave=%0d",
                         $time, txn.transfer_id,
                         txn.write ? "WRITE" : "READ",
                         txn.addr, txn.slave_id);
            end

            // ===========================================================
            // Detect ACCESS Phase: master_psel=1, penable=1
            // ===========================================================
            else if (vif.mon_cb.master_psel && vif.mon_cb.penable && in_transfer) begin

                if (vif.mon_cb.pready) begin
                    // -------------------------------------------------
                    // Transfer COMPLETE: PREADY=1 in ACCESS phase
                    // -------------------------------------------------
                    // The slave has responded. Capture the response
                    // signals and send the completed transaction.
                    // -------------------------------------------------

                    txn.rdata       = vif.mon_cb.prdata;
                    txn.error       = vif.mon_cb.pslverr;
                    txn.ready       = 1'b1;
                    txn.end_time    = $time;
                    txn.wait_cycles = wait_count;

                    // Update statistics
                    num_transfers++;
                    if (txn.write) num_writes++;
                    else           num_reads++;
                    if (txn.error) num_errors++;

                    total_wait_cycles += wait_count;
                    if (wait_count > max_wait_observed)
                        max_wait_observed = wait_count;

                    // Log the completed transfer
                    $display("[MON] [%0t] ACCESS complete: TXN #%0d %s addr=0x%08h %s=%0h %s waits=%0d",
                             $time, txn.transfer_id,
                             txn.write ? "WR" : "RD",
                             txn.addr,
                             txn.write ? "wdata" : "rdata",
                             txn.write ? txn.wdata : txn.rdata,
                             txn.error ? "ERR" : "OK",
                             wait_count);

                    // Send COPIES to scoreboard and coverage
                    // (copies prevent downstream modification of our data)
                    scb_mbx.put(txn.copy());
                    cov_mbx.put(txn.copy());

                    // Mark state for back-to-back detection
                    in_transfer          = 0;
                    prev_was_access_done = 1;

                end
                else begin
                    // -------------------------------------------------
                    // Wait State: PREADY=0 in ACCESS phase
                    // -------------------------------------------------
                    // The slave is inserting a wait cycle. Stay in ACCESS
                    // and increment the wait counter.
                    // -------------------------------------------------
                    wait_count++;

                    // Verify signal stability during wait states
                    // (APB spec requires PADDR, PWRITE, PWDATA, PSELx
                    //  to remain stable while PREADY=0)
                    check_signal_stability(txn);
                end
            end

            // ===========================================================
            // IDLE: No active transfer
            // ===========================================================
            else begin
                if (in_transfer) begin
                    // Unexpected: we were in a transfer but PSELx dropped
                    // This could indicate a reset or protocol violation
                    $display("[MON] [%0t] WARNING: Transfer #%0d aborted (PSELx deasserted unexpectedly)",
                             $time, txn.transfer_id);
                    in_transfer = 0;
                end
                prev_was_access_done = 0;
            end
        end
    endtask

    // =========================================================================
    // Function: check_signal_stability()
    // =========================================================================
    // Verifies that bus signals remain stable during wait states (ACCESS
    // phase with PREADY=0). The APB spec requires PADDR, PWRITE, PWDATA,
    // and PSELx to be held constant by the master during wait insertion.
    //
    // This is a soft check (prints warning, doesn't halt simulation).
    // The SVA assertions in apb_assertions.sv provide the hard check.
    // =========================================================================
    function void check_signal_stability(apb_transaction txn);
        if (vif.mon_cb.paddr !== txn.addr) begin
            $display("[MON] [%0t] STABILITY VIOLATION: PADDR changed during wait! expected=0x%08h actual=0x%08h",
                     $time, txn.addr, vif.mon_cb.paddr);
        end

        if (vif.mon_cb.pwrite !== txn.write) begin
            $display("[MON] [%0t] STABILITY VIOLATION: PWRITE changed during wait! expected=%0b actual=%0b",
                     $time, txn.write, vif.mon_cb.pwrite);
        end

        if (txn.write && (vif.mon_cb.pwdata !== txn.wdata)) begin
            $display("[MON] [%0t] STABILITY VIOLATION: PWDATA changed during wait! expected=0x%08h actual=0x%08h",
                     $time, txn.wdata, vif.mon_cb.pwdata);
        end
    endfunction

    // =========================================================================
    // Task: wait_for_reset()
    // =========================================================================
    // Blocks until reset is asserted and then deasserted. Useful for
    // restarting the monitor after a mid-simulation reset.
    // =========================================================================
    task wait_for_reset();
        $display("[MON] [%0t] Waiting for reset assertion...", $time);
        @(negedge vif.presetn);
        $display("[MON] [%0t] Reset asserted. Monitor paused.", $time);
        @(posedge vif.presetn);
        @(vif.mon_cb);
        $display("[MON] [%0t] Reset deasserted. Monitor resuming.", $time);
    endtask

    // =========================================================================
    // Function: print_stats()
    // =========================================================================
    // Prints a summary of all bus activity observed during simulation.
    // =========================================================================
    function void print_stats();
        real avg_wait;

        if (num_transfers > 0)
            avg_wait = real'(total_wait_cycles) / real'(num_transfers);
        else
            avg_wait = 0.0;

        $display("");
        $display("╔══════════════════════════════════════════════════╗");
        $display("║            Monitor Statistics                    ║");
        $display("╠══════════════════════════════════════════════════╣");
        $display("║  Total Transfers   : %6d                       ║", num_transfers);
        $display("║  Writes            : %6d                       ║", num_writes);
        $display("║  Reads             : %6d                       ║", num_reads);
        $display("║  Errors (PSLVERR)  : %6d                       ║", num_errors);
        $display("║  Back-to-Back      : %6d                       ║", num_b2b_transfers);
        $display("║  Total Wait Cycles : %6d                       ║", total_wait_cycles);
        $display("║  Max Wait (single) : %6d                       ║", max_wait_observed);
        $display("║  Avg Wait/Transfer : %6.2f                       ║", avg_wait);
        $display("╚══════════════════════════════════════════════════╝");
        $display("");
    endfunction

endclass

