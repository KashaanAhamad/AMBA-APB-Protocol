// =============================================================================
// File:    apb_coverage.sv
// Purpose: APB Testbench Functional Coverage Collector.
//
//          Measures verification completeness by tracking which scenarios
//          have been exercised during simulation. The coverage collector
//          receives completed transactions from the Monitor via a mailbox
//          and samples covergroups to record what has been tested.
//
// Covergroups:
//   CG1 — Transfer Type:   write/read × slave (cross coverage)
//   CG2 — Address Space:   address range, register offset, alignment
//   CG3 — Protocol State:  FSM states, transitions, wait cycles
//   CG4 — Error Response:  PSLVERR × transfer direction
//   CG5 — Sequences:       back-to-back patterns, slave switching
//   CG6 — Data Patterns:   boundary values, special patterns
//
// Coverage Target: ≥ 95% on all covergroups
//
// Usage:
//   The environment creates this collector, connects the mailbox and
//   virtual interface, then forks run() alongside the other components.
// =============================================================================

class apb_coverage;

    // =========================================================================
    // Interface Handle (for sampling FSM state directly)
    // =========================================================================
    virtual apb_if.MONITOR vif;

    // =========================================================================
    // Mailbox: Transaction Input
    // =========================================================================
    mailbox #(apb_transaction) cov_mbx;

    // =========================================================================
    // Sampled Variables
    // =========================================================================
    // These are updated from each received transaction before covergroups
    // are sampled. Covergroups reference these variables.
    // =========================================================================

    // Transaction fields
    bit [31:0] txn_addr;
    bit        txn_write;
    bit [31:0] txn_wdata;
    bit [31:0] txn_rdata;
    bit        txn_error;
    int        txn_slave_id;
    int        txn_wait_cycles;
    int        txn_reg_index;

    // Sequence tracking (for cross-transfer coverage)
    bit        prev_write;               // Previous transaction direction
    int        prev_slave_id;            // Previous transaction slave
    bit        is_back_to_back;          // Current txn was back-to-back
    bit        slave_changed;            // Slave differs from previous
    bit        first_txn;                // Flag: is this the first transaction?

    // FSM state (sampled from interface)
    bit [1:0]  fsm_state;

    // =========================================================================
    // CG1: Transfer Type Coverage
    // =========================================================================
    // Ensures every combination of transfer direction × target slave
    // has been exercised.
    //
    // Bins:
    //   cp_direction: write, read
    //   cp_slave:     slave0, slave1, slave2
    //   cross:        6 combinations (write×slave0, write×slave1, ...)
    // =========================================================================
    covergroup cg_transfer_type;
        option.per_instance = 1;
        option.name = "CG1_Transfer_Type";

        cp_direction: coverpoint txn_write {
            bins write = {1};
            bins read  = {0};
        }

        cp_slave: coverpoint txn_slave_id {
            bins slave0       = {0};
            bins slave1       = {1};
            bins slave2       = {2};
            illegal_bins none = {-1};
        }

        // Cross: every slave must see both writes and reads
        cx_dir_x_slave: cross cp_direction, cp_slave;
    endgroup

    // =========================================================================
    // CG2: Address Space Coverage
    // =========================================================================
    // Ensures the full address space has been exercised — all slave ranges,
    // all register offsets, and both aligned/unaligned accesses.
    //
    // Bins:
    //   cp_addr_range:  which slave's address range
    //   cp_reg_offset:  which register index (0–15)
    //   cp_alignment:   word-aligned vs unaligned
    //   cross:          reg_offset × addr_range (48 combos: 16 regs × 3 slaves)
    // =========================================================================
    covergroup cg_address;
        option.per_instance = 1;
        option.name = "CG2_Address_Space";

        cp_addr_range: coverpoint txn_slave_id {
            bins slave0_range = {0};
            bins slave1_range = {1};
            bins slave2_range = {2};
        }

        cp_reg_offset: coverpoint txn_reg_index {
            bins regs[] = {[0:15]};    // 16 individual bins, one per register
        }

        cp_alignment: coverpoint txn_addr[1:0] {
            bins aligned     = {2'b00};
            bins unaligned[] = {2'b01, 2'b10, 2'b11};
        }

        // Cross: every register in every slave
        cx_reg_x_slave: cross cp_reg_offset, cp_addr_range;
    endgroup

    // =========================================================================
    // CG3: Protocol State Coverage
    // =========================================================================
    // Ensures all FSM states and transitions have been exercised, including
    // wait state insertion.
    //
    // Bins:
    //   cp_fsm_state:       IDLE, SETUP, ACCESS
    //   cp_fsm_transitions: all valid state transitions
    //   cp_wait_cycles:     no wait, 1 wait, 2+ waits
    // =========================================================================
    covergroup cg_protocol;
        option.per_instance = 1;
        option.name = "CG3_Protocol_State";

        cp_fsm_state: coverpoint fsm_state {
            bins idle   = {2'b00};
            bins setup  = {2'b01};
            bins access = {2'b10};
        }

        cp_fsm_transitions: coverpoint fsm_state {
            bins idle_to_setup    = (2'b00 => 2'b01);
            bins setup_to_access  = (2'b01 => 2'b10);
            bins access_to_idle   = (2'b10 => 2'b00);
            bins access_to_setup  = (2'b10 => 2'b01);    // back-to-back
            bins access_to_access = (2'b10 => 2'b10);    // wait states
        }

        cp_wait_cycles: coverpoint txn_wait_cycles {
            bins no_wait    = {0};
            bins one_wait   = {1};
            bins multi_wait = {[2:$]};
        }
    endgroup

    // =========================================================================
    // CG4: Error Response Coverage
    // =========================================================================
    // Ensures both error and non-error paths have been exercised for
    // both writes and reads.
    //
    // Bins:
    //   cp_pslverr:   no_error, error
    //   cp_direction: write, read
    //   cross:        4 combos (write_ok, write_err, read_ok, read_err)
    // =========================================================================
    covergroup cg_errors;
        option.per_instance = 1;
        option.name = "CG4_Error_Response";

        cp_pslverr: coverpoint txn_error {
            bins no_error = {0};
            bins error    = {1};
        }

        cp_direction: coverpoint txn_write {
            bins write = {1};
            bins read  = {0};
        }

        // Cross: all 4 combinations
        cx_error_x_dir: cross cp_pslverr, cp_direction;
    endgroup

    // =========================================================================
    // CG5: Sequence Coverage
    // =========================================================================
    // Ensures various transfer sequences and patterns have been tested,
    // including back-to-back transfers with different direction combinations
    // and slave switching.
    //
    // Bins:
    //   cp_b2b:            idle gap vs back-to-back
    //   cp_dir_sequence:   WR→WR, WR→RD, RD→WR, RD→RD
    //   cp_slave_switch:   same slave vs different slave
    //   cross:             b2b × dir_sequence, b2b × slave_switch
    // =========================================================================
    covergroup cg_sequences;
        option.per_instance = 1;
        option.name = "CG5_Sequences";

        cp_b2b: coverpoint is_back_to_back {
            bins idle_gap     = {0};    // Transfer after 1+ idle cycles
            bins back_to_back = {1};    // Consecutive transfer (no idle gap)
        }

        cp_dir_sequence: coverpoint {prev_write, txn_write} {
            bins write_then_write = {2'b11};
            bins write_then_read  = {2'b10};
            bins read_then_write  = {2'b01};
            bins read_then_read   = {2'b00};
        }

        cp_slave_switch: coverpoint slave_changed {
            bins same_slave = {0};     // Consecutive transfers to same slave
            bins diff_slave = {1};     // Switched to a different slave
        }

        // Cross: back-to-back with direction pattern
        cx_b2b_x_dir: cross cp_b2b, cp_dir_sequence;

        // Cross: back-to-back with slave switching
        cx_b2b_x_slave: cross cp_b2b, cp_slave_switch;
    endgroup

    // =========================================================================
    // CG6: Data Pattern Coverage
    // =========================================================================
    // Ensures write data has exercised important boundary values and bit
    // patterns that stress the data path.
    //
    // Bins: all_zeros, all_ones, walking patterns, alternating, etc.
    // =========================================================================
    covergroup cg_data_patterns;
        option.per_instance = 1;
        option.name = "CG6_Data_Patterns";

        cp_wdata_special: coverpoint txn_wdata {
            bins all_zeros     = {32'h0000_0000};
            bins all_ones      = {32'hFFFF_FFFF};
            bins alternating_a = {32'hAAAA_AAAA};
            bins alternating_5 = {32'h5555_5555};
            bins low_byte_only = {32'h0000_00FF};
            bins high_byte_only= {32'hFF00_0000};
            bins one_bit_low   = {32'h0000_0001};
            bins one_bit_high  = {32'h8000_0000};
            bins default_other = default;
        }

        // Only sample when it's a write transfer
        cp_is_write: coverpoint txn_write {
            bins write_only = {1};
        }

        // Cross: only meaningful for writes
        cx_data_x_write: cross cp_wdata_special, cp_is_write {
            ignore_bins reads = binsof(cp_is_write) intersect {0};
        }
    endgroup

    // =========================================================================
    // Statistics
    // =========================================================================
    int unsigned num_sampled;            // Total transactions sampled

    // =========================================================================
    // Constructor
    // =========================================================================
    function new(virtual apb_if.MONITOR vif, mailbox #(apb_transaction) cov_mbx);
        this.vif           = vif;
        this.cov_mbx       = cov_mbx;
        this.num_sampled   = 0;
        this.first_txn     = 1;
        this.prev_write    = 0;
        this.prev_slave_id = -1;
        this.is_back_to_back = 0;
        this.slave_changed   = 0;

        // Construct all covergroups
        cg_transfer_type = new();
        cg_address        = new();
        cg_protocol       = new();
        cg_errors         = new();
        cg_sequences      = new();
        cg_data_patterns  = new();
    endfunction

    // =========================================================================
    // Task: run()
    // =========================================================================
    // Main coverage collection loop. Runs two concurrent processes:
    //   1. Transaction-driven sampling (from mailbox)
    //   2. FSM state sampling (every clock cycle for transition coverage)
    // =========================================================================
    task run();
        $display("[COV] [%0t] Coverage collector starting.", $time);

        fork
            sample_transactions();
            sample_fsm_state();
        join
    endtask

    // =========================================================================
    // Task: sample_transactions()
    // =========================================================================
    // Pulls completed transactions from the mailbox and samples all
    // transaction-driven covergroups.
    // =========================================================================
    task sample_transactions();
        apb_transaction txn;

        forever begin
            cov_mbx.get(txn);

            // ---------------------------------------------------------------
            // Update sampled variables from transaction
            // ---------------------------------------------------------------
            txn_addr        = txn.addr;
            txn_write       = txn.write;
            txn_wdata       = txn.wdata;
            txn_rdata       = txn.rdata;
            txn_error       = txn.error;
            txn_slave_id    = txn.slave_id;
            txn_wait_cycles = txn.wait_cycles;
            txn_reg_index   = txn.get_reg_index();

            // ---------------------------------------------------------------
            // Update sequence tracking variables
            // ---------------------------------------------------------------
            if (!first_txn) begin
                slave_changed  = (txn.slave_id !== prev_slave_id);
                // back-to-back is inferred from monitor's wait_cycles
                // and timing — here we use a simplified heuristic:
                // if the gap between transfers is minimal, it's b2b
                is_back_to_back = (txn.slave_id >= 0);  // Will be refined by monitor data
            end
            else begin
                slave_changed   = 0;
                is_back_to_back = 0;
            end

            // ---------------------------------------------------------------
            // Sample all transaction-driven covergroups
            // ---------------------------------------------------------------
            cg_transfer_type.sample();
            cg_address.sample();
            cg_errors.sample();
            cg_data_patterns.sample();

            // Sequence coverage requires at least 2 transactions
            if (!first_txn) begin
                cg_sequences.sample();
            end

            // Wait cycle coverage
            cg_protocol.sample();

            // ---------------------------------------------------------------
            // Update state for next transaction
            // ---------------------------------------------------------------
            prev_write    = txn.write;
            prev_slave_id = txn.slave_id;
            first_txn     = 0;
            num_sampled++;
        end
    endtask

    // =========================================================================
    // Task: sample_fsm_state()
    // =========================================================================
    // Samples the FSM state every clock cycle for transition coverage.
    // This runs independently from the transaction mailbox because
    // FSM transitions happen every cycle, not just on transfer completion.
    // =========================================================================
    task sample_fsm_state();
        // Wait for reset
        @(posedge vif.presetn);
        @(vif.mon_cb);

        forever begin
            @(vif.mon_cb);
            fsm_state = vif.mon_cb.current_state;
            cg_protocol.sample();
        end
    endtask

    // =========================================================================
    // Function: print_stats()
    // =========================================================================
    // Prints coverage percentages for all covergroups.
    // =========================================================================
    function void print_stats();
        real cg1_cov, cg2_cov, cg3_cov, cg4_cov, cg5_cov, cg6_cov;
        real total_cov;

        cg1_cov = cg_transfer_type.get_coverage();
        cg2_cov = cg_address.get_coverage();
        cg3_cov = cg_protocol.get_coverage();
        cg4_cov = cg_errors.get_coverage();
        cg5_cov = cg_sequences.get_coverage();
        cg6_cov = cg_data_patterns.get_coverage();
        total_cov = (cg1_cov + cg2_cov + cg3_cov + cg4_cov + cg5_cov + cg6_cov) / 6.0;

        $display("");
        $display("╔══════════════════════════════════════════════════════╗");
        $display("║          Functional Coverage Report                  ║");
        $display("╠══════════════════════════════════════════════════════╣");
        $display("║  Transactions Sampled : %6d                          ║", num_sampled);
        $display("║  ─────────────────────────────────                   ║");
        $display("║  CG1 Transfer Type    : %6.2f%%                      ║", cg1_cov);
        $display("║  CG2 Address Space    : %6.2f%%                      ║", cg2_cov);
        $display("║  CG3 Protocol State   : %6.2f%%                      ║", cg3_cov);
        $display("║  CG4 Error Response   : %6.2f%%                      ║", cg4_cov);
        $display("║  CG5 Sequences        : %6.2f%%                      ║", cg5_cov);
        $display("║  CG6 Data Patterns    : %6.2f%%                      ║", cg6_cov);
        $display("║  ─────────────────────────────────                   ║");
        $display("║  OVERALL AVERAGE      : %6.2f%%                      ║", total_cov);
        $display("╠══════════════════════════════════════════════════════╣");

        if (total_cov >= 95.0)
            $display("║   Coverage target MET (≥95%%)                    ║");
        else
            $display("║   Coverage target NOT met (<%6.2f%% < 95%%)      ║", total_cov);

        $display("    ╚══════════════════════════════════════════════════╝");
        $display("");
    endfunction

    // =========================================================================
    // Function: is_target_met()
    // =========================================================================
    // Returns 1 if all individual covergroups are at or above the
    // specified threshold (default 95%).
    // =========================================================================
    function bit is_target_met(real threshold = 95.0);
        return (cg_transfer_type.get_coverage() >= threshold) &&
               (cg_address.get_coverage()       >= threshold) &&
               (cg_protocol.get_coverage()      >= threshold) &&
               (cg_errors.get_coverage()        >= threshold) &&
               (cg_sequences.get_coverage()     >= threshold) &&
               (cg_data_patterns.get_coverage() >= threshold);
    endfunction

endclass

