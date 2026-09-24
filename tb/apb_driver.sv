// =============================================================================
// File:    apb_driver.sv
// Purpose: APB Testbench Driver — converts transactions into pin-level stimulus.
//
//          The Driver is the "active" component that talks TO the DUT. It takes
//          apb_transaction objects from a mailbox and drives the transfer request
//          signals (transfer_req, transfer_addr, transfer_write, transfer_wdata)
//          through the interface's driver clocking block (drv_cb).
//
// How It Works:
//   1. Pull a transaction from the mailbox (blocking get)
//   2. Assert transfer_req=1 with addr/write/wdata on the interface
//   3. Hold addr/write/wdata STABLE until the transfer completes
//      (the master's combinational logic reads these directly in SETUP & ACCESS)
//   4. Wait for transfer_ready=1 (DUT signals transfer completion)
//   5. Capture response (rdata, error) back into the transaction
//   6. Optionally insert idle cycles between transfers
//   7. Repeat
//
// Important Protocol Note:
//   The apb_master module uses transfer_addr/transfer_write/transfer_wdata
//   COMBINATIONALLY in both SETUP and ACCESS states. Therefore, these signals
//   MUST remain stable from the cycle transfer_req is asserted until
//   transfer_ready goes HIGH. Only transfer_req itself can be deasserted
//   after one cycle.
//
// Back-to-Back Transfers:
//   When transfer_req is HIGH at the moment transfer_ready=1 in ACCESS state,
//   the master FSM goes ACCESS→SETUP (skipping IDLE). The driver supports
//   this via the drive_back_to_back_transfers() task.
// =============================================================================

