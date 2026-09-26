// =============================================================================
// File:    apb_scoreboard.sv
// Purpose: APB Testbench Scoreboard — reference model + result checker.
//
//          The Scoreboard is the "brain" of verification correctness. It
//          maintains shadow register files that mirror the DUT's slave
//          register files, and compares every observed transaction against
//          the expected behavior.
//
// Architecture:
//   ┌─────────────────────────────────────────────────────┐
//   │                    Scoreboard                       │
//   │                                                     │
//   │   Monitor ──(mailbox)──► check_transaction()        │
//   │                              │                      │
//   │                    ┌─────────┴──────────┐           │
//   │                    ▼                    ▼           │
//   │            Reference Model         Comparator       │
//   │         (shadow reg files)      (expected vs actual)│
//   │         ┌────────────────┐          │               │
//   │         │ shadow_slave0  │     PASS / FAIL          │
//   │         │ shadow_slave1  │          │               │
//   │         │ shadow_slave2  │          ▼               │
//   │         └────────────────┘     Statistics           │
//   └─────────────────────────────────────────────────────┘
//
// Checks Performed:
//   SCB_001 — Write-then-read data integrity (read data == shadow)
//   SCB_002 — Read from unwritten register returns 0x00000000
//   SCB_003 — PSLVERR=1 on unaligned access (addr[1:0] != 0)
//   SCB_004 — PSLVERR=0 on aligned access
//   SCB_005 — Correct slave selected for given address
//   SCB_006 — Wait state count matches slave configuration
//   SCB_007 — All register indices are accessible
//   SCB_008 — Reset clears all registers (via reset_shadow_registers)
// =============================================================================

