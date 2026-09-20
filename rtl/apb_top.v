// =============================================================================
// Module: apb_top
// Purpose: Top-level integration wrapper for the complete APB subsystem.
//          Instantiates and wires the master, decoder, mux, and 3 slaves.
//
// Architecture:
//   ┌──────────────────────────────────────────────────────────────────┐
//   │                          apb_top                                 │
//   │                                                                  │
//   │  ┌────────────┐    paddr     ┌──────────────┐                    │
//   │  │            │─────────────►│  apb_decoder │                    │
//   │  │            │              └──────┬───────┘                    │
//   │  │            │   master_sel    ▲   │ pselx[2:0]                 │
//   │  │            │─────────────────┘   │                            │
//   │  │ apb_master │                     ▼                            │
//   │  │            │     ┌──────────────┬──────────────┐              │
//   │  │            │     │              │              │              │
//   │  │            │  ┌──┴──┐        ┌──┴──┐        ┌──┴──┐           │
//   │  │            │  │Slv 0│        │Slv 1│        │Slv 2│           │
//   │  │            │  └──┬──┘        └──┬──┘        └──┬──┘           │
//   │  │            │     │              │              │              │
//   │  │            │     └──────────────┼──────────────┘              │
//   │  │            │                    ▼                             │
//   │  │            │  prdata      ┌──────────────┐                    │
//   │  │            │◄─────────────│   apb_mux    │                    │
//   │  │            │  pready      │              │                    │
//   │  │            │◄─────────────│              │                    │
//   │  │            │  pslverr     │              │                    │
//   │  │            │◄─────────────│              │                    │
//   │  └────────────┘              └──────────────┘                    │
//   └──────────────────────────────────────────────────────────────────┘
//
// Address Map (default):
//   Slave 0: 0x0000_0000 – 0x0000_00FF  (256 bytes, 64 registers)
//   Slave 1: 0x0000_0100 – 0x0000_01FF  (256 bytes, 64 registers)
//   Slave 2: 0x0000_0200 – 0x0000_02FF  (256 bytes, 64 registers)
// =============================================================================

