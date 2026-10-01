// =============================================================================
// File:    apb_env.sv
// Purpose: APB Testbench Environment — assembles and manages all TB components.
//
//          The Environment is the orchestrator. It creates all testbench
//          components (driver, monitor, scoreboard, coverage), connects them
//          via mailboxes, and manages the simulation lifecycle.
//
// Architecture:
//   ┌──────────────────────────────────────────────────────────────────┐
//   │                        apb_env                                   │
//   │                                                                  │
//   │   ┌──────────┐     ┌───────────┐     ┌──────────────┐            │
//   │   │  Driver  │     │  Monitor  │────►│  Scoreboard  │            │
//   │   │          │     │           │     └──────────────┘            │
//   │   └────┬─────┘     └─────┬─────┘                                 │
//   │        │                 │          ┌──────────────┐             │
//   │        │                 └─────────►│  Coverage     │            │
//   │        │                            └──────────────┘             │
//   │        ▼                                                         │
//   │   ┌──────────┐                                                   │
//   │   │  drv_mbx │  ◄── Tests put transactions here                  │
//   │   └──────────┘                                                   │
//   │                                                                  │
//   │   Mailboxes:                                                     │
//   │     drv_mbx : Test → Driver                                      │
//   │     scb_mbx : Monitor → Scoreboard                               │
//   │     cov_mbx : Monitor → Coverage                                 │
//   └──────────────────────────────────────────────────────────────────┘
//
// Lifecycle:
//   1. build()    — Create mailboxes and component instances
//   2. run()      — Fork all component run() tasks in parallel
//   3. report()   — Print statistics from all components
//
// Usage (from test):
//   apb_env env = new(vif);
//   env.build();
//   env.run();               // Forks all components — returns immediately
//   // ... drive transactions via env.drv_mbx ...
//   env.report();
// =============================================================================

