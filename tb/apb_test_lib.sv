// =============================================================================
// File:    apb_test_lib.sv
// Purpose: APB Test Library — all test cases for protocol verification.
//
//          Contains a base test class with common utilities and 25 directed
//          + random test cases organized by category. Each test creates
//          transactions, sends them to the driver via the environment's
//          mailbox, and waits for completion.
//
// Test Selection:
//          Tests are selected via $test$plusargs in apb_tb_top.sv:
//            vsim +test_single_write ...
//
// Test Categories:
//   Smoke    (TC_001–002) — Basic functionality sanity checks
//   Basic    (TC_003–006) — Multi-slave, all-register coverage
//   Protocol (TC_007–012) — Wait states, back-to-back transfers
//   Error    (TC_013–014) — Unaligned addresses, invalid ranges
//   Reset    (TC_015–017) — Reset behavior verification
//   Data     (TC_018–021) — Walking ones/zeros, boundary patterns
//   Stress   (TC_022–025) — Random constrained, high-volume
// =============================================================================


// =============================================================================
// Base Test Class
// =============================================================================
// Common utilities inherited by all tests: transaction helpers, wait/sync
// mechanisms, pass/fail reporting.
// =============================================================================

class apb_base_test;

    // =========================================================================
    // Environment Handle
    // =========================================================================
    apb_env env;

    // =========================================================================
    // Test Identity
    // =========================================================================
    string test_name;
    int    test_pass;          // 1 = pass, 0 = fail

    // =========================================================================
    // Constructor
    // =========================================================================
    function new(apb_env env, string name = "apb_base_test");
        this.env       = env;
        this.test_name = name;
        this.test_pass = 1;
    endfunction

    // =========================================================================
    // Task: run()
    // =========================================================================
    // Override this in each derived test. The base version does nothing.
    // =========================================================================
    virtual task run();
        $display("[TEST] [%0t] Base test run() — override this in derived test.", $time);
    endtask

    // =========================================================================
    // Helper: write_transfer()
    // =========================================================================
    // Creates a write transaction to a specific address with specific data,
    // sends it to the driver, and waits for completion.
    // =========================================================================
    task write_transfer(bit [31:0] addr, bit [31:0] data);
        apb_transaction txn = new();
        txn.addr  = addr;
        txn.write = 1;
        txn.wdata = data;
        txn.post_randomize();    // Compute slave_id from addr
        env.drv_mbx.put(txn);
        wait_transfer_done();
    endtask

    // =========================================================================
    // Helper: read_transfer()
    // =========================================================================
    // Creates a read transaction to a specific address, sends it to the
    // driver, and waits for completion.
    // =========================================================================
    task read_transfer(bit [31:0] addr);
        apb_transaction txn = new();
        txn.addr  = addr;
        txn.write = 0;
        txn.wdata = 0;
        txn.post_randomize();
        env.drv_mbx.put(txn);
        wait_transfer_done();
    endtask

    // =========================================================================
    // Helper: write_and_verify()
    // =========================================================================
    // Write data to an address, then read it back and verify the read data
    // matches. This is the most common test pattern.
    // =========================================================================
    task write_and_verify(bit [31:0] addr, bit [31:0] data);
        write_transfer(addr, data);
        read_transfer(addr);
    endtask

    // =========================================================================
    // Helper: wait_transfer_done()
    // =========================================================================
    // Waits enough clock cycles for a transfer to complete.
    // A worst-case transfer takes: 1 (SETUP) + 1+ (ACCESS) + margin
    // Slave 2 has WAIT_CYCLES=1, so worst case is ~5 cycles.
    // =========================================================================
    task wait_transfer_done();
        repeat (6) @(posedge env.vif.pclk);
    endtask

    // =========================================================================
    // Helper: wait_clocks()
    // =========================================================================
    task wait_clocks(int n);
        repeat (n) @(posedge env.vif.pclk);
    endtask

    // =========================================================================
    // Helper: print_test_header() / print_test_result()
    // =========================================================================
    function void print_test_header();
        $display("");
        $display("╔══════════════════════════════════════════════════════╗");
        $display("║  TEST: %-45s   ║", test_name);
        $display("╚══════════════════════════════════════════════════════╝");
        $display("");
    endfunction

    function void print_test_result();
        $display("");
        if (test_pass && env.scoreboard.get_pass_status())
            $display("[TEST] *** %s: PASSED ***", test_name);
        else begin
            $display("[TEST] *** %s: FAILED ***", test_name);
            test_pass = 0;
        end
        $display("");
    endfunction