module apb_top (
    // Clock & Reset
    input  wire        pclk,
    input  wire        presetn,

    // Transfer request interface (from testbench / higher-level controller)
    input  wire        transfer_req,
    input  wire [31:0] transfer_addr,
    input  wire        transfer_write,
    input  wire [31:0] transfer_wdata,

    // Transfer response interface (back to testbench / controller)
    output wire [31:0] transfer_rdata,
    output wire        transfer_ready,
    output wire        transfer_error
);

    // =========================================================================
    // Internal Signal Declarations
    // =========================================================================

    // Master → Bus signals
    wire [31:0] paddr;
    wire        master_psel;    // Master's aggregate PSELx (HIGH during SETUP/ACCESS)
    wire        penable;
    wire        pwrite;
    wire [31:0] pwdata;

    // Decoder → Slaves (one-hot slave select)
    wire [2:0]  pselx;

    // Slave 0 response signals
    wire [31:0] slave0_prdata;
    wire        slave0_pready;
    wire        slave0_pslverr;

    // Slave 1 response signals
    wire [31:0] slave1_prdata;
    wire        slave1_pready;
    wire        slave1_pslverr;

    // Slave 2 response signals
    wire [31:0] slave2_prdata;
    wire        slave2_pready;
    wire        slave2_pslverr;

    // Mux → Master (muxed slave responses)
    wire [31:0] mux_prdata;
    wire        mux_pready;
    wire        mux_pslverr;

    // =========================================================================
    // Module 1: APB Master
    // =========================================================================
    // Drives PADDR, PENABLE, PWRITE, PWDATA based on transfer requests.
    // Receives muxed PRDATA/PREADY/PSLVERR from the slave response mux.
    // =========================================================================
    apb_master u_master (
        // Clock & Reset
        .pclk           (pclk),
        .presetn        (presetn),

        // Transfer request interface (from external)
        .transfer_req   (transfer_req),
        .transfer_addr  (transfer_addr),
        .transfer_write (transfer_write),
        .transfer_wdata (transfer_wdata),

        // APB slave response (from mux)
        .prdata         (mux_prdata),
        .pready         (mux_pready),
        .pslverr        (mux_pslverr),

        // APB bus outputs
        .paddr          (paddr),
        .pselx          (master_psel),
        .penable        (penable),
        .pwrite         (pwrite),
        .pwdata         (pwdata),

        // Transfer response (to external)
        .transfer_rdata (transfer_rdata),
        .transfer_ready (transfer_ready),
        .transfer_error (transfer_error)
    );

    // =========================================================================
    // Module 2: APB Address Decoder
    // =========================================================================
    // Decodes PADDR into one-hot PSELx[2:0], gated by master_psel.
    // Only asserts a slave select when the master is actively driving a transfer.
    // =========================================================================
    apb_decoder u_decoder (
        .paddr      (paddr),
        .master_sel (master_psel),
        .pselx      (pselx)
    );

    // =========================================================================
    // Module 3: APB Slave 0  (Address: 0x0000_0000 – 0x0000_00FF)
    // =========================================================================
    apb_slave #(
        .DATA_WIDTH  (32),
        .REG_DEPTH   (16),
        .WAIT_CYCLES (0)            // No wait states
    ) u_slave0 (
        .pclk    (pclk),
        .presetn (presetn),
        .psel    (pselx[0]),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (slave0_prdata),
        .pready  (slave0_pready),
        .pslverr (slave0_pslverr)
    );

    // =========================================================================
    // Module 4: APB Slave 1  (Address: 0x0000_0100 – 0x0000_01FF)
    // =========================================================================
    apb_slave #(
        .DATA_WIDTH  (32),
        .REG_DEPTH   (16),
        .WAIT_CYCLES (0)            // No wait states
    ) u_slave1 (
        .pclk    (pclk),
        .presetn (presetn),
        .psel    (pselx[1]),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (slave1_prdata),
        .pready  (slave1_pready),
        .pslverr (slave1_pslverr)
    );

    // =========================================================================
    // Module 5: APB Slave 2  (Address: 0x0000_0200 – 0x0000_02FF)
    //           Configured with 1 wait cycle for protocol testing
    // =========================================================================
    apb_slave #(
        .DATA_WIDTH  (32),
        .REG_DEPTH   (16),
        .WAIT_CYCLES (1)            // 1 wait cycle — tests wait-state path
    ) u_slave2 (
        .pclk    (pclk),
        .presetn (presetn),
        .psel    (pselx[2]),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (slave2_prdata),
        .pready  (slave2_pready),
        .pslverr (slave2_pslverr)
    );

    // =========================================================================
    // Module 6: APB Slave Response Multiplexer
    // =========================================================================
    // Routes the selected slave's PRDATA/PREADY/PSLVERR back to the master.
    // Defaults to PREADY=1, PRDATA=0, PSLVERR=0 when no slave is selected.
    // =========================================================================
    apb_mux u_mux (
        // Slave select (from decoder)
        .pselx          (pselx),

        // Slave 0 responses
        .slave0_prdata  (slave0_prdata),
        .slave0_pready  (slave0_pready),
        .slave0_pslverr (slave0_pslverr),

        // Slave 1 responses
        .slave1_prdata  (slave1_prdata),
        .slave1_pready  (slave1_pready),
        .slave1_pslverr (slave1_pslverr),

        // Slave 2 responses
        .slave2_prdata  (slave2_prdata),
        .slave2_pready  (slave2_pready),
        .slave2_pslverr (slave2_pslverr),

        // Muxed output to master
        .prdata         (mux_prdata),
        .pready         (mux_pready),
        .pslverr        (mux_pslverr)
    );

endmodule
