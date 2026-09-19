// =============================================================================
// Module: apb_mux
// Purpose: Multiplexes responses from multiple APB slaves back to the master
//          based on the active PSELx signal.
//
// Functionality:
//   - Combinational mux driven by one-hot PSEL signals
//   - Selects PRDATA, PREADY, PSLVERR from the active slave
//   - Default response when no slave selected: PREADY=1, PRDATA=0, PSLVERR=0
//     (PREADY=1 by default prevents the master from stalling indefinitely)
//
// Architecture:
//   Slave 0 ──┐
//   Slave 1 ──┼──► MUX (selected by PSELx) ──► PRDATA, PREADY, PSLVERR
//   Slave 2 ──┘
// =============================================================================

module apb_mux (
    // Slave select from decoder (one-hot)
    input  wire [2:0]  pselx,

    // Slave 0 response signals
    input  wire [31:0] slave0_prdata,
    input  wire        slave0_pready,
    input  wire        slave0_pslverr,

    // Slave 1 response signals
    input  wire [31:0] slave1_prdata,
    input  wire        slave1_pready,
    input  wire        slave1_pslverr,

    // Slave 2 response signals
    input  wire [31:0] slave2_prdata,
    input  wire        slave2_pready,
    input  wire        slave2_pslverr,

    // Muxed outputs to master
    output reg  [31:0] prdata,
    output reg         pready,
    output reg         pslverr
);

    // ---------------------------------------------------------
    // Response Mux Logic (Combinational)
    // Routes the selected slave's response signals to the master.
    // PSELx is one-hot, so only one case should match at a time.
    //
    // Default (no slave selected):
    //   PREADY  = 1  (prevents master from hanging in ACCESS)
    //   PRDATA  = 0  (no valid data)
    //   PSLVERR = 0  (no error)
    // ---------------------------------------------------------
    always @(*) begin
        // Defaults — applied when no slave is selected
        prdata  = 32'b0;
        pready  = 1'b1;
        pslverr = 1'b0;

        case (pselx)
            3'b001: begin   // Slave 0 selected
                prdata  = slave0_prdata;
                pready  = slave0_pready;
                pslverr = slave0_pslverr;
            end

            3'b010: begin   // Slave 1 selected
                prdata  = slave1_prdata;
                pready  = slave1_pready;
                pslverr = slave1_pslverr;
            end

            3'b100: begin   // Slave 2 selected
                prdata  = slave2_prdata;
                pready  = slave2_pready;
                pslverr = slave2_pslverr;
            end

            default: begin  // No slave or invalid select
                prdata  = 32'b0;
                pready  = 1'b1;
                pslverr = 1'b0;
            end
        endcase
    end

endmodule