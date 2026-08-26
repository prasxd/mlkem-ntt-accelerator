`timescale 1ns / 1ps
// AXI4-Lite control + AXI4-Stream data wrapper around ntt_core.
//
// Register map (32-bit, byte address):
//   0x00 CTRL   [0] start (write-1-pulse)
//   0x04 MODE   [0] 0 = NTT, 1 = INTT
//   0x08 STATUS [0] busy   [1] done (sticky, cleared by writing 1 to it)
//   0x0C CYCLES  cycles taken by the last completed operation
//
// Data: 12-bit coefficients carried in the low bits of a 16-bit stream word.
// tlast is asserted on output coefficient 255.
module ntt_top #(
    parameter integer COEFF_W = 12,
    parameter integer AXIL_AW = 4,
    parameter         ZETA_FILE = "vectors/rom_zetas_mont.mem"
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- AXI4-Lite slave ----
    input  wire [AXIL_AW-1:0] s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output reg         s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output reg         s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [AXIL_AW-1:0] s_axil_araddr,
    input  wire        s_axil_arvalid,
    output reg         s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,
    // ---- AXI4-Stream slave (coefficients in) ----
    input  wire [15:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    // ---- AXI4-Stream master (coefficients out) ----
    output wire [15:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);
    reg        r_start, r_mode, done_sticky;
    reg [31:0] cyc_cnt, cyc_last;
    wire core_busy, core_done, core_loading;
    wire [COEFF_W-1:0] core_out;
    wire core_ovalid, core_olast;

    ntt_core #(.COEFF_W(COEFF_W), .ZETA_FILE(ZETA_FILE)) u_core (
        .clk(clk), .rst_n(rst_n), .start(r_start), .mode(r_mode),
        .s_valid(s_axis_tvalid && s_axis_tready), .s_data(s_axis_tdata[COEFF_W-1:0]),
        .m_valid(core_ovalid), .m_data(core_out), .m_last(core_olast),
        .m_ready(m_axis_tready), .loading(core_loading),
        .busy(core_busy), .done(core_done));

    // core accepts input only while loading
    assign s_axis_tready = core_loading;
    assign m_axis_tdata   = {{(16-COEFF_W){1'b0}}, core_out};
    assign m_axis_tvalid  = core_ovalid;
    assign m_axis_tlast   = core_olast;

    // ---- cycle counter -----------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc_cnt  <= 0;
            cyc_last <= 0;
        end else begin
            if (r_start)        cyc_cnt <= 0;
            else if (core_busy) cyc_cnt <= cyc_cnt + 1;
            if (core_done)      cyc_last <= cyc_cnt;
        end
    end

    // ---- AXI4-Lite write ---------------------------------------------------
    reg aw_seen, w_seen;
    reg [AXIL_AW-1:0] aw_addr;
    reg [31:0] w_data;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready<=0; s_axil_wready<=0; s_axil_bvalid<=0; s_axil_bresp<=2'b00;
            aw_seen<=0; w_seen<=0; aw_addr<=0; w_data<=0;
            r_start<=0; r_mode<=0; done_sticky<=0;
        end else begin
            r_start <= 1'b0;
            if (core_done) done_sticky <= 1'b1;

            s_axil_awready <= !aw_seen && !s_axil_bvalid;
            s_axil_wready  <= !w_seen  && !s_axil_bvalid;
            if (s_axil_awvalid && s_axil_awready) begin aw_seen<=1; aw_addr<=s_axil_awaddr; end
            if (s_axil_wvalid  && s_axil_wready ) begin w_seen <=1; w_data <=s_axil_wdata;  end

            if (aw_seen && w_seen && !s_axil_bvalid) begin
                case (aw_addr[3:2])
                2'd0: if (w_data[0] && !core_busy) r_start <= 1'b1;
                2'd1: r_mode <= w_data[0];
                2'd2: if (w_data[1]) done_sticky <= 1'b0;   // W1C
                default: ;
                endcase
                aw_seen<=0; w_seen<=0;
                s_axil_bvalid<=1'b1; s_axil_bresp<=2'b00;
            end
            if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
        end
    end

    // ---- AXI4-Lite read ----------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready<=0; s_axil_rvalid<=0; s_axil_rdata<=0; s_axil_rresp<=2'b00;
        end else begin
            s_axil_arready <= !s_axil_rvalid;
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_rvalid <= 1'b1; s_axil_rresp <= 2'b00;
                case (s_axil_araddr[3:2])
                2'd0: s_axil_rdata <= 32'd0;
                2'd1: s_axil_rdata <= {31'd0, r_mode};
                2'd2: s_axil_rdata <= {30'd0, done_sticky, core_busy};
                2'd3: s_axil_rdata <= cyc_last;
                endcase
            end
            if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 1'b0;
        end
    end
endmodule
