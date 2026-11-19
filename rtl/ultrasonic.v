// ultrasonic —— HC-SR04 测距
//
// 时序：start → Trig 输出 12µs 高脉冲 → 等 Echo 上升沿 → Echo 高电平期间计距离 → Echo 下降沿结束
//
// 计距离：distance(mm) = t(µs) × 340m/s ÷ 2 = t × 0.17
//   每 µs 做 acc += 17，acc ≥ 100 时 acc -= 100、毫米计数 +1，得到的正好是 floor(t × 17 / 100)。
//   毫米计数直接用 4 位 BCD 计，省掉二进制→BCD 转换（参考 angle_bcd：除法器很吃逻辑单元）。
//
// 超量程（oor=1，同样发 done）：
//   1. 毫米计数到 4000（Echo 高电平约 23.5ms）就直接结束，不再等下降沿；
//   2. Trig 之后 10ms 内没等到 Echo 上升沿（没接模块 / 没回波）。
//   等的是"上升沿"而不是"高电平"：HC-SR04 无回波时 Echo 可能保持高 38ms 以上，
//   下一次 start 来时上一次的 Echo 还没落下，按电平判断会把它当成新回波。
// 毛刺过滤：Echo 高电平不到 20mm 就落下，视为干扰（板上实测出现过假 "0"），回 S_WAIT 继续等。
//
// mm_bcd 就是计数器本身：done 时有效，并一直保持到下一次 start。
// 测量进行中（busy）再来的 start 被忽略；两次测量的间隔由 scan_engine 的节拍保证。
// abort（= restart 或 phase!=SCAN）：中止进行中的测量、不发 done。否则按键切换模式时
//   测到一半的旧测量会在切换后才发 done，把旧角度的结果写进刚清空的 result_reg/dir_mem（顶层仿真抓到过）。
module ultrasonic(
	input clk,					// 1MHz，1 个周期 = 1µs
	input rst,
	input tick_1ms,			// 等 Echo 超时按 ms 数
	input start,				// 单周期脉冲：触发一次测量
	input abort,				// 中止进行中的测量（不发 done）
	input echo,					// HC-SR04 Echo（异步输入，内部同步）

	output reg trig,			// HC-SR04 Trig
	output reg done,			// 单周期脉冲：本次测量结束（正常或超量程）
	output reg [15:0] mm_bcd,	// 距离，4 位 BCD（mm）
	output reg oor				// 超量程 / 无回波
);

localparam TRIG_LAST = 4'd11;		// Trig 高电平 12µs（要求 ≥10µs）
localparam WAIT_LAST = 4'd10;		// 等 Echo 上升沿最多 9~10ms（按 tick_1ms 数，第一个 tick 来的时刻不定）
// 【资源】原来一个 14 位计数器同时管 12µs 和 10ms；拆成 4 位计数器 + 数 tick_1ms，省约 10 LE

localparam S_IDLE    = 2'd0,
           S_TRIG    = 2'd1,
           S_WAIT    = 2'd2,
           S_MEASURE = 2'd3;

// ---- Echo 两级同步 + 边沿检测 ----
reg echo_s1, echo_s2, echo_s3;
always@(posedge clk or posedge rst) begin
	if (rst) begin
		echo_s1 <= 1'b0;
		echo_s2 <= 1'b0;
		echo_s3 <= 1'b0;
	end
	else begin
		echo_s1 <= echo;
		echo_s2 <= echo_s1;
		echo_s3 <= echo_s2;
	end
end
wire echo_rise =  echo_s2 && !echo_s3;
wire echo_fall = !echo_s2 &&  echo_s3;

// ---- BCD 毫米计数 +1 ----
wire [3:0] d0 = mm_bcd[3:0];
wire [3:0] d1 = mm_bcd[7:4];
wire [3:0] d2 = mm_bcd[11:8];
wire [3:0] d3 = mm_bcd[15:12];
wire c0 = (d0 == 4'd9);
wire c1 = c0 && (d1 == 4'd9);
wire c2 = c1 && (d2 == 4'd9);
wire [15:0] mm_inc = { c2 ? d3 + 1'b1 : d3,
                       c2 ? 4'd0 : c1 ? d2 + 1'b1 : d2,
                       c1 ? 4'd0 : c0 ? d1 + 1'b1 : d1,
                       c0 ? 4'd0 : d0 + 1'b1 };

reg [1:0]  state;
reg [3:0]  t_cnt;			// Trig 宽度（µs）/ 等待超时（ms）共用
reg [6:0]  acc;				// 0~99

wire acc_carry = (acc >= 7'd83);	// acc + 17 ≥ 100

always@(posedge clk or posedge rst) begin
	if (rst) begin
		state  <= S_IDLE;
		t_cnt  <= 0;
		acc    <= 0;
		trig   <= 1'b0;
		done   <= 1'b0;
		mm_bcd <= 16'h0000;
		oor    <= 1'b0;
	end
	else if (abort) begin
		state <= S_IDLE;
		trig  <= 1'b0;
		done  <= 1'b0;
	end
	else begin
		done <= 1'b0;				// 默认单周期

		case (state)
			S_IDLE: begin
				if (start) begin
					state  <= S_TRIG;
					t_cnt  <= 0;
					trig   <= 1'b1;
					acc    <= 0;
					mm_bcd <= 16'h0000;
					oor    <= 1'b0;
				end
			end

			S_TRIG: begin
				if (t_cnt == TRIG_LAST) begin
					state <= S_WAIT;
					t_cnt <= 0;
					trig  <= 1'b0;
				end
				else
					t_cnt <= t_cnt + 1'b1;
			end

			S_WAIT: begin
				if (echo_rise) begin
					// 上升沿这一拍 Echo 已经是高，算作第 1µs，计数拍数才正好等于高电平宽度
					state  <= S_MEASURE;
					acc    <= 7'd17;
					mm_bcd <= 16'h0000;		// 前面若有被丢掉的毛刺，它计的数要清掉
				end
				else if (t_cnt == WAIT_LAST) begin				// 数的是 tick_1ms
					state <= S_IDLE;
					oor   <= 1'b1;
					done  <= 1'b1;
				end
				else
					if (tick_1ms) t_cnt <= t_cnt + 1'b1;
			end

			S_MEASURE: begin
				if (echo_fall) begin
					// 不到 20mm（约 118µs，HC-SR04 最小量程）的高电平是干扰毛刺：丢掉，回去接着等真回波。
					// t_cnt 没清零，10ms 超时照常起作用
					if (d3 == 4'd0 && d2 == 4'd0 && d1 < 4'd2)
						state <= S_WAIT;
					else begin
						state <= S_IDLE;
						done  <= 1'b1;
					end
				end
				else if (d3 == 4'd4) begin
					// 计到 4000mm：超量程，不再等下降沿
					state <= S_IDLE;
					oor   <= 1'b1;
					done  <= 1'b1;
				end
				else begin
					// 【资源】+17 和 -83 写成"常量选择 + 单个加法器"，不要两套加减法器
					acc <= acc + (acc_carry ? -7'd83 : 7'd17);
					if (acc_carry)
						mm_bcd <= mm_inc;
				end
			end
		endcase
	end
end

endmodule