class apb_driver ;

    // =========================================================================
    // Interface Handle
    // =========================================================================
    // Virtual interface — connects this class to the actual apb_if instance.
    // Must be set by the environment before calling run().
    // =========================================================================
    virtual apb_if.DRIVER vif;

    // =========================================================================
    // Mailbox: Transaction Input
    // =========================================================================
    // The test/environment puts transactions here; the driver consumes them.
    // Uses a blocking get(), so the driver waits if the mailbox is empty.
    // =========================================================================
    mailbox #(apb_transaction) drv_mbx;

    // =========================================================================
    // Configuration
    // =========================================================================
    int unsigned idle_cycles_between;    // Idle cycles to insert between transfers
                                         // 0 = back-to-back, 1+ = gap
    int unsigned transfer_count;         // Total transfers driven (auto-incremented)

    // =========================================================================
    // Statistics
    // =========================================================================
    int unsigned num_writes;             // Total write transfers driven
    int unsigned num_reads;              // Total read transfers driven
    int unsigned num_errors;             // Transfers that returned error
    int unsigned num_timeouts;           // Transfers that timed out

    // =========================================================================
    // Timeout Configuration
    // =========================================================================
    // Maximum clock cycles to wait for transfer_ready. If exceeded, the
    // driver reports a TIMEOUT error and moves on. This prevents hangs
    // if the DUT is stuck.
    // =========================================================================
    int unsigned max_wait_cycles;

    // =========================================================================
    // Constructor
    // =========================================================================
    function new(virtual apb_if.DRIVER vif, mailbox #(apb_transaction) mbx);
        this.vif                   = vif;
        this.drv_mbx               = mbx;
        this.idle_cycles_between   = 0;        // Default: no idle gap
        this.transfer_count        = 0;
        this.num_writes            = 0;
        this.num_reads             = 0;
        this.num_errors            = 0;
        this.num_timeouts          = 0;
        this.max_wait_cycles       = 100;      // Default timeout: 100 cycles
    endfunction

    // =========================================================================
    // Task: run()
    // =========================================================================
    // Main driver loop — runs forever (typically forked in the environment).
    // Pulls transactions from the mailbox one at a time and drives them.
    //
    // Flow:
    //   1. Wait for reset to deassert (presetn=1)
    //   2. Loop: get txn → drive → insert idle gap → repeat
    // =========================================================================
    task run();
        apb_transaction txn;

        // ---------------------------------------------------------------
        // Wait for reset to deassert
        // ---------------------------------------------------------------
        $display("[DRV] [%0t] Waiting for reset to deassert...", $time);
        @(posedge vif.presetn);
        // Let the DUT settle for 1 cycle after reset release
        @(vif.drv_cb);
        $display("[DRV] [%0t] Reset deasserted. Driver starting.", $time);

        // ---------------------------------------------------------------
        // Initialize all outputs to idle state
        // ---------------------------------------------------------------
        drive_idle();

        // ---------------------------------------------------------------
        // Main loop: pull from mailbox and drive
        // ---------------------------------------------------------------
        forever begin
            drv_mbx.get(txn);
            drive_single_transfer(txn);

            // Insert configurable idle gap between transfers
            repeat (idle_cycles_between) begin
                @(vif.drv_cb);
            end
        end
    endtask

    // =========================================================================
    // Task: drive_single_transfer()
    // =========================================================================
    // Drives a single APB transfer through the DUT's transfer interface.
    //
    // Protocol Sequence:
    //   Cycle 0: Assert transfer_req=1, drive addr/write/wdata
    //   Cycle 1: Deassert transfer_req=0 (addr/write/wdata remain stable)
    //            Master enters SETUP → ACCESS
    //   Cycle N: Wait for transfer_ready=1 (ACCESS complete)
    //            Capture rdata and error
    //   Cycle N+1: Return to idle
    //
    // IMPORTANT: transfer_addr, transfer_write, transfer_wdata are held stable
    //            from assertion until transfer_ready, because the master reads
    //            them combinationally in SETUP and ACCESS states.
    // =========================================================================
    task drive_single_transfer(apb_transaction txn);
        int wait_count;

        // Assign unique transfer ID
        txn.transfer_id = transfer_count;
        transfer_count++;

        // Record start time
        txn.start_time = $time;

        // ---------------------------------------------------------------
        // Cycle 0: Assert transfer request
        // ---------------------------------------------------------------
        // Drive all transfer signals. The master FSM sees transfer_req=1
        // in IDLE and transitions to SETUP on the next posedge.
        // ---------------------------------------------------------------
        @(vif.drv_cb);
        vif.drv_cb.transfer_req   <= 1'b1;
        vif.drv_cb.transfer_addr  <= txn.addr;
        vif.drv_cb.transfer_write <= txn.write;
        vif.drv_cb.transfer_wdata <= txn.wdata;

        // ---------------------------------------------------------------
        // Cycle 1+: Deassert transfer_req, hold addr/write/wdata stable,
        //           wait for transfer_ready
        // ---------------------------------------------------------------
        // After 1 cycle, deassert transfer_req so the master knows there's
        // no NEXT pending transfer (prevents unintended back-to-back).
        // BUT keep addr/write/wdata stable — the master uses them
        // combinationally until the ACCESS phase completes.
        // ---------------------------------------------------------------
        wait_count = 0;
        forever begin
            @(vif.drv_cb);
            vif.drv_cb.transfer_req <= 1'b0;   // Deassert req (one-shot pulse)

            // Check for transfer completion
            if (vif.drv_cb.transfer_ready) begin
                break;
            end

            // Timeout protection
            wait_count++;
            if (wait_count >= max_wait_cycles) begin
                $display("[DRV] [%0t] ERROR: Transfer #%0d TIMEOUT after %0d cycles!",
                         $time, txn.transfer_id, max_wait_cycles);
                $display("[DRV]        addr=0x%08h %s", txn.addr,
                         txn.write ? "WRITE" : "READ");
                num_timeouts++;
                break;
            end
        end

        // ---------------------------------------------------------------
        // Capture response
        // ---------------------------------------------------------------
        txn.rdata    = vif.drv_cb.transfer_rdata;
        txn.error    = vif.drv_cb.transfer_error;
        txn.ready    = 1'b1;
        txn.end_time = $time;

        // ---------------------------------------------------------------
        // Update statistics
        // ---------------------------------------------------------------
        if (txn.write) num_writes++;
        else           num_reads++;
        if (txn.error) num_errors++;

        // ---------------------------------------------------------------
        // Return bus to idle
        // ---------------------------------------------------------------
        drive_idle();

    endtask

    // =========================================================================
    // Task: drive_back_to_back_transfers()
    // =========================================================================
    // Drives multiple transfers without any idle gap between them.
    // Achieves the ACCESS→SETUP (back-to-back) FSM transition by asserting
    // the NEXT transfer_req at the exact cycle when transfer_ready goes HIGH.
    //
    // Usage:
    //   apb_transaction txns[$];
    //   // ... populate txns queue ...
    //   driver.drive_back_to_back_transfers(txns);
    //
    // Protocol Sequence (2 transfers, A then B):
    //   Cycle 0: Assert req=1 with A's signals        → IDLE→SETUP(A)
    //   Cycle 1: Deassert req, hold A's signals       → SETUP(A)→ACCESS(A)
    //   Cycle N: transfer_ready=1, assert req=1       → ACCESS(A)→SETUP(B)
    //            with B's signals simultaneously
    //   Cycle N+1: Deassert req, hold B's signals     → SETUP(B)→ACCESS(B)
    //   Cycle M: transfer_ready=1, req=0              → ACCESS(B)→IDLE
    // =========================================================================
    task drive_back_to_back_transfers(ref apb_transaction txns[$]);
        int wait_count;

        if (txns.size() == 0) return;

        // ---------------------------------------------------------------
        // Drive first transfer: assert req and wait for ACCESS phase
        // ---------------------------------------------------------------
        txns[0].transfer_id = transfer_count++;
        txns[0].start_time  = $time;

        @(vif.drv_cb);
        vif.drv_cb.transfer_req   <= 1'b1;
        vif.drv_cb.transfer_addr  <= txns[0].addr;
        vif.drv_cb.transfer_write <= txns[0].write;
        vif.drv_cb.transfer_wdata <= txns[0].wdata;

        // ---------------------------------------------------------------
        // Process each transfer
        // ---------------------------------------------------------------
        for (int i = 0; i < txns.size(); i++) begin
            wait_count = 0;

            // Wait for this transfer to complete
            forever begin
                @(vif.drv_cb);

                if (vif.drv_cb.transfer_ready) begin
                    // Capture response for current transfer
                    txns[i].rdata    = vif.drv_cb.transfer_rdata;
                    txns[i].error    = vif.drv_cb.transfer_error;
                    txns[i].ready    = 1'b1;
                    txns[i].end_time = $time;

                    if (txns[i].write) num_writes++;
                    else               num_reads++;
                    if (txns[i].error) num_errors++;

                    // If there's a NEXT transfer, assert it NOW for back-to-back
                    if (i + 1 < txns.size()) begin
                        txns[i+1].transfer_id = transfer_count++;
                        txns[i+1].start_time  = $time;

                        vif.drv_cb.transfer_req   <= 1'b1;
                        vif.drv_cb.transfer_addr  <= txns[i+1].addr;
                        vif.drv_cb.transfer_write <= txns[i+1].write;
                        vif.drv_cb.transfer_wdata <= txns[i+1].wdata;
                    end
                    else begin
                        // Last transfer — go to idle
                        vif.drv_cb.transfer_req <= 1'b0;
                    end

                    break;
                end
                else begin
                    // Not ready yet — deassert req (it was a one-shot pulse)
                    vif.drv_cb.transfer_req <= 1'b0;
                end

                // Timeout protection
                wait_count++;
                if (wait_count >= max_wait_cycles) begin
                    $display("[DRV] [%0t] ERROR: B2B Transfer #%0d TIMEOUT!",
                             $time, txns[i].transfer_id);
                    num_timeouts++;
                    break;
                end
            end
        end

        // Ensure bus returns to idle after the last transfer
        @(vif.drv_cb);
        drive_idle();

    endtask

    // =========================================================================
    // Task: reset_driver()
    // =========================================================================
    // Called when a reset event is detected. Returns all driven signals to
    // their idle (inactive) state and resets internal state.
    // =========================================================================
    task reset_driver();
        $display("[DRV] [%0t] Reset detected. Returning to idle.", $time);
        drive_idle();
    endtask

    // =========================================================================
    // Task: drive_idle()
    // =========================================================================
    // Drives all transfer request signals to their inactive state.
    // Called after each transfer completes and during/after reset.
    // =========================================================================
    task drive_idle();
        vif.drv_cb.transfer_req   <= 1'b0;
        vif.drv_cb.transfer_addr  <= 32'h0;
        vif.drv_cb.transfer_write <= 1'b0;
        vif.drv_cb.transfer_wdata <= 32'h0;
    endtask

    // =========================================================================
    // Function: print_stats()
    // =========================================================================
    // Prints a summary of all transfers driven during the simulation.
    // =========================================================================
    function void print_stats();
        $display("");
        $display("╔══════════════════════════════════════════════╗");
        $display("║           Driver Statistics                  ║");
        $display("╠══════════════════════════════════════════════╣");
        $display("║  Total Transfers : %6d                       ║", transfer_count);
        $display("║  Writes          : %6d                       ║", num_writes);
        $display("║  Reads           : %6d                       ║", num_reads);
        $display("║  Errors          : %6d                       ║", num_errors);
        $display("║  Timeouts        : %6d                       ║", num_timeouts);
        $display("╚══════════════════════════════════════════════╝");
        $display("");
    endfunction

endclass