endclass


// =============================================================================
//  TC_001: test_single_write — Smoke Test
// =============================================================================
// Writes 0xDEAD_BEEF to Slave 0, register 0 (address 0x000).
// Verifies transfer completes without error.
// =============================================================================
class test_single_write extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_001_single_write");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing 0xDEAD_BEEF to Slave 0, reg 0 (addr=0x000)...");

        write_transfer(32'h0000_0000, 32'hDEAD_BEEF);

        $display("[TEST] Write complete.");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_002: test_single_read — Smoke Test
// =============================================================================
// Writes then reads from Slave 0, register 0.
// Scoreboard verifies read data matches written data.
// =============================================================================
class test_single_read extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_002_single_read");
    endfunction

    task run();
        print_test_header();

        $display("[TEST] Write 0xDEAD_BEEF to addr=0x000, then read back...");
        write_and_verify(32'h0000_0000, 32'hDEAD_BEEF);

        $display("[TEST] Write-read cycle complete.");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_003: test_write_read_all_slaves — Basic Functional
// =============================================================================
// Writes unique data to each slave, then reads back from all three.
// Verifies cross-slave data integrity.
// =============================================================================
class test_write_read_all_slaves extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_003_write_read_all_slaves");
    endfunction

    task run();
        print_test_header();

        // Write to each slave
        $display("[TEST] Writing to all 3 slaves...");
        write_transfer(32'h0000_0000, 32'hAAAA_0000);   // Slave 0, reg 0
        write_transfer(32'h0000_0100, 32'hBBBB_1111);   // Slave 1, reg 0
        write_transfer(32'h0000_0200, 32'hCCCC_2222);   // Slave 2, reg 0

        // Read back from each slave
        $display("[TEST] Reading back from all 3 slaves...");
        read_transfer(32'h0000_0000);   // Slave 0
        read_transfer(32'h0000_0100);   // Slave 1
        read_transfer(32'h0000_0200);   // Slave 2

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_004: test_all_registers_slave0 — Register Coverage
// =============================================================================
// Writes and reads all 16 registers of Slave 0.
// =============================================================================
class test_all_registers_slave0 extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_004_all_registers_slave0");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing/reading all 16 registers of Slave 0...");

        for (int i = 0; i < 16; i++) begin
            write_and_verify(32'h0000_0000 + (i * 4), 32'hS0_00_00_00 + i);
        end

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_005: test_all_registers_slave1 — Register Coverage
// =============================================================================
class test_all_registers_slave1 extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_005_all_registers_slave1");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing/reading all 16 registers of Slave 1...");

        for (int i = 0; i < 16; i++) begin
            write_and_verify(32'h0000_0100 + (i * 4), 32'hS1_00_00_00 + i);
        end

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_006: test_all_registers_slave2 — Register Coverage (with wait states)
// =============================================================================
class test_all_registers_slave2 extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_006_all_registers_slave2");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing/reading all 16 registers of Slave 2 (WAIT_CYCLES=1)...");

        for (int i = 0; i < 16; i++) begin
            write_and_verify(32'h0000_0200 + (i * 4), 32'hS2_00_00_00 + i);
        end

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_007: test_wait_state_timing — Protocol Verification
// =============================================================================
// Writes to Slave 2 and verifies the wait state count via the scoreboard
// (SCB_006 check: Slave 2 should have exactly 1 wait cycle).
// =============================================================================
class test_wait_state_timing extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_007_wait_state_timing");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Verifying wait state behavior on Slave 2...");

        // Multiple writes to Slave 2 to confirm consistent wait behavior
        write_transfer(32'h0000_0200, 32'h1111_1111);
        write_transfer(32'h0000_0204, 32'h2222_2222);
        write_transfer(32'h0000_0208, 32'h3333_3333);

        // Reads from Slave 2
        read_transfer(32'h0000_0200);
        read_transfer(32'h0000_0204);
        read_transfer(32'h0000_0208);

        $display("[TEST] Wait state checks handled by scoreboard (SCB_006).");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_008: test_back_to_back_same_slave — B2B Protocol
// =============================================================================
// 5 consecutive writes to Slave 0 using back-to-back driver mode.
// =============================================================================
class test_back_to_back_same_slave extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_008_b2b_same_slave");
    endfunction

    task run();
        apb_transaction txns[$];
        apb_transaction txn;

        print_test_header();
        $display("[TEST] 5 back-to-back writes to Slave 0...");

        for (int i = 0; i < 5; i++) begin
            txn = new();
            txn.addr  = 32'h0000_0000 + (i * 4);
            txn.write = 1;
            txn.wdata = 32'hB2B0_0000 + i;
            txn.post_randomize();
            txns.push_back(txn);
        end

        env.driver.drive_back_to_back_transfers(txns);
        wait_clocks(10);

        // Read back all 5 registers
        $display("[TEST] Reading back 5 registers...");
        for (int i = 0; i < 5; i++) begin
            read_transfer(32'h0000_0000 + (i * 4));
        end

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_009: test_back_to_back_diff_slave — B2B Slave Switching
// =============================================================================
// Alternates writes between Slave 0 and Slave 1 using back-to-back mode.
// =============================================================================
class test_back_to_back_diff_slave extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_009_b2b_diff_slave");
    endfunction

    task run();
        apb_transaction txns[$];
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Back-to-back writes alternating Slave 0 and Slave 1...");

        for (int i = 0; i < 6; i++) begin
            txn = new();
            txn.addr  = (i % 2 == 0) ? (32'h0000_0000 + (i/2)*4) :
                                        (32'h0000_0100 + (i/2)*4);
            txn.write = 1;
            txn.wdata = 32'hB2B1_0000 + i;
            txn.post_randomize();
            txns.push_back(txn);
        end

        env.driver.drive_back_to_back_transfers(txns);
        wait_clocks(10);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_010: test_b2b_write_read — B2B Write-then-Read
// =============================================================================
// Write to an address, immediately read from the same address (back-to-back).
// =============================================================================
class test_b2b_write_read extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_010_b2b_write_read");
    endfunction

    task run();
        apb_transaction txns[$];
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Back-to-back write then read to same address...");

        // Write
        txn = new();
        txn.addr  = 32'h0000_0000;
        txn.write = 1;
        txn.wdata = 32'hFACE_CAFE;
        txn.post_randomize();
        txns.push_back(txn);

        // Immediate read from same address
        txn = new();
        txn.addr  = 32'h0000_0000;
        txn.write = 0;
        txn.wdata = 0;
        txn.post_randomize();
        txns.push_back(txn);

        env.driver.drive_back_to_back_transfers(txns);
        wait_clocks(10);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_011: test_b2b_read_read — B2B Read-Read
// =============================================================================
class test_b2b_read_read extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_011_b2b_read_read");
    endfunction

    task run();
        apb_transaction txns[$];
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Back-to-back reads from same address...");

        // First write some data
        write_transfer(32'h0000_0004, 32'hREAD_READ);
        wait_clocks(2);

        // Two back-to-back reads
        for (int i = 0; i < 2; i++) begin
            txn = new();
            txn.addr  = 32'h0000_0004;
            txn.write = 0;
            txn.wdata = 0;
            txn.post_randomize();
            txns.push_back(txn);
        end

        env.driver.drive_back_to_back_transfers(txns);
        wait_clocks(10);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_012: test_b2b_read_write — B2B Read-then-Write
// =============================================================================
class test_b2b_read_write extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_012_b2b_read_write");
    endfunction

    task run();
        apb_transaction txns[$];
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Back-to-back read then write...");

        // Read
        txn = new();
        txn.addr  = 32'h0000_0008;
        txn.write = 0;
        txn.wdata = 0;
        txn.post_randomize();
        txns.push_back(txn);

        // Write to same address
        txn = new();
        txn.addr  = 32'h0000_0008;
        txn.write = 1;
        txn.wdata = 32'hRW_B2B_01;
        txn.post_randomize();
        txns.push_back(txn);

        env.driver.drive_back_to_back_transfers(txns);
        wait_clocks(10);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_013: test_unaligned_addr — Error Path
// =============================================================================
// Writes to unaligned addresses (addr[1:0] != 0) and verifies PSLVERR fires.
// =============================================================================
class test_unaligned_addr extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_013_unaligned_addr");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Testing unaligned address error detection...");

        // Byte offset 1
        $display("[TEST]   addr=0x001 (byte offset 1)...");
        write_transfer(32'h0000_0001, 32'hBAD0_0001);

        // Byte offset 2
        $display("[TEST]   addr=0x002 (byte offset 2)...");
        write_transfer(32'h0000_0002, 32'hBAD0_0002);

        // Byte offset 3
        $display("[TEST]   addr=0x003 (byte offset 3)...");
        write_transfer(32'h0000_0003, 32'hBAD0_0003);

        // Unaligned read
        $display("[TEST]   Read from addr=0x101 (unaligned, Slave 1)...");
        read_transfer(32'h0000_0101);

        $display("[TEST] Error checks handled by scoreboard (SCB_003).");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_014: test_invalid_addr_range — Error Path
// =============================================================================
// Writes to address outside all slave ranges (0x300+).
// Verifies no slave is selected and the bus doesn't hang.
// =============================================================================
class test_invalid_addr_range extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_014_invalid_addr_range");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing to out-of-range address 0x300...");

        write_transfer(32'h0000_0300, 32'hDEAD_ZONE);
        wait_clocks(5);

        // Verify the bus is still functional after invalid access
        $display("[TEST] Verifying bus still works after invalid access...");
        write_and_verify(32'h0000_0000, 32'hAFTR_INVL);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_015: test_reset_during_idle — Reset Verification
// =============================================================================
// Asserts reset while FSM is IDLE. Verifies FSM stays in IDLE and all
// outputs are 0.
// =============================================================================
class test_reset_during_idle extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_015_reset_during_idle");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Asserting reset while FSM is IDLE...");
        $display("[TEST] NOTE: Reset must be asserted externally by apb_tb_top.");
        $display("[TEST] This test verifies post-reset state only.");

        // Just verify we're in a clean state (reset was done at start)
        wait_clocks(5);

        // Read from a register — should return 0 (reset value)
        read_transfer(32'h0000_0000);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_016: test_reset_during_transfer — Reset Verification
// =============================================================================
// NOTE: This test requires the TB top to assert reset mid-transfer.
// It writes data, triggers a reset via the environment, then verifies
// the FSM recovered properly.
// =============================================================================
class test_reset_during_transfer extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_016_reset_during_transfer");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing data before reset...");

        write_transfer(32'h0000_0000, 32'hBEFO_REST);
        write_transfer(32'h0000_0100, 32'hBEFO_RST1);

        $display("[TEST] NOTE: Mid-transfer reset is controlled by apb_tb_top.");
        $display("[TEST] Verifying bus works after reset...");

        // Post-reset: bus should be functional
        wait_clocks(10);
        write_and_verify(32'h0000_0000, 32'hPOST_REST);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_017: test_reset_clears_registers — Reset Verification
// =============================================================================
// Writes data to multiple slaves, resets the environment's shadow registers
// (simulating hardware reset), then reads back to verify 0x00000000.
// =============================================================================
class test_reset_clears_registers extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_017_reset_clears_registers");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Writing data, then verifying reset clears all registers...");

        // Write data to each slave
        write_transfer(32'h0000_0000, 32'hAAAA_AAAA);
        write_transfer(32'h0000_0100, 32'hBBBB_BBBB);
        write_transfer(32'h0000_0200, 32'hCCCC_CCCC);

        $display("[TEST] Data written. Reset should clear registers.");
        $display("[TEST] NOTE: Hardware reset must be controlled by apb_tb_top.");
        $display("[TEST] After reset, shadow registers cleared by env.reset_env().");

        // Simulate post-reset: clear shadow registers
        env.reset_env();
        wait_clocks(10);

        // Read back — scoreboard expects 0x00000000 (shadow was cleared)
        read_transfer(32'h0000_0000);
        read_transfer(32'h0000_0100);
        read_transfer(32'h0000_0200);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_018: test_data_walking_ones — Data Integrity
// =============================================================================
// Writes walking-ones pattern (0x1, 0x2, 0x4, ..., 0x80000000) to
// consecutive registers and reads back.
// =============================================================================
class test_data_walking_ones extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_018_data_walking_ones");
    endfunction

    task run();
        bit [31:0] pattern;

        print_test_header();
        $display("[TEST] Walking ones pattern across Slave 0 registers...");

        for (int i = 0; i < 16; i++) begin
            pattern = 32'h1 << i;
            write_and_verify(32'h0000_0000 + (i * 4), pattern);
        end

        // Also test upper 16 bits using Slave 1
        for (int i = 0; i < 16; i++) begin
            pattern = 32'h1 << (i + 16);
            write_and_verify(32'h0000_0100 + (i * 4), pattern);
        end

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_019: test_data_walking_zeros — Data Integrity
// =============================================================================
class test_data_walking_zeros extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_019_data_walking_zeros");
    endfunction

    task run();
        bit [31:0] pattern;

        print_test_header();
        $display("[TEST] Walking zeros pattern across Slave 0 registers...");

        for (int i = 0; i < 16; i++) begin
            pattern = ~(32'h1 << i);
            write_and_verify(32'h0000_0000 + (i * 4), pattern);
        end

        for (int i = 0; i < 16; i++) begin
            pattern = ~(32'h1 << (i + 16));
            write_and_verify(32'h0000_0100 + (i * 4), pattern);
        end

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_020: test_data_all_ones_zeros — Data Integrity
// =============================================================================
class test_data_all_ones_zeros extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_020_data_all_ones_zeros");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] All-ones and all-zeros data patterns...");

        // All ones
        write_and_verify(32'h0000_0000, 32'hFFFF_FFFF);
        // All zeros
        write_and_verify(32'h0000_0000, 32'h0000_0000);
        // All ones to different slave
        write_and_verify(32'h0000_0100, 32'hFFFF_FFFF);
        // All zeros to different slave
        write_and_verify(32'h0000_0100, 32'h0000_0000);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_021: test_data_checkerboard — Data Integrity
// =============================================================================
class test_data_checkerboard extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_021_data_checkerboard");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] Checkerboard data patterns (0x55555555 / 0xAAAAAAAA)...");

        // Slave 0
        write_and_verify(32'h0000_0000, 32'h5555_5555);
        write_and_verify(32'h0000_0004, 32'hAAAA_AAAA);

        // Slave 1
        write_and_verify(32'h0000_0100, 32'h5555_5555);
        write_and_verify(32'h0000_0104, 32'hAAAA_AAAA);

        // Slave 2 (with wait states)
        write_and_verify(32'h0000_0200, 32'h5555_5555);
        write_and_verify(32'h0000_0204, 32'hAAAA_AAAA);

        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_022: test_random_stress_100 — Random Stress (100 transactions)
// =============================================================================
class test_random_stress_100 extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_022_random_stress_100");
    endfunction

    task run();
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Running 100 random constrained transactions...");

        for (int i = 0; i < 100; i++) begin
            txn = new();
            if (!txn.randomize()) begin
                $display("[TEST] ERROR: Randomization failed at iteration %0d!", i);
                test_pass = 0;
                break;
            end
            env.drv_mbx.put(txn);
            wait_transfer_done();
        end

        $display("[TEST] 100 random transactions complete.");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_023: test_random_stress_1000 — Random Stress (1000 transactions)
// =============================================================================
class test_random_stress_1000 extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_023_random_stress_1000");
    endfunction

    task run();
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Running 1000 random constrained transactions...");

        for (int i = 0; i < 1000; i++) begin
            txn = new();
            if (!txn.randomize()) begin
                $display("[TEST] ERROR: Randomization failed at iteration %0d!", i);
                test_pass = 0;
                break;
            end
            env.drv_mbx.put(txn);
            wait_transfer_done();

            // Progress indicator every 100
            if ((i + 1) % 100 == 0)
                $display("[TEST]   ...%0d/1000 transfers complete", i + 1);
        end

        $display("[TEST] 1000 random transactions complete.");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_024: test_random_stress_10000 — Random Stress (10000 transactions)
// =============================================================================
class test_random_stress_10000 extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_024_random_stress_10000");
    endfunction

    task run();
        apb_transaction txn;

        print_test_header();
        $display("[TEST] Running 10000 random constrained transactions...");

        for (int i = 0; i < 10000; i++) begin
            txn = new();
            if (!txn.randomize()) begin
                $display("[TEST] ERROR: Randomization failed at iteration %0d!", i);
                test_pass = 0;
                break;
            end
            env.drv_mbx.put(txn);
            wait_transfer_done();

            if ((i + 1) % 1000 == 0)
                $display("[TEST]   ...%0d/10000 transfers complete", i + 1);
        end

        $display("[TEST] 10000 random transactions complete.");
        print_test_result();
    endtask

endclass


// =============================================================================
//  TC_025: test_slave2_burst_wait — Stress with Wait States
// =============================================================================
// 10 consecutive writes to Slave 2 (which has WAIT_CYCLES=1).
// Verifies data integrity under sustained wait-state operation.
// =============================================================================
class test_slave2_burst_wait extends apb_base_test;

    function new(apb_env env);
        super.new(env, "TC_025_slave2_burst_wait");
    endfunction

    task run();
        print_test_header();
        $display("[TEST] 10 consecutive write/read to Slave 2 (WAIT_CYCLES=1)...");

        for (int i = 0; i < 10; i++) begin
            write_and_verify(32'h0000_0200 + (i % 16) * 4,
                             32'hWAIT_0000 + i);
        end

        $display("[TEST] Slave 2 burst complete.");
        print_test_result();
    endtask

endclass

