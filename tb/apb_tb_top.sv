// =============================================================================
// File:    apb_tb_top.sv
// Purpose: Top-level testbench module — ties everything together.
//
//          This is the single entry point for simulation. It:
//            1. Generates clock (pclk) and reset (presetn)
//            2. Instantiates the APB interface (apb_if)
//            3. Instantiates the DUT (apb_top) and connects to interface
//            4. Wires internal DUT signals to interface for monitoring
//            5. Instantiates SVA assertion checker module
//            6. Creates the testbench environment (driver, monitor, etc.)
//            7. Selects and runs the test via +test$plusargs
//            8. Generates waveform dumps (VCD and/or WLF)
//            9. Prints final report and exits
//
// Running a test:
//   vsim -batch work.apb_tb_top +test_single_write +WAVE_EN -do "run -all"
//   vsim -batch work.apb_tb_top +test_random_stress_1000 -do "run -all"
// =============================================================================

`timescale 1ns / 1ps

// =============================================================================
// Include all TB source files (compile order matters)
// =============================================================================
// Package and interface are compiled as separate files by the Makefile,
// but the class-based components are included here for simplicity.
// =============================================================================
`include "apb_transaction.sv"
`include "apb_driver.sv"
`include "apb_monitor.sv"
`include "apb_scoreboard.sv"
`include "apb_coverage.sv"
`include "apb_env.sv"
`include "apb_test_lib.sv"

