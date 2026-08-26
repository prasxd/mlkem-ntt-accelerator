`timescale 1ns / 1ps

module ntt_core #(
    parameter integer COEFF_W   = 12,
    parameter integer ADDR_W    = 8,
    parameter integer Q         = 3329,
    parameter integer QINV      = 3327,
    parameter integer NINV_MONT = 512,          // 128^-1 * R mod q
    parameter integer WB_LAT    = 5,            // mem read 1 + butterfly 4
    parameter         ZETA_FILE = "vectors/rom_zetas_mont.mem"
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire                mode,            // 0 = NTT, 1 = INTT
    input  wire                s_valid,
    input  wire [COEFF_W-1:0]  s_data,
    output reg                 m_valid,
    output reg  [COEFF_W-1:0]  m_data,
    output reg                 m_last,
    input  wire                m_ready,
    output wire                loading,      // high while consuming input stream
    output reg                 busy,
    output reg                 done
);
    localparam S_IDLE=3'd0, S_LOAD=3'd1, S_RUN=3'd2,
               S_SCALE=3'd3, S_STORE=3'd4, S_DONE=3'd5;

    reg [2:0] state;
    reg mode_r;
    reg [ADDR_W:0] cnt;

    // Exposed as a real port, NOT read hierarchically by the parent: Yosys
    // does not support cross-module hierarchical references, so `u_core.state`
    // in ntt_top silently became an UNDRIVEN wire in synthesis while working
    // perfectly in simulation. Classic sim/synth mismatch.
    assign loading = (state == S_LOAD);                 // 9 bits: counts to 256

    // AXI-Stream backpressure: we may issue a new output beat when the
    // current one has been accepted (or there is none). Declared here,
    // ahead of its first use in mem_ren below -- Verilog-2005 onward
    // rejects a forward reference to an explicitly declared wire.
    wire adv = (!m_valid) || m_ready;

    // ---- addr_gen ----------------------------------------------------------
    reg  ag_start, ag_en;
    wire ag_valid, ag_last_layer, ag_busy, ag_done;
    wire [ADDR_W-1:0] ag_a, ag_b;
    wire [6:0] ag_k;
    wire [2:0] ag_layer;

    addr_gen u_ag (.clk(clk), .rst_n(rst_n), .start(ag_start), .mode(mode_r),
        .en(ag_en), .valid(ag_valid), .addr_a(ag_a), .addr_b(ag_b), .k(ag_k),
        .layer(ag_layer), .last_in_layer(ag_last_layer), .busy(ag_busy), .done(ag_done));

    // ---- twiddle ROM -------------------------------------------------------
    wire [COEFF_W-1:0] z_rom;
    twiddle_rom #(.COEFF_W(COEFF_W), .INIT_FILE(ZETA_FILE)) u_rom
        (.clk(clk), .rst_n(rst_n), .en(1'b1), .addr(ag_k), .dout(z_rom));

    // ---- coefficient memory ------------------------------------------------
    reg  [ADDR_W-1:0]  mem_ra, mem_rb, mem_wa_addr, mem_wb_addr;
    reg                mem_wea, mem_web;
    reg  [COEFF_W-1:0] mem_da, mem_db;
    wire [COEFF_W-1:0] mem_qa, mem_qb;

    // Read enable: during STORE the sink can stall us. Without this the held
    // address would be re-read and the already-fetched beat clobbered.
    wire mem_ren = (state == S_STORE) ? adv : 1'b1;

    coeff_mem u_mem (.clk(clk), .rst_n(rst_n), .ren(mem_ren),
        .raddr_a(mem_ra), .raddr_b(mem_rb), .rdata_a(mem_qa), .rdata_b(mem_qb),
        .waddr_a(mem_wa_addr), .waddr_b(mem_wb_addr),
        .we_a(mem_wea), .we_b(mem_web), .wdata_a(mem_da), .wdata_b(mem_db));

    // ---- pipeline: read data lands one cycle after the address -------------
    reg r_valid, r_scale;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin r_valid <= 1'b0; r_scale <= 1'b0; end
        else begin
            r_valid <= (state==S_RUN && ag_valid) || (state==S_SCALE && cnt<256);
            r_scale <= (state==S_SCALE);
        end
    end

    // ---- butterfly ---------------------------------------------------------
    // SCALE reuses it: GS mode with a=0 gives b_out = z*(b-0) = NINV*b.
    wire [COEFF_W-1:0] bf_a_in = r_scale ? {COEFF_W{1'b0}} : mem_qa;
    wire [COEFF_W-1:0] bf_b_in = r_scale ? mem_qa          : mem_qb;
    wire [COEFF_W-1:0] bf_z_in = r_scale ? NINV_MONT[COEFF_W-1:0] : z_rom;
    wire               bf_mode = r_scale ? 1'b1 : mode_r;
    wire [COEFF_W-1:0] bf_a_out, bf_b_out;
    wire               bf_valid;

    butterfly #(.COEFF_W(COEFF_W), .Q(Q), .QINV(QINV)) u_bf
        (.clk(clk), .rst_n(rst_n), .valid_in(r_valid), .mode(bf_mode),
         .z_mont(bf_z_in), .a(bf_a_in), .b(bf_b_in),
         .a_out(bf_a_out), .b_out(bf_b_out), .valid_out(bf_valid));

    // ---- writeback address delay: shifts EVERY cycle, matching the
    //      butterfly pipeline which has no enable -------------------------
    reg [ADDR_W-1:0] wa_dly [0:WB_LAT-1];
    reg [ADDR_W-1:0] wb_dly [0:WB_LAT-1];
    reg              sc_dly [0:WB_LAT-1];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) for (i=0;i<WB_LAT;i=i+1) begin
            wa_dly[i]<=0; wb_dly[i]<=0; sc_dly[i]<=1'b0; end
        else begin
            wa_dly[0] <= (state==S_SCALE) ? cnt[ADDR_W-1:0] : ag_a;
            wb_dly[0] <= ag_b;
            sc_dly[0] <= (state==S_SCALE);
            for (i=1;i<WB_LAT;i=i+1) begin
                wa_dly[i]<=wa_dly[i-1]; wb_dly[i]<=wb_dly[i-1]; sc_dly[i]<=sc_dly[i-1];
            end
        end
    end
    wire [ADDR_W-1:0] wb_a = wa_dly[WB_LAT-1];
    wire [ADDR_W-1:0] wb_b = wb_dly[WB_LAT-1];
    wire              wb_scale = sc_dly[WB_LAT-1];

    // ---- in-flight tracking drives the inter-layer drain -------------------
    reg [3:0] inflight;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) inflight <= 0;
        else inflight <= inflight + (r_valid ? 4'd1 : 4'd0) - (bf_valid ? 4'd1 : 4'd0);
    end
    wire pipe_empty = (inflight == 0) && !r_valid;

    reg draining, run_finished;

    // ---- main FSM ----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; busy<=0; done<=0; cnt<=0; mode_r<=0;
            ag_start<=0; ag_en<=0; draining<=0; run_finished<=0;
            m_valid<=0; m_data<=0; m_last<=0;
        end else begin
            ag_start <= 1'b0;
            done     <= 1'b0;

            case (state)
            S_IDLE: if (start) begin
                        busy<=1'b1; mode_r<=mode; cnt<=0; state<=S_LOAD;
                        draining<=0; run_finished<=0;
                    end

            S_LOAD: if (s_valid) begin
                        if (cnt == 255) begin
                            cnt<=0; state<=S_RUN; ag_start<=1'b1; ag_en<=1'b1;
                        end else cnt <= cnt + 1'b1;
                    end

            S_RUN: begin
                        if (ag_valid && ag_last_layer) begin
                            draining <= 1'b1;
                            ag_en    <= 1'b0;
                        end
                        if (ag_done) run_finished <= 1'b1;
                        if (draining && pipe_empty) begin
                            draining <= 1'b0;
                            if (run_finished) begin
                                cnt <= 0;
                                state <= mode_r ? S_SCALE : S_STORE;
                            end else begin
                                ag_en <= 1'b1;
                            end
                        end
                    end

            S_SCALE: begin
                        if (cnt < 256) cnt <= cnt + 1'b1;
                        else if (pipe_empty) begin cnt<=0; state<=S_STORE; end
                     end

            S_STORE: begin
                        // Read data lands ONE cycle after the address, so the
                        // first valid beat is at cnt==1, carrying mem[0].
                        // `adv` implements AXI-Stream backpressure: while the
                        // sink is not ready we freeze cnt, so the read address
                        // holds and mem_qa holds with it.
                        if (adv) begin
                            if (cnt < 258) cnt <= cnt + 1'b1;
                            m_valid <= (cnt >= 1) && (cnt <= 256);
                            m_data  <= mem_qa;
                            m_last  <= (cnt == 256);
                            if (cnt == 257) state <= S_DONE;
                        end
                     end

            S_DONE: begin busy<=1'b0; done<=1'b1; state<=S_IDLE; end
            endcase
        end
    end

    // ---- memory port muxing (reads and writes are now independent) --------
    always @(*) begin
        // read address
        case (state)
        S_LOAD:  begin mem_ra = cnt[ADDR_W-1:0]; mem_rb = cnt[ADDR_W-1:0] ^ 8'd1; end
        S_STORE: begin mem_ra = cnt[ADDR_W-1:0]; mem_rb = cnt[ADDR_W-1:0] ^ 8'd1; end
        S_SCALE: begin mem_ra = cnt[ADDR_W-1:0]; mem_rb = cnt[ADDR_W-1:0] ^ 8'd1; end
        default: begin mem_ra = ag_a;            mem_rb = ag_b;                    end
        endcase

        // write port
        mem_wa_addr = 0; mem_wb_addr = 0; mem_wea = 0; mem_web = 0;
        mem_da = 0; mem_db = 0;
        if (state == S_LOAD) begin
            mem_wa_addr = cnt[ADDR_W-1:0]; mem_da = s_data; mem_wea = s_valid;
            mem_wb_addr = cnt[ADDR_W-1:0] ^ 8'd1;
        end else if (bf_valid) begin
            if (wb_scale) begin
                mem_wa_addr = wb_a; mem_da = bf_b_out; mem_wea = 1'b1;
                mem_wb_addr = wb_a ^ 8'd1;
            end else begin
                mem_wa_addr = wb_a; mem_da = bf_a_out; mem_wea = 1'b1;
                mem_wb_addr = wb_b; mem_db = bf_b_out; mem_web = 1'b1;
            end
        end
    end
endmodule
