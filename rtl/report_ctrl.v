// report_ctrl —— 串口汇报：每次测距完成，把结果拼成一行 ASCII 文本，逐字节喂给 uart_tx
//
// 测量行（18 字节，定长）： "A=045 D=0623 L=1\r\n"   超量程 / 无回波时距离 4 位为 "----"
//   A = 角度（度），D = 距离（mm），L = 距离分级 band（0 = ≥800mm/超量程 … 4 = <200mm）
//
// 【资源】原版（快照寄存器 + #SELFTEST/#STANDBY/#STEP/#CONT 事件行）155 LE，加上后整体 1327/1270 装不下。
//   现在：只发测量行（事件行的四段文字表约 49 LE）；不再另存一份快照，直接读 result_reg 的 r_*
//   （一行 18 字节约 19ms，下一次测距最快 100ms 后才来，发送途中 r_* 不会变；只有按键切换模式
//   恰好撞在这 19ms 里时，这一行后半截会变成清零后的值）。
// 发送途中又来新结果：记一个 pending，本行发完再发新的一行（只记最新一次，不排队）。
module report_ctrl(
	input clk,
	input rst,
	
	input r_strobe,				// 新的测量结果已锁存
	input [11:0] r_angle_bcd,
	input [15:0] r_dist_bcd,
	input r_oor,
	input [2:0] r_band,
	
	output reg [7:0] uart_data,	// 组合：当前要发的字节
	output uart_send,			// 组合：本拍把 uart_data 交给 uart_tx
	input uart_busy
);

localparam LINE_LEN = 5'd18;

reg pending;			// 有一行待发
reg active;				// 正在发一行
reg [4:0] idx;			// 行内字节序号 0~17

// uart_tx 在接收字节的那个时钟沿就装好帧，下一拍 busy 已经是高，不会重复交同一个字节
assign uart_send = active && !uart_busy && (idx != LINE_LEN);

// BCD → ASCII：数字 0~9 的 ASCII 是 {4'h3, d}
wire [7:0] dist_ch3 = r_oor ? "-" : {4'h3, r_dist_bcd[15:12]};
wire [7:0] dist_ch2 = r_oor ? "-" : {4'h3, r_dist_bcd[11:8]};
wire [7:0] dist_ch1 = r_oor ? "-" : {4'h3, r_dist_bcd[7:4]};
wire [7:0] dist_ch0 = r_oor ? "-" : {4'h3, r_dist_bcd[3:0]};

always@(*) begin
	case (idx)					// "A=045 D=0623 L=1\r\n"
		5'd0:    uart_data = "A";
		5'd1:    uart_data = "=";
		5'd2:    uart_data = {4'h3, r_angle_bcd[11:8]};
		5'd3:    uart_data = {4'h3, r_angle_bcd[7:4]};
		5'd4:    uart_data = {4'h3, r_angle_bcd[3:0]};
		5'd5:    uart_data = " ";
		5'd6:    uart_data = "D";
		5'd7:    uart_data = "=";
		5'd8:    uart_data = dist_ch3;
		5'd9:    uart_data = dist_ch2;
		5'd10:   uart_data = dist_ch1;
		5'd11:   uart_data = dist_ch0;
		5'd12:   uart_data = " ";
		5'd13:   uart_data = "L";
		5'd14:   uart_data = "=";
		5'd15:   uart_data = {5'b00110, r_band};
		5'd16:   uart_data = 8'h0D;
		default: uart_data = 8'h0A;
	endcase
end

always@(posedge clk or posedge rst) begin
	if (rst) begin
		pending <= 1'b0;
		active  <= 1'b0;
		idx     <= 0;
	end
	else begin
		if (!active) begin
			if (pending) begin
				pending <= 1'b0;
				active  <= 1'b1;
				idx     <= 0;
			end
		end
		else if (idx == LINE_LEN) begin
			if (!uart_busy)					// 最后一个字节（\n）发完
				active <= 1'b0;
		end
		else if (uart_send)
			idx <= idx + 1'b1;
		
		// 放在后面：和"开始发一行"撞在同一拍时以新结果为准，不会丢
		if (r_strobe)
			pending <= 1'b1;
	end
end

endmodule
