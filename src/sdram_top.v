//
// SDRAM access example for Tang Primer 20K
// Feng Zhou, 2022.0
//
// SDRAM memory module: 
// Chip is Winbond W9812G6KH-6.   2M x 4 BANKS x 16 BITS SDRAM
//
// Test module wiring is as follows,
//
// SDRAM module pinout:
//         +-----+
//   DQ14  |1   2|   DQ15
//   DQ12  |3   4|   DQ13
//   DQ10  |5   6|   DQ11
//   DQ8   |7   8|   DQ9
//   DQ6   |9  10|   DQ7 
//         |11 12|   _GND
//   DQ4   |13 14|   DQ5 
//   DQ2   |15 16|   DQ3 
//   DQ1   |17 18|   DQ0
//   BA1   |19 20|   BA0
//   A0    |21 22|   A10
//   A2    |23 24|   A1
//   CS#   |25 26|   A3
//   CAS#  |27 28|   RAS#
//  _3V3   |29 30|   _GND
//   WE#   |31 32|   CLK
//   CKE   |33 34|   A11
//   A9    |35 36|   A8 
//   A7    |37 38|   A6
//   A5    |39 40|   A4
//         +-----+
//
// Connect Tang 20K Lite board top GPIO (J3) and bottom GPIO to the 
// corresponding module pins as the following diagram. For example,
//   - GPIO pin #1 (3V3) to module pin #29 (3V3)
//   - GPIO pin #3 (N6) to module pin #1 (DQ14)
// 
//           J3 (GPIO)                             Bottom GPIO
//            +-----+                                        
//  3V3  29 3V3|1   2|GND 12 GND                   |         | 
//  DQ14 1   N6|3   4|N7  2  DQ15                  |     K13 | 38 A6
//  DQ12 3  B11|5   6|A12 4  DQ13                  |     K11 | 39 A5  
//  DQ10 5   L9|7   8|N8  6  DQ11                  |     T12 | 40 A4
//  DQ8  7   R9|9  10|N9  8  DQ9                   |         |
//           A6|11 12|A7                                 
//           C6|13 14|B8                                   
//  DQ6  9  C10|15 16|GND       
//  DQ4  13 A11|17 18|C11 10 DQ7 
//  DQ2  15 B12|19 20|C12 14 DQ5 
//  DQ1  17 B13|21 22|A14 16 DQ3 
//  BA1  19 B14|23 24|A15 18 DQ0
//  A0   21 D14|25 26|E15 20 BA0
//  A2   23 F16|27 28|F14 22 A10
//  CS#  25 G15|29 30|G14 24 A1 
//  CAS# 27 J14|31 32|J16 26 A3
//  WE#  31 G12|33 34|F13 28 RAS#
//  CKE  33 M14|35 36|M15 32 CLK
//  A9   35 T14|37 38|R13 34 A11
//  A7   37 P13|39 40|R12 36 A8
//         +-----+
// 
// Also see src\tang20k.cst for actual pin specfications.
// 

