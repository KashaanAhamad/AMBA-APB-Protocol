// =============================================================================
// Module: apb_master
// Purpose: APB Master datapath — instantiates the FSM and drives all APB bus
//          outputs + transfer interface signals based on the current state.
//
// Architecture:
//   ┌─────────────────────────────────────────┐
//   │              apb_master                 │
//   │  ┌───────────────────┐                  │
//   │  │  apb_master_fsm   │──current_state──►│──► Output Logic
//   │  │  (state register  │                  │    (pselx, penable,
//   │  │   + next-state)   │                  │     pwrite, paddr,
//   │  └───────────────────┘                  │     pwdata, etc.)
//   └─────────────────────────────────────────┘
//
// =============================================================================

module apb_master (
    // Clock & Reset
    input  wire        pclk,
    input  wire        presetn,

    // Transfer request interface (from higher-level controller / testbench)
    input  wire        transfer_req,
    input  wire [31:0] transfer_addr,
    input  wire        transfer_write,
    input  wire [31:0] transfer_wdata,

    // APB Slave response signals
    input  wire [31:0] prdata,
    input  wire        pready,
    input  wire        pslverr,

    // APB Bus output signals (directly to slaves via decoder/mux)
    output reg  [31:0] paddr,
    output reg         pselx,
    output reg         penable,
    output reg         pwrite,
    output reg  [31:0] pwdata,

    // Transfer response interface (back to controller / testbench)
    output reg  [31:0] transfer_rdata,
    output reg         transfer_ready,
    output reg         transfer_error
);

    // State encoding (must match apb_master_fsm parameters)
    parameter IDLE   = 2'b00;
    parameter SETUP  = 2'b01;
    parameter ACCESS = 2'b10;

    // Internal wire from FSM
    wire [1:0] current_state;

    // -------------------------------------------------
    // FSM Instantiation
    // -------------------------------------------------
    apb_master_fsm u_fsm (
        .pclk          (pclk),
        .presetn       (presetn),
        .transfer_req  (transfer_req),
        .pready        (pready),
        .current_state (current_state)
    );

    // -------------------------------------------------
    // APB Bus Output Logic (Combinational)
    // Drives pselx, penable, pwrite, paddr, pwdata
    // based on the current FSM state.
    // -------------------------------------------------
    always @(*) begin
        case (current_state)
            IDLE: begin
                pselx   = 1'b0;
                penable = 1'b0;
                pwrite  = 1'b0;
                paddr   = 32'b0;
                pwdata  = 32'b0;
            end

            SETUP: begin
                pselx   = 1'b1;
                penable = 1'b0;
                pwrite  = transfer_write;
                paddr   = transfer_addr;
                pwdata  = transfer_wdata;
            end

            ACCESS: begin
                pselx   = 1'b1;
                penable = 1'b1;
                pwrite  = transfer_write;
                paddr   = transfer_addr;
                pwdata  = transfer_wdata;
            end

            default: begin
                pselx   = 1'b0;
                penable = 1'b0;
                pwrite  = 1'b0;
                paddr   = 32'b0;
                pwdata  = 32'b0;
            end
        endcase
    end

    // -------------------------------------------------
    // Transfer Response Logic (Combinational)
    // Drives transfer_rdata, transfer_ready, transfer_error
    // back to the requesting controller / testbench.
    //
    // These are only valid when the transfer completes:
    //   i.e., in ACCESS state AND pready == 1
    // -------------------------------------------------
    always @(*) begin
        if (current_state == ACCESS && pready) begin
            transfer_ready = 1'b1;
            transfer_rdata = prdata;       // Capture read data from slave
            transfer_error = pslverr;      // Capture error status from slave
        end
        else begin
            transfer_ready = 1'b0;
            transfer_rdata = 32'b0;
            transfer_error = 1'b0;
        end
    end

endmodule