class apb_env;

    // =========================================================================
    // Interface Handle
    // =========================================================================
    // The virtual interface is passed in from the TB top and distributed
    // to the driver (DRIVER modport) and monitor (MONITOR modport).
    // =========================================================================
    virtual apb_if      vif;

    // =========================================================================
    // Component Instances
    // =========================================================================
    apb_driver      driver;
    apb_monitor     monitor;
    apb_scoreboard  scoreboard;
    apb_coverage    coverage;

    // =========================================================================
    // Mailboxes (Inter-Component Communication)
    // =========================================================================
    // Three unbounded mailboxes connect the components:
    //
    //   drv_mbx: Test → Driver
    //     Tests create apb_transaction objects and put() them here.
    //     The driver get()s them and converts to pin-level stimulus.
    //
    //   scb_mbx: Monitor → Scoreboard
    //     The monitor captures completed transactions and sends copies
    //     here for correctness checking.
    //
    //   cov_mbx: Monitor → Coverage
    //     The monitor sends copies of completed transactions here
    //     for functional coverage sampling.
    // =========================================================================
    mailbox #(apb_transaction) drv_mbx;
    mailbox #(apb_transaction) scb_mbx;
    mailbox #(apb_transaction) cov_mbx;

    // =========================================================================
    // Constructor
    // =========================================================================
    // Takes the virtual interface handle and stores it. The actual
    // component creation happens in build().
    // =========================================================================
    function new(virtual apb_if vif);
        this.vif = vif;
    endfunction

    // =========================================================================
    // Phase: build()
    // =========================================================================
    // Creates all mailboxes and component instances. Must be called
    // before run(). Separating build from the constructor follows the
    // standard verification methodology pattern (build → connect → run).
    //
    // Order:
    //   1. Create mailboxes
    //   2. Create driver (needs DRIVER modport + drv_mbx)
    //   3. Create monitor (needs MONITOR modport + scb_mbx + cov_mbx)
    //   4. Create scoreboard (needs scb_mbx)
    //   5. Create coverage (needs MONITOR modport + cov_mbx)
    // =========================================================================
    function void build();
        $display("[ENV] [%0t] Building environment...", $time);

        // ---------------------------------------------------------------
        // Create mailboxes
        // ---------------------------------------------------------------
        drv_mbx = new();
        scb_mbx = new();
        cov_mbx = new();

        // ---------------------------------------------------------------
        // Create components
        // ---------------------------------------------------------------
        driver     = new(vif, drv_mbx);
        monitor    = new(vif, scb_mbx, cov_mbx);
        scoreboard = new(scb_mbx);
        coverage   = new(vif, cov_mbx);

        $display("[ENV] [%0t] Environment built: driver, monitor, scoreboard, coverage created.", $time);
    endfunction

    // =========================================================================
    // Phase: run()
    // =========================================================================
    // Forks all component run() tasks in parallel. Each component runs
    // independently and communicates through mailboxes.
    //
    // fork...join_none is used so that run() returns immediately,
    // allowing the test to proceed with driving transactions.
    //
    // Component execution:
    //   - Driver:     waits for reset, then pulls from drv_mbx
    //   - Monitor:    waits for reset, then observes bus continuously
    //   - Scoreboard: waits for transactions from monitor
    //   - Coverage:   waits for transactions + samples FSM every cycle
    // =========================================================================
    task run();
        $display("[ENV] [%0t] Starting all components...", $time);

        fork
            driver.run();
            monitor.run();
            scoreboard.run();
            coverage.run();
        join_none

        $display("[ENV] [%0t] All components forked.", $time);
    endtask

    // =========================================================================
    // Phase: report()
    // =========================================================================
    // Collects and prints statistics from all components. Call this at
    // the end of simulation (before $finish) to get a complete summary.
    //
    // Prints:
    //   1. Driver stats (transfers driven, timeouts)
    //   2. Monitor stats (transfers observed, wait cycles)
    //   3. Scoreboard results (pass/fail checks)
    //   4. Coverage percentages (all covergroups)
    //   5. Overall PASS/FAIL verdict
    // =========================================================================
    function void report();
        bit scb_pass;
        bit cov_pass;

        $display("");
        $display("================================================================");
        $display("           AMBA APB VERIFICATION REPORT");
        $display("================================================================");
        $display("");

        // ---------------------------------------------------------------
        // Individual component reports
        // ---------------------------------------------------------------
        driver.print_stats();
        monitor.print_stats();
        scoreboard.print_stats();
        coverage.print_stats();

        // ---------------------------------------------------------------
        // Overall Verdict
        // ---------------------------------------------------------------
        scb_pass = scoreboard.get_pass_status();
        cov_pass = coverage.is_target_met(95.0);

        $display("");
        $display("================================================================");
        $display("                  OVERALL VERDICT");
        $display("================================================================");
        $display("  Scoreboard  : %s", scb_pass ? "PASSED" : "FAILED");
        $display("  Coverage    : %s", cov_pass ? "MET (>=95%%)" : "NOT MET (<95%%)");
        $display("  ────────────────────────────");

        if (scb_pass && cov_pass)
            $display("  *** SIMULATION PASSED ***");
        else if (scb_pass)
            $display("  *** SIMULATION PASSED (coverage below target) ***");
        else
            $display("  *** SIMULATION FAILED ***");

        $display("================================================================");
        $display("");
    endfunction

    // =========================================================================
    // Function: reset_env()
    // =========================================================================
    // Resets the environment state after a DUT reset. The scoreboard's
    // shadow registers must be cleared to stay in sync with the DUT.
    // Call this whenever the testbench asserts reset mid-simulation.
    // =========================================================================
    function void reset_env();
        $display("[ENV] [%0t] Resetting environment state.", $time);

        // Clear shadow register files (they were zeroed by hardware reset)
        scoreboard.reset_shadow_registers();

        // Reset driver state
        driver.reset_driver();
    endfunction

    // =========================================================================
    // Function: set_driver_idle_cycles()
    // =========================================================================
    // Configures the number of idle cycles the driver inserts between
    // consecutive transfers. Useful for tests that want to control
    // transfer spacing.
    //
    //   0 = back-to-back (fastest)
    //   1 = 1 idle cycle gap
    //   N = N idle cycle gap
    // =========================================================================
    function void set_driver_idle_cycles(int unsigned cycles);
        driver.idle_cycles_between = cycles;
        $display("[ENV] [%0t] Driver idle cycles set to %0d.", $time, cycles);
    endfunction

    // =========================================================================
    // Function: set_driver_timeout()
    // =========================================================================
    // Configures the maximum number of clock cycles the driver will wait
    // for transfer_ready before declaring a timeout.
    // =========================================================================
    function void set_driver_timeout(int unsigned cycles);
        driver.max_wait_cycles = cycles;
        $display("[ENV] [%0t] Driver timeout set to %0d cycles.", $time, cycles);
    endfunction

endclass

