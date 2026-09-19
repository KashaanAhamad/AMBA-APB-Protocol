// =============================================================================
// Module: apb_decoder
// Purpose: Address decoder for APB bus — decodes PADDR to generate one-hot
//          slave select signals (PSEL[0], PSEL[1], PSEL[2]).
//
// Functionality:
//   - Pure combinational logic (no clocked elements)
//   - Maps address ranges to one-hot slave select lines
//   - Only one PSELx may be active at any time
//   - Gated by master_sel: PSELx outputs are 0 when no valid transfer
//
// Address Map (default):
//   Slave 0: 0x0000_0000 – 0x0000_00FF  →  PSEL[0]
//   Slave 1: 0x0000_0100 – 0x0000_01FF  →  PSEL[1]
//   Slave 2: 0x0000_0200 – 0x0000_02FF  →  PSEL[2]
// =============================================================================

module apb_decoder #(
    parameter ADDR_WIDTH  = 32,
    parameter NUM_SLAVES  = 3,

    // Base address and size for each slave (byte-addressable)
    parameter SLAVE0_BASE = 32'h0000_0000,
    parameter SLAVE0_SIZE = 32'h0000_0100,   // 256 bytes

    parameter SLAVE1_BASE = 32'h0000_0100,
    parameter SLAVE1_SIZE = 32'h0000_0100,   // 256 bytes

    parameter SLAVE2_BASE = 32'h0000_0200,
    parameter SLAVE2_SIZE = 32'h0000_0100    // 256 bytes
) (
    input  wire [ADDR_WIDTH-1:0]  paddr,
    input  wire                   master_sel,   // From apb_master — indicates valid transfer
    output reg  [NUM_SLAVES-1:0]  pselx
);

    // ---------------------------------------------------------
    // Address Decode Logic (Combinational)
    // Generates one-hot PSELx based on PADDR, gated by master_sel.
    // When master_sel is LOW (no active transfer), all PSELx = 0.
    // When no address matches, all PSELx = 0 (no slave selected).
    // ---------------------------------------------------------
    always @(*) begin
        pselx = {NUM_SLAVES{1'b0}};           // Default: no slave selected

        if (master_sel) begin
            if (paddr >= SLAVE0_BASE && paddr < (SLAVE0_BASE + SLAVE0_SIZE))
                pselx = 3'b001;               // Slave 0 selected
            else if (paddr >= SLAVE1_BASE && paddr < (SLAVE1_BASE + SLAVE1_SIZE))
                pselx = 3'b010;               // Slave 1 selected
            else if (paddr >= SLAVE2_BASE && paddr < (SLAVE2_BASE + SLAVE2_SIZE))
                pselx = 3'b100;               // Slave 2 selected
            else
                pselx = {NUM_SLAVES{1'b0}};   // No match — no slave selected
        end
    end

endmodule