class apb_scoreboard;

    // =========================================================================
    // Mailbox: Transaction Input
    // =========================================================================
    // Receives completed transactions from the Monitor.
    // =========================================================================
    mailbox #(apb_transaction) scb_mbx;

    // =========================================================================
    // Reference Model: Shadow Register Files
    // =========================================================================
    // Mirror of the DUT's slave register files. Updated on every write
    // transaction, and consulted on every read transaction to predict
    // the expected PRDATA value.
    //
    // Dimensions: 3 slaves × 16 registers × 32 bits
    // Indexed as:  shadow_regs[slave_id][reg_index]
    //
    // Initial state: all zeros (same as DUT after reset).
    // =========================================================================
    bit [31:0] shadow_regs [3][16];    // [slave_id][reg_index]

    // =========================================================================
    // Statistics & Tracking
    // =========================================================================
    int unsigned num_checked;           // Total transactions checked
    int unsigned num_passed;            // Transactions that passed all checks
    int unsigned num_failed;            // Transactions that failed any check
    int unsigned num_write_updates;     // Shadow register writes performed
    int unsigned num_read_compares;     // Read data comparisons performed
    int unsigned num_error_checks;      // Error response checks performed

    // Track which registers have been written (for coverage insight)
    bit reg_written [3][16];            // [slave_id][reg_index] = 1 if ever written

    // Failure log — stores first N failures for end-of-sim report
    string       failure_log[$];
    int unsigned max_failure_log;       // Max failures to store (prevent memory bloat)

    // =========================================================================
    // Constructor
    // =========================================================================
    function new(mailbox #(apb_transaction) scb_mbx);
        this.scb_mbx          = scb_mbx;
        this.num_checked      = 0;
        this.num_passed       = 0;
        this.num_failed       = 0;
        this.num_write_updates = 0;
        this.num_read_compares = 0;
        this.num_error_checks = 0;
        this.max_failure_log  = 50;

        // Initialize shadow registers and written-tracking to zero
        reset_shadow_registers();
    endfunction

    // =========================================================================
    // Task: run()
    // =========================================================================
    // Main scoreboard loop — runs forever (forked in the environment).
    // Pulls transactions from the mailbox and checks each one.
    // =========================================================================
    task run();
        apb_transaction txn;

        $display("[SCB] [%0t] Scoreboard starting.", $time);

        forever begin
            scb_mbx.get(txn);
            check_transaction(txn);
        end
    endtask

    // =========================================================================
    // Function: check_transaction()
    // =========================================================================
    // Master check function — runs ALL applicable checks on a single
    // transaction and records PASS/FAIL.
    //
    // Check Flow:
    //   1. Validate slave selection matches address range
    //   2. Check error response (PSLVERR) correctness
    //   3. If no error:
    //      a. WRITE → update shadow register
    //      b. READ  → compare rdata against shadow register
    //   4. If slave 2: verify wait cycles
    // =========================================================================
    function void check_transaction(apb_transaction txn);
        bit all_passed;
        int expected_slave;
        int reg_idx;

        all_passed = 1;
        num_checked++;

        // ---------------------------------------------------------------
        // Determine expected slave from address
        // ---------------------------------------------------------------
        expected_slave = get_expected_slave(txn.addr);
        reg_idx        = txn.get_reg_index();   // addr[5:2]

        // ---------------------------------------------------------------
        // CHECK: SCB_005 — Correct slave selection
        // ---------------------------------------------------------------
        if (txn.slave_id !== expected_slave) begin
            log_failure(txn, "SCB_005",
                $sformatf("Slave select mismatch: expected=%0d actual=%0d",
                          expected_slave, txn.slave_id));
            all_passed = 0;
        end

        // ---------------------------------------------------------------
        // CHECK: SCB_003 / SCB_004 — Error response correctness
        // ---------------------------------------------------------------
        num_error_checks++;

        if (!txn.is_aligned()) begin
            // SCB_003: Unaligned address SHOULD produce error
            if (!txn.error) begin
                log_failure(txn, "SCB_003",
                    $sformatf("Unaligned addr=0x%08h should produce PSLVERR=1, got 0",
                              txn.addr));
                all_passed = 0;
            end
        end
        else begin
            // SCB_004: Aligned address should NOT produce error
            //          (within valid address range)
            if (txn.error && expected_slave >= 0) begin
                log_failure(txn, "SCB_004",
                    $sformatf("Aligned addr=0x%08h got unexpected PSLVERR=1",
                              txn.addr));
                all_passed = 0;
            end
        end

        // ---------------------------------------------------------------
        // Only check data integrity for valid, error-free transfers
        // ---------------------------------------------------------------
        if (expected_slave >= 0 && expected_slave <= 2 &&
            txn.is_aligned() && !txn.error) begin

            if (txn.write) begin
                // ---------------------------------------------------
                // WRITE: Update shadow register
                // ---------------------------------------------------
                // Store the written data so future reads can be verified.
                // ---------------------------------------------------
                shadow_regs[expected_slave][reg_idx] = txn.wdata;
                reg_written[expected_slave][reg_idx] = 1;
                num_write_updates++;

            end
            else begin
                // ---------------------------------------------------
                // CHECK: SCB_001 / SCB_002 — Read data integrity
                // ---------------------------------------------------
                // Compare actual read data against shadow register.
                //
                // SCB_001: If this register was previously written,
                //          rdata must match the written value.
                // SCB_002: If never written, rdata must be 0x00000000
                //          (reset value).
                // ---------------------------------------------------
                num_read_compares++;

                if (txn.rdata !== shadow_regs[expected_slave][reg_idx]) begin
                    log_failure(txn, "SCB_001",
                        $sformatf("Read data mismatch: slave=%0d reg=%0d expected=0x%08h actual=0x%08h %s",
                                  expected_slave, reg_idx,
                                  shadow_regs[expected_slave][reg_idx],
                                  txn.rdata,
                                  reg_written[expected_slave][reg_idx] ?
                                      "(previously written)" : "(never written, expected 0)"));
                    all_passed = 0;
                end
            end
        end

        // ---------------------------------------------------------------
        // CHECK: SCB_006 — Wait state count for Slave 2
        // ---------------------------------------------------------------
        // Slave 2 is configured with WAIT_CYCLES=1, so every transfer
        // to Slave 2 should observe exactly 1 wait cycle.
        // Slaves 0 & 1 have WAIT_CYCLES=0, so wait_cycles should be 0.
        // ---------------------------------------------------------------
        if (expected_slave == 2) begin
            if (txn.wait_cycles != 1) begin
                log_failure(txn, "SCB_006",
                    $sformatf("Slave 2 wait cycles: expected=1 actual=%0d",
                              txn.wait_cycles));
                all_passed = 0;
            end
        end
        else if (expected_slave >= 0 && expected_slave <= 1) begin
            if (txn.wait_cycles != 0) begin
                log_failure(txn, "SCB_006",
                    $sformatf("Slave %0d wait cycles: expected=0 actual=%0d",
                              expected_slave, txn.wait_cycles));
                all_passed = 0;
            end
        end

        // ---------------------------------------------------------------
        // Record result
        // ---------------------------------------------------------------
        if (all_passed) begin
            num_passed++;
        end
        else begin
            num_failed++;
        end
    endfunction

    // =========================================================================
    // Function: get_expected_slave()
    // =========================================================================
    // Returns the expected slave ID (0, 1, or 2) for a given address,
    // or -1 if the address doesn't map to any slave.
    //
    // Address Map (must match apb_decoder parameters):
    //   Slave 0: 0x0000_0000 – 0x0000_00FF
    //   Slave 1: 0x0000_0100 – 0x0000_01FF
    //   Slave 2: 0x0000_0200 – 0x0000_02FF
    // =========================================================================
    function int get_expected_slave(bit [31:0] addr);
        if      (addr >= 32'h0000_0000 && addr <= 32'h0000_00FF) return 0;
        else if (addr >= 32'h0000_0100 && addr <= 32'h0000_01FF) return 1;
        else if (addr >= 32'h0000_0200 && addr <= 32'h0000_02FF) return 2;
        else                                                      return -1;
    endfunction

    // =========================================================================
    // Function: reset_shadow_registers()
    // =========================================================================
    // Clears all shadow registers to zero and resets the written-tracking
    // array. Call this whenever the DUT is reset to keep the reference
    // model in sync.
    //
    // Implements: SCB_008 — Reset clears all registers
    // =========================================================================
    function void reset_shadow_registers();
        for (int s = 0; s < 3; s++) begin
            for (int r = 0; r < 16; r++) begin
                shadow_regs[s][r] = 32'h0000_0000;
                reg_written[s][r] = 0;
            end
        end
        $display("[SCB] [%0t] Shadow registers reset to zero.", $time);
    endfunction

    // =========================================================================
    // Function: log_failure()
    // =========================================================================
    // Records a check failure with full context. Prints immediately to
    // the simulation log and stores in the failure_log queue for the
    // end-of-simulation report.
    // =========================================================================
    function void log_failure(apb_transaction txn, string check_id, string message);
        string log_entry;

        $sformat(log_entry, "[SCB] FAIL %s TXN#%0d: %s",
                 check_id, txn.transfer_id, message);

        // Print immediately
        $display("[SCB] [%0t] *** FAIL *** %s | TXN #%0d %s addr=0x%08h | %s",
                 $time, check_id, txn.transfer_id,
                 txn.write ? "WR" : "RD", txn.addr, message);

        // Store for end-of-sim report (capped to prevent memory bloat)
        if (failure_log.size() < max_failure_log) begin
            failure_log.push_back(log_entry);
        end
        else if (failure_log.size() == max_failure_log) begin
            failure_log.push_back("[SCB] ... (further failures truncated)");
        end
    endfunction

    // =========================================================================
    // Function: get_shadow_value()
    // =========================================================================
    // Returns the current shadow register value for a given slave and
    // register index. Useful for directed tests that need to predict
    // expected read data.
    // =========================================================================
    function bit [31:0] get_shadow_value(int slave_id, int reg_idx);
        if (slave_id >= 0 && slave_id <= 2 && reg_idx >= 0 && reg_idx <= 15)
            return shadow_regs[slave_id][reg_idx];
        else begin
            $display("[SCB] WARNING: get_shadow_value called with invalid slave=%0d reg=%0d",
                     slave_id, reg_idx);
            return 32'hxxxx_xxxx;
        end
    endfunction

    // =========================================================================
    // Function: is_register_written()
    // =========================================================================
    // Returns 1 if the given register has ever been written since the last
    // reset. Useful for coverage analysis.
    // =========================================================================
    function bit is_register_written(int slave_id, int reg_idx);
        if (slave_id >= 0 && slave_id <= 2 && reg_idx >= 0 && reg_idx <= 15)
            return reg_written[slave_id][reg_idx];
        else
            return 0;
    endfunction

    // =========================================================================
    // Function: print_stats()
    // =========================================================================
    // Prints a comprehensive end-of-simulation summary including pass/fail
    // counts and any logged failures.
    // =========================================================================
    function void print_stats();
        $display("");
        $display("╔══════════════════════════════════════════════════════╗");
        $display("║             Scoreboard Results                       ║");
        $display("╠══════════════════════════════════════════════════════╣");
        $display("║  Total Checked     : %6d                           ║", num_checked);
        $display("║  PASSED            : %6d                           ║", num_passed);
        $display("║  FAILED            : %6d                           ║", num_failed);
        $display("║  ─────────────────────────────────                   ║");
        $display("║  Write Updates     : %6d                           ║", num_write_updates);
        $display("║  Read Compares     : %6d                           ║", num_read_compares);
        $display("║  Error Checks      : %6d                           ║", num_error_checks);
        $display("╠══════════════════════════════════════════════════════╣");

        if (num_failed == 0) begin
            $display("║  ✅ ALL CHECKS PASSED                                ║");
        end
        else begin
            $display("║  ❌ %0d CHECK(S) FAILED                              ║", num_failed);
        end

        $display("╚══════════════════════════════════════════════════════╝");

        // Print failure log if any
        if (failure_log.size() > 0) begin
            $display("");
            $display("──────── Failure Details ────────");
            foreach (failure_log[i]) begin
                $display("  %s", failure_log[i]);
            end
            $display("────────────────────────────────");
        end

        $display("");
    endfunction

    // =========================================================================
    // Function: print_shadow_dump()
    // =========================================================================
    // Dumps the entire shadow register file contents. Useful for debugging
    // when a read mismatch occurs.
    // =========================================================================
    function void print_shadow_dump();
        $display("");
        $display("──────── Shadow Register Dump ────────");
        for (int s = 0; s < 3; s++) begin
            $display("  Slave %0d:", s);
            for (int r = 0; r < 16; r++) begin
                if (reg_written[s][r])
                    $display("    reg[%2d] = 0x%08h  (written)", r, shadow_regs[s][r]);
                else
                    $display("    reg[%2d] = 0x%08h  (default)", r, shadow_regs[s][r]);
            end
        end
        $display("──────────────────────────────────────");
        $display("");
    endfunction

    // =========================================================================
    // Function: get_pass_status()
    // =========================================================================
    // Returns 1 if ALL checks passed (num_failed == 0), 0 otherwise.
    // Used by the test to determine overall PASS/FAIL status.
    // =========================================================================
    function bit get_pass_status();
        return (num_failed == 0) && (num_checked > 0);
    endfunction

endclass

