// =============================================================================
// Module: apb_slave
// Purpose: Generic APB completer with an internal register file. Serves as a
//          reusable template for any simple peripheral (UART, GPIO, Timer, etc).
//
// Functionality:
//   - Internal register file: REG_DEPTH × DATA_WIDTH bits
//   - Write: Stores PWDATA into addressed register on valid write transfer
//   - Read:  Drives PRDATA with addressed register content on read transfer
//   - PREADY: Immediate (WAIT_CYCLES=0) or delayed (WAIT_CYCLES=N) response
//   - PSLVERR: Flags unaligned (non-word-aligned) accesses
//
// Register Addressing (word-aligned):
//   Register index = PADDR[REG_ADDR_BITS+1 : 2]
//   Example (REG_DEPTH=16): reg_idx = PADDR[5:2], valid byte addrs 0x00–0x3F
//
// Wait State Behavior:
//   WAIT_CYCLES=0 → PREADY always HIGH (single-cycle ACCESS)
//   WAIT_CYCLES=N → PREADY LOW for N cycles in ACCESS, then HIGH
//
// Timing Diagram (WAIT_CYCLES=1, Write):
//   CLK:     ‾\_/‾\_/‾\_/‾\_/
//   State:    IDLE | SETUP | ACCESS(wait) | ACCESS(done)
//   PSEL:     _____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|___
//   PENABLE:  ______________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|___
//   PREADY:   ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|______|‾‾‾‾‾‾‾‾‾‾‾‾‾|___
// =============================================================================

module apb_slave #(
    parameter DATA_WIDTH  = 32,
    parameter REG_DEPTH   = 16,     // Number of registers
    parameter WAIT_CYCLES = 0       // 0 = no wait states, N = N extra clocks
) (
    // Clock & Reset
    input  wire                   pclk,
    input  wire                   presetn,

    // APB Interface (from master via decoder/mux)
    input  wire                   psel,
    input  wire                   penable,
    input  wire                   pwrite,
    input  wire [31:0]            paddr,
    input  wire [DATA_WIDTH-1:0]  pwdata,

    // APB Response (back to master via mux)
    output reg  [DATA_WIDTH-1:0]  prdata,
    output wire                   pready,
    output wire                   pslverr
);

    // =========================================================================
    // Internal Declarations
    // =========================================================================

    // Register file: REG_DEPTH entries, each DATA_WIDTH bits wide
    reg [DATA_WIDTH-1:0] reg_file [0:REG_DEPTH-1];

    // Register addressing — word-aligned, skip byte-offset bits [1:0]
    //   REG_DEPTH=16 → REG_ADDR_BITS=4 → reg_idx = paddr[5:2]
    localparam REG_ADDR_BITS = $clog2(REG_DEPTH);
    wire [REG_ADDR_BITS-1:0] reg_idx;
    assign reg_idx = paddr[REG_ADDR_BITS+1:2];

    // Transfer phase detection
    wire setup_phase;
    wire access_phase;
    assign setup_phase  = psel & ~penable;  // SETUP:  PSELx=1, PENABLE=0
    assign access_phase = psel &  penable;  // ACCESS: PSELx=1, PENABLE=1

    // Loop variable for register initialization
    integer i;

    // =========================================================================
    // Wait State Logic (PREADY Generation)
    // =========================================================================
    //
    // WAIT_CYCLES=0: PREADY is tied HIGH — slave always responds immediately.
    // WAIT_CYCLES=N: A counter runs during ACCESS phase. PREADY stays LOW
    //                for N cycles, then goes HIGH to complete the transfer.
    //
    // The counter resets during the SETUP phase so each new transfer gets
    // a fresh wait period.
    // =========================================================================
    generate
        if (WAIT_CYCLES == 0) begin : gen_no_wait
            // No wait states: always ready
            assign pready = 1'b1;
        end
        else begin : gen_with_wait
            reg [$clog2(WAIT_CYCLES+1)-1:0] wait_cnt;

            always @(posedge pclk or negedge presetn) begin
                if (!presetn)
                    wait_cnt <= 0;
                else if (setup_phase)
                    wait_cnt <= 0;                      // Reset for new transfer
                else if (access_phase && wait_cnt < WAIT_CYCLES)
                    wait_cnt <= wait_cnt + 1;           // Count wait cycles
            end

            // PREADY HIGH when counter reaches target (or outside access phase)
            assign pready = !access_phase || (wait_cnt == WAIT_CYCLES);
        end
    endgenerate

    // =========================================================================
    // Error Response Logic (PSLVERR)
    // =========================================================================
    // PSLVERR is only valid when PSEL && PENABLE && PREADY (per APB spec).
    // We flag unaligned accesses (byte offset != 0) as errors.
    // =========================================================================
    assign pslverr = access_phase & pready & (paddr[1:0] != 2'b00);

    // =========================================================================
    // Write Logic (Sequential — clocked)
    // =========================================================================
    // Writes occur on the rising edge of PCLK when all conditions are met:
    //   - Valid ACCESS phase (PSEL=1, PENABLE=1)
    //   - Slave is ready (PREADY=1)
    //   - Write transfer (PWRITE=1)
    //   - No error (PSLVERR=0)
    // =========================================================================
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            for (i = 0; i < REG_DEPTH; i = i + 1)
                reg_file[i] <= {DATA_WIDTH{1'b0}};
        end
        else if (access_phase && pready && pwrite && !pslverr) begin
            reg_file[reg_idx] <= pwdata;
        end
    end

    // =========================================================================
    // Read Logic (Combinational)
    // =========================================================================
    // PRDATA is driven with the addressed register's content during read
    // transfers. The master samples PRDATA on the rising PCLK edge when
    // PENABLE=1 and PREADY=1.
    //
    // During write transfers or when PSEL is LOW, PRDATA is driven to 0
    // (don't-care, but 0 is cleaner for simulation/debug).
    // =========================================================================
    always @(*) begin
        if (psel && !pwrite)
            prdata = reg_file[reg_idx];
        else
            prdata = {DATA_WIDTH{1'b0}};
    end

endmodule