`timescale 1ps /1ps

module sdram_top
  (
    input sys_clk,
    input sys_resetn,

    input d7,

	inout  [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output [11:0] SDRAM_A,    // 12 bit multiplexed address bus
	output [1:0] SDRAM_BA,   // 4 banks
	output SDRAM_nCS,  // a single chip select
	output SDRAM_nWE,  // write enable
	output SDRAM_nRAS, // row address select
	output SDRAM_nCAS, // columns address select
	output SDRAM_CLK,
	output SDRAM_CKE,

    output [7:0] led,

    output uart_txp
  );

reg start;      // press d7 to start the system
always @(posedge clk) begin
    if (d7) start <= 1;
    if (~sys_resetn) start <= 0;
end

reg rd, wr, refresh;
reg [24:0] addr;
reg [15:0] din;
wire [15:0] dout;

localparam FREQ=54_000_000;

localparam [24:0] TOTAL_SIZE = 8*1024*1024;         // 16MB

Gowin_rPLL pll(
    .clkout(clk),           // FREQ: main clock
    .clkoutp(clk_sdram),    // FREQ: Phase shifted clock for SDRAM
    .clkin(sys_clk)         // 27Mhz system clock
);

sdram #(.FREQ(FREQ)) u_sdram (
    .clk(clk), .clk_sdram(clk_sdram), .resetn(sys_resetn && start),
	.addr(addr), .rd(rd), .wr(wr), .refresh(refresh),
	.din(din), .dout(dout), .data_ready(data_ready), .busy(busy),

    .SDRAM_DQ(SDRAM_DQ),   // 16 bit bidirectional data bus
    .SDRAM_A(SDRAM_A),    // 13 bit multiplexed address bus
    .SDRAM_BA(SDRAM_BA),   // two banks
    .SDRAM_nCS(SDRAM_nCS),  // a single chip select
    .SDRAM_nWE(SDRAM_nWE),  // write enable
    .SDRAM_nRAS(SDRAM_nRAS), // row address select
    .SDRAM_nCAS(SDRAM_nCAS), // columns address select
    .SDRAM_CLK(SDRAM_CLK)
);

localparam [3:0] INIT = 3'd0;
localparam [3:0] WRITE1 = 3'd1;
localparam [3:0] WRITE2 = 3'd2;
localparam [3:0] READ = 3'd3;
localparam [3:0] READ_RESULT = 3'd4;
localparam [3:0] WRITE_BLOCK = 4'd5;
localparam [3:0] VERIFY_BLOCK = 4'd6;
localparam [3:0] FINISH = 3'd7;

reg [3:0] state, end_state;
reg [7:0] work_counter; // 10ms per state to give UART time to print one line of message
reg [7:0] latency_write1, latency_write2, latency_read;
reg [15:0] expected, actual;

reg error_bit;
localparam V0=16'h1234;
localparam V1=16'b1110_1101_1100_1011;

assign led = ~{error_bit, 3'b0, state};
reg refresh_needed;
reg refresh_executed;   // pulse from main FSM

// 7.8us refresh
reg [11:0] refresh_time;
localparam REFRESH_COUNT=FREQ/1000/1000*7813/1000;       // one refresh every 422 cycles for 54 Mhz

always @(posedge clk && state) begin
    refresh_time <= refresh_time == (REFRESH_COUNT*2-2) ? (REFRESH_COUNT*2-2) : refresh_time + 1;
    if (refresh_time == REFRESH_COUNT) 
        refresh_needed <= 1;
    if (refresh_executed) begin
        refresh_time <= refresh_time - REFRESH_COUNT;
        refresh_needed <= 0;
    end
    if (~sys_resetn) begin
        refresh_time <= 0;
        refresh_needed <= 0;
    end
end

reg refresh_cycle;
reg [23:0] refresh_count;
reg [24:0] refresh_addr;

wire VV = addr[15:0] ^ {7'b0, addr[24:16]};

always @(posedge clk) begin
    wr <= 0; rd <= 0; refresh <= 0; refresh_executed <= 0;
    work_counter <= work_counter + 1;

    case (state)
        INIT: if (start && work_counter == 0) begin
            state <= WRITE1;
        end
        WRITE1: if (!busy) begin 
            wr <= 1'b1;
            addr <= 25'b0;
            din <= V0;
            work_counter <= 0;
            state <= WRITE2;
        end
        WRITE2: begin
            // record write latency and issue another write command
            if (!wr && !busy) begin
                latency_write1 <= work_counter[7:0]; 
                wr <= 1'b1;
                addr <= 25'h1;
                din <= V1;
                state <= READ;
                work_counter <= 0;
            end
        end
        READ: begin
            if (!wr && !busy && latency_write2 == 0) latency_write2 <= work_counter[7:0]; 
            if (!wr && !busy /* && work_counter == 0 */) begin
                rd <= 1'b1;
                addr <= 25'h0;
                work_counter <= 0;
                state <= READ_RESULT;
            end
        end
        READ_RESULT: begin
            if (!rd && !busy && latency_read == 0) latency_read <= work_counter;
            if (!rd && !busy) begin
                actual <= dout;
                expected <= V0;
                if (dout == V0) begin
                    state <= WRITE_BLOCK;
                    addr <= 0;
                    work_counter <= 0;
                end else begin
                    error_bit <= 1;
                    end_state <= state;
                    state <= FINISH;
                end
            end
        end
        WRITE_BLOCK: begin
            // write some data
            if (addr == TOTAL_SIZE) begin
                state <= VERIFY_BLOCK;
                work_counter <= 0;
                addr <= 0;
            end else begin
                if (work_counter == 0) begin
                    if (!refresh_needed) begin
                        wr <= 1'b1;
                        din <= VV;
                        refresh_cycle <= 0;
                    end else begin
                        refresh <= 1'b1;
                        refresh_executed <= 1'b1;
                        refresh_cycle <= 1'b1;
                        refresh_count <= refresh_count + 1;
                        refresh_addr <= addr;
                    end
                end else if (!wr && !refresh && !busy) begin
                    work_counter <= 0;
                    if (!refresh_cycle)
                        addr <= addr + 1;
                end
            end
        end
        VERIFY_BLOCK: begin
            if (addr == TOTAL_SIZE) begin
                end_state <= state;
                state <= FINISH;
            end else begin
                if (work_counter == 0) begin
                    // send next read request or refresh
                    if (!refresh_needed) begin
                        rd <= 1'b1;
                        refresh_cycle <= 1'b0;
                    end else begin
                        refresh <= 1'b1;
                        refresh_executed <= 1'b1;
                        refresh_cycle <= 1'b1;
                        refresh_count <= refresh_count + 1;
                        refresh_addr <= addr;
                    end
                end else if (data_ready) begin
                    // verify result
                    expected <= VV;
                    actual <= dout;
                    if (dout != VV) begin
                        error_bit <= 1'b1;
                        end_state <= state;
                        state <= FINISH;
                    end
                end else if (!rd && !refresh && !busy) begin
                    work_counter <= 0;      // start next read
                    if (!refresh_cycle) begin
                        addr <= addr + 1;
                    end
                end
            end
        end
    endcase

    if (~sys_resetn) begin
        error_bit <= 1'b0;
        latency_write1 <= 0; latency_write2 <= 0; latency_read <= 0;
        refresh_count <= 0;
        state <= INIT;
    end
end


//Print Controll -------------------------------------------
`include "print.v"
defparam tx.uart_freq=115200;
defparam tx.clk_freq=FREQ;
assign print_clk = clk;
assign txp = uart_txp;

