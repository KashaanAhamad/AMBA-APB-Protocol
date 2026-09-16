// =============================================================================
// Module: apb_master_fsm
// Purpose: Pure FSM for the APB Master — state register + next-state logic ONLY.
//          No datapath or output driving logic lives here.
//
// States:
//   IDLE   (2'b00) — No transfer active
//   SETUP  (2'b01) — PSELx asserted, address/control driven (1 clock cycle)
//   ACCESS (2'b10) — PENABLE asserted, waiting for PREADY from slave
//
// Transitions:
//   IDLE   → SETUP  : when transfer_req is asserted
//   SETUP  → ACCESS : always (unconditional, exactly 1 clock cycle in SETUP)
//   ACCESS → IDLE   : when PREADY=1 and no new transfer_req
//   ACCESS → SETUP  : when PREADY=1 and transfer_req (back-to-back transfer)
//   ACCESS → ACCESS : when PREADY=0 (slave inserting wait states)
// =============================================================================

module apb_master_fsm (
    input  wire       pclk,
    input  wire       presetn,
    input  wire       transfer_req,    // New transfer requested
    input  wire       pready,          // Slave ready signal

    output reg  [1:0] current_state    // Exposed so datapath can use it
);

    // State encoding
    parameter IDLE   = 2'b00;
    parameter SETUP  = 2'b01;
    parameter ACCESS = 2'b10;

    reg [1:0] next_state;

    // -------------------------------------------------
    // State Register (Sequential logic)
    // -------------------------------------------------
    always @(posedge pclk or negedge presetn) begin
        if (~presetn)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    // -------------------------------------------------
    // Next-State Logic (Combinational)
    // -------------------------------------------------
    always @(*) begin
        case (current_state)
            IDLE: begin
                if (transfer_req)
                    next_state = SETUP;
                else
                    next_state = IDLE;
            end

            SETUP: begin
                // SETUP always transitions to ACCESS after exactly 1 cycle
                // (per APB spec — no condition check needed here)
                next_state = ACCESS;
            end

            ACCESS: begin
                if (pready) begin
                    // Transfer complete — check for back-to-back
                    if (transfer_req)
                        next_state = SETUP;   // Back-to-back: go directly to next SETUP
                    else
                        next_state = IDLE;    // No pending transfer
                end
                else begin
                    // Slave inserting wait states — stay in ACCESS
                    next_state = ACCESS;
                end
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

endmodule
