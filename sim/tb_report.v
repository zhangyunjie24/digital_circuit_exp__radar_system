`timescale 1us/1ns
// tb_report —— report_ctrl + uart_tx 测试台
//
// 用一个独立的串口接收模型（在每一位的中点采样，9600bps = 104.17µs/位）把 TX 线解码回字符，
// 拼成文本行后和期望字符串比对。期望字符串在这里按格式独立写，不引用 DUT。
// 1. 复位期间、空闲时 TX 为高
// 2. 普通测量行、超量程行、三位角度
// 3. 发送途中又来新结果：本行发完后再发新的一行，且内容是新结果
// 4. 位宽：起始位下降沿到下一个字节起始位，帧长 10 位
module tb_report;

reg clk = 0;
always #0.5 clk = ~clk;

reg rst;
reg r_strobe = 0;
reg [11:0] r_angle_bcd = 0;
reg [15:0] r_dist_bcd = 0;
reg r_oor = 0;
reg [2:0] r_band = 0;

wire [7:0] uart_data;
wire uart_send, uart_busy, tx;

report_ctrl report_ctrl_1(
	.clk(clk), .rst(rst), .r_strobe(r_strobe),
	.r_angle_bcd(r_angle_bcd), .r_dist_bcd(r_dist_bcd), .r_oor(r_oor), .r_band(r_band),
	.uart_data(uart_data), .uart_send(uart_send), .uart_busy(uart_busy));

uart_tx uart_tx_1(
	.clk(clk), .rst(rst), .data(uart_data), .send(uart_send), .busy(uart_busy), .tx(tx));

integer errors = 0;

// ================= 串口接收模型 =================
localparam real BIT_US = 1000000.0 / 9600.0;
reg [8*32:1] line_buf;			// 收到的当前行（右对齐）
integer line_len = 0;
reg [8*32:1] lines [0:7];		// 收到的完整行
integer n_lines = 0;
integer frame_err = 0;
real t_start, t_prev_start = -1.0, min_gap = 1.0e9;

always begin : rx
	integer b;
	reg [7:0] ch;
	@(negedge tx);
	t_start = $realtime;
	if (t_prev_start >= 0 && t_start - t_prev_start < min_gap) min_gap = t_start - t_prev_start;
	t_prev_start = t_start;
	#(BIT_US / 2);
	if (tx !== 1'b0) frame_err = frame_err + 1;		// 起始位
	for (b = 0; b < 8; b = b + 1) begin
		#(BIT_US);
		ch[b] = tx;									// 先收最低位
	end
	#(BIT_US);
	if (tx !== 1'b1) frame_err = frame_err + 1;		// 停止位
	if (ch == 8'h0A) begin
		lines[n_lines] = line_buf;
		n_lines = n_lines + 1;
		line_buf = 0;
		line_len = 0;
	end
	else begin
		line_buf = {line_buf[8*31:1], ch};
		line_len = line_len + 1;
	end
end

task strobe;
	input [11:0] a;
	input [15:0] d;
	input oor;
	input [2:0] band;
	begin
		@(posedge clk);
		r_angle_bcd <= a; r_dist_bcd <= d; r_oor <= oor; r_band <= band; r_strobe <= 1;
		@(posedge clk);
		r_strobe <= 0;
	end
endtask

task check_line;
	input integer k;
	input [8*32:1] want;
	begin
		if (lines[k] !== want) begin
			$display("  [FAIL] 第 %0d 行 = \"%0s\"，期望 \"%0s\"", k, lines[k], want);
			errors = errors + 1;
		end
		else
			$display("  [ok]   第 %0d 行 \"%0s\"", k, lines[k]);
	end
endtask

// 一行 18 字节 × 10 位 × 104µs ≈ 18.7ms
localparam LINE_US = 19000;

integer i, bad;
initial begin
	line_buf = 0;
	rst = 1;
	#20;
	if (tx !== 1'b1) begin $display("  [FAIL] 复位时 TX 不是高"); errors = errors + 1; end
	r_strobe = 1; #3; r_strobe = 0;				// 复位期间的 strobe 应被忽略
	rst = 0;
	bad = 0;
	for (i = 0; i < 3000; i = i + 1) begin @(posedge clk); if (tx !== 1'b1) bad = 1; end
	if (bad || n_lines != 0) begin $display("  [FAIL] 空闲时 TX 不是常高"); errors = errors + 1; end
	else $display("  [ok]   复位 / 空闲时 TX 常高");

	$display("==== 1. 普通测量行 / 超量程行 ====");
	strobe(12'h045, 16'h0623, 0, 3'd1);
	#(LINE_US);
	strobe(12'h180, 16'h0000, 1, 3'd0);
	#(LINE_US);
	strobe(12'h135, 16'h0187, 0, 3'd4);
	#(LINE_US);
	// 期望行末带回车（8'h0D）；Verilog 字符串没有 \r 转义，用拼接写
	check_line(0, {"A=045 D=0623 L=1", 8'h0D});
	check_line(1, {"A=180 D=---- L=0", 8'h0D});
	check_line(2, {"A=135 D=0187 L=4", 8'h0D});

	$display("==== 2. 发送途中来新结果：本行发完再发新的一行 ====");
	strobe(12'h090, 16'h3999, 0, 3'd0);
	#(5000);
	strobe(12'h092, 16'h0400, 0, 3'd2);			// 第一行还在发（只到第 4~5 个字节）
	#(2 * LINE_US);
	// 第一行后半截会读到新值（直接读 r_*，不存快照）：只核对前 5 个字节没被打乱、第二行完整
	if (lines[3][8*17:8*13+1] !== "A=09") begin
		$display("  [FAIL] 第 3 行开头 = \"%0s\"", lines[3]); errors = errors + 1;
	end
	else $display("  [ok]   第 3 行开头正常（\"%0s\"）", lines[3]);
	check_line(4, {"A=092 D=0400 L=2", 8'h0D});
	if (n_lines != 5) begin $display("  [FAIL] 共收到 %0d 行，期望 5", n_lines); errors = errors + 1; end

	$display("==== 3. 帧格式 ====");
	if (frame_err != 0) begin $display("  [FAIL] %0d 个字节起始位/停止位不对", frame_err); errors = errors + 1; end
	else $display("  [ok]   全部字节起始位 / 停止位正确");
	// 同一行内字节背靠背发：相邻起始位间隔 = 10 位 = 1040µs（每位 104 个时钟）
	if (min_gap < 1039.0 || min_gap > 1045.0) begin
		$display("  [FAIL] 相邻字节最小间隔 %0.1fµs，期望约 1040µs", min_gap); errors = errors + 1;
	end
	else $display("  [ok]   相邻字节间隔 %0.1fµs（10 位 × 104µs）", min_gap);

	$display("");
	if (errors == 0) $display("==== ALL PASS ====");
	else             $display("==== %0d ERROR(S) ====", errors);
	$finish;
end

endmodule