module apb_tb_top;

    // =========================================================================
    // Clock & Reset Parameters
    // =========================================================================
    parameter CLK_PERIOD   = 10;       // 100 MHz (10ns period)
    parameter RESET_CYCLES = 5;        // Hold reset for 5 clock cycles

    // =========================================================================
    // Clock & Reset Signals
    // =========================================================================
    reg pclk;
    reg presetn;

    // =========================================================================
    // Clock Generation
    // =========================================================================
    // 100 MHz clock: 5ns HIGH, 5ns LOW
    // =========================================================================
    initial pclk = 0;
    always #(CLK_PERIOD / 2) pclk = ~pclk;

    // =========================================================================
    // Interface Instantiation
    // =========================================================================
    // The interface bundles all signals between TB and DUT.
    // Clock and reset are passed as ports.
    // =========================================================================
    apb_if apb_vif (
        .pclk    (pclk),
        .presetn (presetn)
    );

    // =========================================================================
    // DUT Instantiation (apb_top)
    // =========================================================================
    // Connect the DUT's top-level ports to the interface signals.
    // The DUT's internal signals are accessed via hierarchical references
    // below (for monitoring and assertions).
    // =========================================================================
    apb_top u_dut (
        // Clock & Reset
        .pclk            (pclk),
        .presetn         (presetn),

        // Transfer request interface (driven by testbench via interface)
        .transfer_req    (apb_vif.transfer_req),
        .transfer_addr   (apb_vif.transfer_addr),
        .transfer_write  (apb_vif.transfer_write),
        .transfer_wdata  (apb_vif.transfer_wdata),

        // Transfer response interface (observed by testbench via interface)
        .transfer_rdata  (apb_vif.transfer_rdata),
        .transfer_ready  (apb_vif.transfer_ready),
        .transfer_error  (apb_vif.transfer_error)
    );

    // =========================================================================
    // Internal Signal Wiring (Hierarchical References)
    // =========================================================================
    // Expose DUT-internal APB bus signals to the interface so the Monitor,
    // Coverage, and Assertions can observe the actual protocol activity.
    //
    // These are CONTINUOUS assignments — they track the DUT signals in
    // real time. The monitor samples them via mon_cb clocking block.
    //
    // Hierarchical paths match the instance names in apb_top.v:
    //   u_dut.u_master  → apb_master instance
    //   u_dut.u_master.u_fsm → apb_master_fsm instance
    //   u_dut.u_decoder → apb_decoder instance
    //   u_dut.u_mux     → apb_mux instance
    // =========================================================================

    // Master bus outputs
    assign apb_vif.paddr       = u_dut.paddr;
    assign apb_vif.master_psel = u_dut.master_psel;
    assign apb_vif.penable     = u_dut.penable;
    assign apb_vif.pwrite      = u_dut.pwrite;
    assign apb_vif.pwdata      = u_dut.pwdata;

    // Decoder output (one-hot slave select)
    assign apb_vif.decoded_psel = u_dut.pselx;

    // Muxed slave response
    assign apb_vif.prdata  = u_dut.mux_prdata;
    assign apb_vif.pready  = u_dut.mux_pready;
    assign apb_vif.pslverr = u_dut.mux_pslverr;

    // Master FSM state
    assign apb_vif.current_state = u_dut.u_master.u_fsm.current_state;

    // =========================================================================
    // SVA Assertion Module Instantiation
    // =========================================================================
    // Connects the assertion checker to the same internal signals.
    // Assertions fire continuously on every posedge pclk.
    // =========================================================================
    apb_assertions u_assertions (
        .pclk          (pclk),
        .presetn       (presetn),
        .paddr         (u_dut.paddr),
        .master_psel   (u_dut.master_psel),
        .penable       (u_dut.penable),
        .pwrite        (u_dut.pwrite),
        .pwdata        (u_dut.pwdata),
        .decoded_psel  (u_dut.pselx),
        .prdata        (u_dut.mux_prdata),
        .pready        (u_dut.mux_pready),
        .pslverr       (u_dut.mux_pslverr),
        .current_state (u_dut.u_master.u_fsm.current_state),
        .transfer_req  (apb_vif.transfer_req)
    );

    // =========================================================================
    // Waveform Dump
    // =========================================================================
    // Generates VCD (portable) and/or WLF (QuestaSim native) waveform files.
    // Controlled via plusargs: +WAVE_EN to enable waveform dumping.
    // =========================================================================
    initial begin
        if ($test$plusargs("WAVE_EN")) begin
            // VCD dump (portable — works with GTKWave, etc.)
            $dumpfile("apb_sim.vcd");
            $dumpvars(0, apb_tb_top);
            $display("[TB_TOP] VCD waveform dump enabled: apb_sim.vcd");
        end
    end

    // =========================================================================
    // Reset Generation
    // =========================================================================
    // Active-LOW asynchronous reset.
    // Asserted (LOW) at time 0, held for RESET_CYCLES clock cycles,
    // then deasserted (HIGH) to allow normal operation.
    // =========================================================================
    initial begin
        presetn = 1'b0;     // Assert reset
        $display("[TB_TOP] [%0t] Reset asserted.", $time);
        repeat (RESET_CYCLES) @(posedge pclk);
        presetn = 1'b1;     // Release reset
        $display("[TB_TOP] [%0t] Reset deasserted.", $time);
    end

    // =========================================================================
    // Test Execution
    // =========================================================================
    // 1. Create the environment
    // 2. Build all components
    // 3. Start all components (fork in background)
    // 4. Select and run the chosen test via +plusargs
    // 5. Wait for test to complete
    // 6. Print report
    // 7. Finish simulation
    // =========================================================================
    initial begin
        // Declare environment and test handles
        apb_env                  env;
        test_single_write        tc_001;
        test_single_read         tc_002;
        test_write_read_all_slaves tc_003;
        test_all_registers_slave0  tc_004;
        test_all_registers_slave1  tc_005;
        test_all_registers_slave2  tc_006;
        test_wait_state_timing     tc_007;
        test_back_to_back_same_slave tc_008;
        test_back_to_back_diff_slave tc_009;
        test_b2b_write_read        tc_010;
        test_b2b_read_read         tc_011;
        test_b2b_read_write        tc_012;
        test_unaligned_addr        tc_013;
        test_invalid_addr_range    tc_014;
        test_reset_during_idle     tc_015;
        test_reset_during_transfer tc_016;
        test_reset_clears_registers tc_017;
        test_data_walking_ones     tc_018;
        test_data_walking_zeros    tc_019;
        test_data_all_ones_zeros   tc_020;
        test_data_checkerboard     tc_021;
        test_random_stress_100     tc_022;
        test_random_stress_1000    tc_023;
        test_random_stress_10000   tc_024;
        test_slave2_burst_wait     tc_025;

        // ---------------------------------------------------------------
        // Wait for reset to complete
        // ---------------------------------------------------------------
        @(posedge presetn);
        @(posedge pclk);

        // ---------------------------------------------------------------
        // Build Environment
        // ---------------------------------------------------------------
        $display("[TB_TOP] [%0t] Creating environment...", $time);
        env = new(apb_vif);
        env.build();

        // ---------------------------------------------------------------
        // Start All Components
        // ---------------------------------------------------------------
        $display("[TB_TOP] [%0t] Starting environment...", $time);
        env.run();

        // Allow components to initialize (wait a few clocks)
        repeat (2) @(posedge pclk);

        // ---------------------------------------------------------------
        // Test Selection via $test$plusargs
        // ---------------------------------------------------------------
        $display("[TB_TOP] [%0t] Selecting test...", $time);

        if ($test$plusargs("test_single_write")) begin
            tc_001 = new(env);
            tc_001.run();
        end
        else if ($test$plusargs("test_single_read")) begin
            tc_002 = new(env);
            tc_002.run();
        end
        else if ($test$plusargs("test_write_read_all_slaves")) begin
            tc_003 = new(env);
            tc_003.run();
        end
        else if ($test$plusargs("test_all_registers_slave0")) begin
            tc_004 = new(env);
            tc_004.run();
        end
        else if ($test$plusargs("test_all_registers_slave1")) begin
            tc_005 = new(env);
            tc_005.run();
        end
        else if ($test$plusargs("test_all_registers_slave2")) begin
            tc_006 = new(env);
            tc_006.run();
        end
        else if ($test$plusargs("test_wait_state_timing")) begin
            tc_007 = new(env);
            tc_007.run();
        end
        else if ($test$plusargs("test_back_to_back_same_slave")) begin
            tc_008 = new(env);
            tc_008.run();
        end
        else if ($test$plusargs("test_back_to_back_diff_slave")) begin
            tc_009 = new(env);
            tc_009.run();
        end
        else if ($test$plusargs("test_b2b_write_read")) begin
            tc_010 = new(env);
            tc_010.run();
        end
        else if ($test$plusargs("test_b2b_read_read")) begin
            tc_011 = new(env);
            tc_011.run();
        end
        else if ($test$plusargs("test_b2b_read_write")) begin
            tc_012 = new(env);
            tc_012.run();
        end
        else if ($test$plusargs("test_unaligned_addr")) begin
            tc_013 = new(env);
            tc_013.run();
        end
        else if ($test$plusargs("test_invalid_addr_range")) begin
            tc_014 = new(env);
            tc_014.run();
        end
        else if ($test$plusargs("test_reset_during_idle")) begin
            tc_015 = new(env);
            tc_015.run();
        end
        else if ($test$plusargs("test_reset_during_transfer")) begin
            tc_016 = new(env);
            tc_016.run();
        end
        else if ($test$plusargs("test_reset_clears_registers")) begin
            tc_017 = new(env);
            tc_017.run();
        end
        else if ($test$plusargs("test_data_walking_ones")) begin
            tc_018 = new(env);
            tc_018.run();
        end
        else if ($test$plusargs("test_data_walking_zeros")) begin
            tc_019 = new(env);
            tc_019.run();
        end
        else if ($test$plusargs("test_data_all_ones_zeros")) begin
            tc_020 = new(env);
            tc_020.run();
        end
        else if ($test$plusargs("test_data_checkerboard")) begin
            tc_021 = new(env);
            tc_021.run();
        end
        else if ($test$plusargs("test_random_stress_100")) begin
            tc_022 = new(env);
            tc_022.run();
        end
        else if ($test$plusargs("test_random_stress_1000")) begin
            tc_023 = new(env);
            tc_023.run();
        end
        else if ($test$plusargs("test_random_stress_10000")) begin
            tc_024 = new(env);
            tc_024.run();
        end
        else if ($test$plusargs("test_slave2_burst_wait")) begin
            tc_025 = new(env);
            tc_025.run();
        end
        else begin
            // Default test: run TC_001 (single write smoke test)
            $display("[TB_TOP] No test specified via +plusargs. Running default: test_single_write");
            tc_001 = new(env);
            tc_001.run();
        end

        // ---------------------------------------------------------------
        // Wait for all pending transactions to complete
        // ---------------------------------------------------------------
        $display("[TB_TOP] [%0t] Test task completed. Draining pipeline...", $time);
        repeat (20) @(posedge pclk);

        // ---------------------------------------------------------------
        // Print Final Report
        // ---------------------------------------------------------------
        env.report();

        // ---------------------------------------------------------------
        // End Simulation
        // ---------------------------------------------------------------
        $display("[TB_TOP] [%0t] Simulation finished.", $time);
        $finish;
    end

    // =========================================================================
    // Simulation Timeout (Safety Net)
    // =========================================================================
    // Prevents simulation from running forever if something hangs.
    // Default: 10ms simulation time (= 1,000,000 clock cycles at 100MHz).
    // Override via $value$plusargs if needed.
    // =========================================================================
    initial begin
        int timeout_ns;

        if (!$value$plusargs("TIMEOUT=%d", timeout_ns))
            timeout_ns = 10_000_000;     // Default: 10ms

        #(timeout_ns);
        $display("[TB_TOP] [%0t] *** SIMULATION TIMEOUT (%0d ns) ***", $time, timeout_ns);
        $display("[TB_TOP] The simulation exceeded the maximum allowed time.");
        $display("[TB_TOP] This may indicate a hang in the DUT or testbench.");
        $finish;
    end

endmodule