reg[3:0] state_0;
reg[3:0] state_1;
reg[3:0] state_old;
wire[3:0] state_new = state_1;

reg [7:0] print_counters = 0, print_counters_p;

always@(posedge clk)begin
    state_1<=state_0;
    state_0<=state;

    if(state_0==state_1) begin //stable value
        state_old<=state_new;

        if(state_old!=state_new)begin//state changes
            if(state_new==INIT)`print("Initializing SDRAM\n",STR);
          
            if(state_new==WRITE1)
                `print("Single write/read test...\n",STR);
          
            if(state_new==WRITE_BLOCK)`print("Bulk write/read test...\n",STR);

            if(state_new==FINISH)begin
                if(error_bit)
                    `print("ERROR Occured. See below for actual dout.\n\n",STR);
                else
                    `print("SUCCESS: Test Finished\n\n",STR);
                print_counters <= 1;
            end      
        end
    end

    print_counters_p <= print_counters;
    if (print_counters != 0 && print_counters == print_counters_p && print_state == PRINT_IDLE_STATE) begin
        case (print_counters)
        8'd1: `print("Write latency=", STR);
        8'd2: `print(latency_write1, 1);
        8'd5: `print("\nRead latency=", STR);
        8'd6: `print(latency_read, 1);
        8'd7: `print("\nExpected value=", STR);
        8'd8: `print(expected, 2);
        8'd9: `print("\nActual value=", STR);
        8'd10: `print(actual, 2);
        8'd11: `print("\nFinal address=", STR);
        8'd12: `print(addr[23:0], 3);
        8'd13: `print("\nError bit=", STR);
        8'd14: `print({7'b0, error_bit}, 1);
        8'd15: `print("\nEnd state=", STR);
        8'd16: `print({4'b0, end_state}, 1);
        8'd17: `print("\nRefresh counts=", STR);
        8'd18: `print(refresh_count, 3);
        8'd19: `print("\nLast refresh address=", STR);
        8'd20: `print(refresh_addr[23:0], 3);
        8'd255: `print("\n\n", STR);
        endcase
        print_counters <= print_counters == 8'd255 ? 0 : print_counters + 1;
    end

    if(~sys_resetn) `print("Perform Reset\n",STR);
end
//Print Controll -------------------------------------------


endmodule







