// =============================================================================
// File:    apb_transaction.sv
// Purpose: Randomizable transaction class for APB protocol verification.
//
//          Represents a single APB transfer (read or write). Contains all the
//          fields needed to describe a transfer request AND capture its response.
//
// Field Groups:
//   Group 1 — Stimulus fields  (randomized): addr, write, wdata
//   Group 2 — Response fields  (set by monitor/driver): rdata, error, ready
//   Group 3 — Metadata fields  (bookkeeping): transfer_id, timestamps, slave_id
//
// Constraints:
//   Constraints are organized into independent, toggleable groups using
//   constraint_mode(). Tests enable/disable specific constraints to target
//   different scenarios (aligned vs unaligned, valid vs invalid addresses, etc.)
//
// Usage:
//   apb_transaction txn = new();
//   txn.randomize();                        // Random valid transfer
//   txn.c_word_aligned.constraint_mode(0);  // Disable alignment constraint
//   txn.randomize();                        // Now generates unaligned addrs
// =============================================================================

class apb_transaction;

    // =========================================================================
    // Group 1: Stimulus Fields (Randomizable)
    // =========================================================================
    // These fields are randomized and used by the Driver to construct
    // the transfer request signals.
    // =========================================================================
    rand bit [31:0] addr;       // Target address
    rand bit        write;      // 1 = Write transfer, 0 = Read transfer
    rand bit [31:0] wdata;      // Write data (only meaningful when write=1)

    // =========================================================================
    // Group 2: Response Fields (Non-Random)
    // =========================================================================
    // These fields are populated by the Driver (after transfer completes)
    // or by the Monitor (observing the bus). NOT randomized.
    // =========================================================================
    bit [31:0] rdata;           // Read data returned by the slave
    bit        error;           // PSLVERR — slave error response
    bit        ready;           // PREADY captured at transfer completion

    // =========================================================================
    // Group 3: Metadata Fields (Bookkeeping)
    // =========================================================================
    // Used for tracking, debugging, and scoreboard correlation.
    // NOT randomized — set by the testbench infrastructure.
    // =========================================================================
    int        transfer_id;     // Unique sequential ID (assigned by driver)
    time       start_time;      // $time when transfer was initiated
    time       end_time;        // $time when transfer completed
    int        slave_id;        // Which slave was targeted (0, 1, 2, or -1 = none)
    int        wait_cycles;     // Number of wait cycles observed (0 = immediate)

    // =========================================================================
    // Constraint: Valid Slave Address Range
    // =========================================================================
    // Restricts addr to fall within one of the three slave address ranges.
    // This is the DEFAULT mode — most tests want valid addresses.
    //
    // Address Map:
    //   Slave 0: 0x0000_0000 – 0x0000_00FF  (256 bytes)
    //   Slave 1: 0x0000_0100 – 0x0000_01FF  (256 bytes)
    //   Slave 2: 0x0000_0200 – 0x0000_02FF  (256 bytes)
    //
    // To generate out-of-range addresses, disable this constraint:
    //   txn.c_valid_slave_addr.constraint_mode(0);
    // =========================================================================
    constraint c_valid_slave_addr {
        addr inside {
            [32'h0000_0000 : 32'h0000_00FF],   // Slave 0
            [32'h0000_0100 : 32'h0000_01FF],   // Slave 1
            [32'h0000_0200 : 32'h0000_02FF]    // Slave 2
        };
    }

    // =========================================================================
    // Constraint: Word-Aligned Address
    // =========================================================================
    // Ensures addr[1:0] == 2'b00 (4-byte aligned).
    // The APB slave flags unaligned accesses as PSLVERR.
    //
    // To generate unaligned addresses (for error testing), disable this:
    //   txn.c_word_aligned.constraint_mode(0);
    // =========================================================================
    constraint c_word_aligned {
        addr[1:0] == 2'b00;
    }

    // =========================================================================
    // Constraint: Slave Distribution (Weighted)
    // =========================================================================
    // Controls how frequently each slave is targeted during random testing.
    // Slave 2 gets a higher weight because it has wait states (WAIT_CYCLES=1)
    // and needs thorough testing.
    //
    // Distribution: Slave 0 = 30%, Slave 1 = 30%, Slave 2 = 40%
    // =========================================================================
    constraint c_slave_distribution {
        addr dist {
            [32'h0000_0000 : 32'h0000_00FF] :/ 30,   // Slave 0 — no wait states
            [32'h0000_0100 : 32'h0000_01FF] :/ 30,   // Slave 1 — no wait states
            [32'h0000_0200 : 32'h0000_02FF] :/ 40    // Slave 2 — 1 wait cycle
        };
    }

    // =========================================================================
    // Constraint: Write/Read Distribution
    // =========================================================================
    // Balanced 50/50 by default. Tests can override for write-heavy or
    // read-heavy workloads.
    // =========================================================================
    constraint c_rw_distribution {
        write dist {
            1 :/ 50,    // 50% writes
            0 :/ 50     // 50% reads
        };
    }

    // =========================================================================
    // Constructor
    // =========================================================================
    function new();
        this.transfer_id = -1;
        this.slave_id    = -1;
        this.start_time  = 0;
        this.end_time    = 0;
        this.wait_cycles = 0;
        this.rdata       = '0;
        this.error       = 0;
        this.ready       = 0;
    endfunction

    // =========================================================================
    // Post-Randomize: Auto-compute slave_id from address
    // =========================================================================
    // Called automatically after every successful randomize() call.
    // Determines which slave the randomized address maps to.
    // =========================================================================
    function void post_randomize();
        if      (addr >= 32'h0000_0000 && addr <= 32'h0000_00FF) slave_id = 0;
        else if (addr >= 32'h0000_0100 && addr <= 32'h0000_01FF) slave_id = 1;
        else if (addr >= 32'h0000_0200 && addr <= 32'h0000_02FF) slave_id = 2;
        else                                                      slave_id = -1;
    endfunction

    // =========================================================================
    // Utility: Copy / Clone
    // =========================================================================
    // Creates a deep copy of this transaction. Useful when the monitor needs
    // to capture a snapshot without the driver overwriting fields later.
    // =========================================================================
    function apb_transaction copy();
        apb_transaction c = new();
        c.addr        = this.addr;
        c.write       = this.write;
        c.wdata       = this.wdata;
        c.rdata       = this.rdata;
        c.error       = this.error;
        c.ready       = this.ready;
        c.transfer_id = this.transfer_id;
        c.start_time  = this.start_time;
        c.end_time    = this.end_time;
        c.slave_id    = this.slave_id;
        c.wait_cycles = this.wait_cycles;
        return c;
    endfunction

    // =========================================================================
    // Utility: Compare
    // =========================================================================
    // Compares two transactions for data-level equality. Used by the
    // scoreboard to verify expected vs actual results.
    //
    // Returns 1 if ALL compared fields match, 0 otherwise.
    // Only compares fields relevant to correctness (not metadata like times).
    // =========================================================================
    function bit compare(apb_transaction other);
        bit match = 1;

        if (this.addr !== other.addr) begin
            $display("[TXN COMPARE] MISMATCH addr: expected=0x%08h, actual=0x%08h",
                     this.addr, other.addr);
            match = 0;
        end

        if (this.write !== other.write) begin
            $display("[TXN COMPARE] MISMATCH write: expected=%0b, actual=%0b",
                     this.write, other.write);
            match = 0;
        end

        // For write transfers, compare wdata
        if (this.write && (this.wdata !== other.wdata)) begin
            $display("[TXN COMPARE] MISMATCH wdata: expected=0x%08h, actual=0x%08h",
                     this.wdata, other.wdata);
            match = 0;
        end

        // For read transfers, compare rdata
        if (!this.write && (this.rdata !== other.rdata)) begin
            $display("[TXN COMPARE] MISMATCH rdata: expected=0x%08h, actual=0x%08h",
                     this.rdata, other.rdata);
            match = 0;
        end

        if (this.error !== other.error) begin
            $display("[TXN COMPARE] MISMATCH error: expected=%0b, actual=%0b",
                     this.error, other.error);
            match = 0;
        end

        return match;
    endfunction

    // =========================================================================
    // Utility: Display / Print
    // =========================================================================
    // Prints a formatted summary of the transaction. Used for debug logging.
    //
    // Example output:
    //   [TXN #5] WRITE addr=0x00000004 wdata=0xDEADBEEF slave=0 | OK @ 150ns–200ns
    //   [TXN #6] READ  addr=0x00000104 rdata=0x12345678 slave=1 | OK @ 210ns–260ns
    //   [TXN #7] WRITE addr=0x00000001 wdata=0xCAFEBABE slave=0 | ERR @ 300ns–350ns
    // =========================================================================
    function void display(string prefix = "");
        string dir_str;
        string status_str;
        string data_str;

        // Direction string
        dir_str = write ? "WRITE" : "READ ";

        // Status string
        status_str = error ? "ERR" : "OK ";

        // Data string — show wdata for writes, rdata for reads
        if (write)
            $sformat(data_str, "wdata=0x%08h", wdata);
        else
            $sformat(data_str, "rdata=0x%08h", rdata);

        $display("%s[TXN #%0d] %s addr=0x%08h %s slave=%0d | %s @ %0t–%0t",
                 prefix, transfer_id, dir_str, addr, data_str,
                 slave_id, status_str, start_time, end_time);
    endfunction

    // =========================================================================
    // Utility: Compute Register Index
    // =========================================================================
    // Extracts the register index from the address, matching the hardware
    // addressing scheme: reg_idx = addr[5:2] (word-aligned, 16 registers).
    // =========================================================================
    function int get_reg_index();
        return addr[5:2];
    endfunction

    // =========================================================================
    // Utility: Is Address Aligned?
    // =========================================================================
    // Returns 1 if the address is word-aligned (addr[1:0] == 0).
    // Used by the scoreboard to predict whether PSLVERR should fire.
    // =========================================================================
    function bit is_aligned();
        return (addr[1:0] == 2'b00);
    endfunction

endclass

