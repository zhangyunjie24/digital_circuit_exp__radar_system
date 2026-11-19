// scan_engine —— 通用扫描节拍
//
// SCAN_STEP 和 SCAN_CONT 本质是同一个循环，只是"角度步长"和"每档节拍时长"两个参数不同：
//
//              角度步长   节拍时长   稳定时间   单程(0→180)   一整圈
//   SCAN_STEP    45°       2000ms     500ms     4档=8秒      8档=16秒
//   SCAN_CONT     2°        100ms      20ms    90档=9秒       约18秒
//
// 每个节拍：舵机目标角度前进一档 → 等稳定时间 → 发一次 meas_start 触发测距 →
//           节拍剩余时间维持不变。角度在 0~180 之间来回反弹。
// STEP 每档只测一次，测出 "----" 要停 2 秒，所以超量程时在 600ms 再测一次（只重测一次）；
// CONT 每 100ms 就测一次，不重测。
//
// 【资源】角度/脉宽的加减必须只保留一份。最初把"前进一档"写成 task 在 4 个分支里调用，
//   被展开成 4 份加减法器，整个模块 214 个逻辑单元。现在把"增量"算成一个带符号常量选择，
//   角度和脉宽各只有一个加法器。
module scan_engine(
	input clk,
	input rst,
	input tick_1ms,
	input scan_en,				// phase==SCAN；为 0 时输出回零位
	input mode_cont,			// 0=SCAN_STEP，1=SCAN_CONT
	input restart,				// 脉冲：回到 0°、序列位置清零
	input meas_oor,				// ultrasonic 上一次结果是超量程（STEP 重测用）

	output reg [11:0] pulse_us,	// 舵机目标脉宽 500~2500µs
	output reg [7:0] angle_deg,	// 当前目标角度 0~180
	output [2:0] dir_idx,		// 角度就近取整到 5 个方向
	output reg meas_start,		// 单周期脉冲：稳定时间结束时发一次
	output phase_tick			// scan_en=0 期间每 2000ms 一个单周期脉冲（给 sys_fsm 切自检/待机/扫描，共用本模块的 ms_cnt）
);

// ---- 两套参数（直接给出"计到几"，省掉减法器）----
// CONT 重新开始后的第一个节拍拉长到 500ms（480ms 时测距）：按键切换时舵机可能还停在 180° 附近，
// 回 0° 要约 0.36s，只等 20ms 就测会把转动途中的读数记到 0° 方向上。STEP 本来就等 500ms，不受影响。
reg first;					// 1=重新开始后的第一个节拍
wire [10:0] beat_last   = !mode_cont ? 11'd1999 : first ? 11'd499 : 11'd99;
wire [10:0] settle_last = !mode_cont ? 11'd499  : first ? 11'd479 : 11'd19;

reg [10:0] ms_cnt;
// 【资源】自检、待机各 2 秒的计时和扫描节拍不会同时用，共用这一个 ms_cnt
//   （原来 sys_fsm 里另有一个 11 位计数器）。phase_tick 来的同一拍 ms_cnt 回 0，扫描从 0 开始计
assign phase_tick = !scan_en && tick_1ms && (ms_cnt == 11'd1999);
reg up;						// 1=角度递增，0=递减

// CONT 模式的脉宽累加：每 2° 对应 200/9 ≈ 22.22µs
// 用"每步 +22、余数每攒够 9 再 +1"的方式精确累加，避免乘除法。
// 累加值恰好等于 floor(角度 × 100 / 9)，端点 0°/180° 精确落在 500/2500µs。
reg [3:0] rem;				// 0~8

// ---- 本拍往哪个方向走（到端点就反弹）----
wire going_up = up ? (angle_deg < 8'd180) : (angle_deg == 8'd0);

// ---- 余数进位 ----
wire rem_carry = mode_cont && (going_up ? (rem >= 4'd7) : (rem < 4'd2));
wire [3:0] rem_next = !mode_cont ? rem
                    : rem + (going_up ? (rem_carry ? -4'd7 : 4'd2)
                                      : (rem_carry ? 4'd7 : -4'd2));

// ---- 增量：一律做成"常量选择 + 单个加法器"，不要写成 a+b / a-b 两套 ----
wire [7:0] angle_delta = mode_cont ? (going_up ? 8'd2   : -8'd2)
                                   : (going_up ? 8'd45  : -8'd45);

wire [11:0] pulse_delta = !mode_cont ? (going_up ? 12'd500 : -12'd500)
                        : going_up   ? (rem_carry ? 12'd23  : 12'd22)
                                     : (rem_carry ? -12'd23 : -12'd22);

always@(posedge clk or posedge rst) begin
	if (rst) begin
		ms_cnt     <= 0;
		up         <= 1'b1;
		angle_deg  <= 8'd0;
		pulse_us   <= 12'd500;
		rem        <= 4'd0;
		meas_start <= 1'b0;
		first      <= 1'b1;
	end
	else begin
		meas_start <= 1'b0;			// 默认单周期
		
		if (!scan_en || restart) begin
			// 回零位：0°、序列从头开始（scan_en=0 时 ms_cnt 改为给 sys_fsm 计 2 秒）
			if (restart || phase_tick)
				ms_cnt <= 0;
			else if (tick_1ms)
				ms_cnt <= ms_cnt + 1'b1;
			up        <= 1'b1;
			angle_deg <= 8'd0;
			pulse_us  <= 12'd500;
			rem       <= 4'd0;
			first     <= 1'b1;
		end
		else if (tick_1ms) begin
			// 稳定时间结束 → 触发一次测距
			// ms_cnt 从 0 开始计，所以第 settle_ms 个 tick 时 ms_cnt 是 settle_ms-1
			// STEP 重测：第一次（500ms）测出超量程，600ms 时再测一次。
			// 隔 100ms：无回波时 HC-SR04 的 Echo 可能拉高 38ms，太早再触发会被模块忽略
			if (ms_cnt == settle_last || (!mode_cont && meas_oor && ms_cnt == 11'd599))
				meas_start <= 1'b1;
			
			if (ms_cnt == beat_last) begin
				ms_cnt    <= 0;
				up        <= going_up;
				angle_deg <= angle_deg + angle_delta;
				pulse_us  <= pulse_us  + pulse_delta;
				rem       <= rem_next;
				first     <= 1'b0;
			end
			else
				ms_cnt <= ms_cnt + 1'b1;
		end
	end
end

// ---- 角度就近取整到 0/45/90/135/180 ----
assign dir_idx = (angle_deg <  8'd23)  ? 3'd0 :
                 (angle_deg <  8'd68)  ? 3'd1 :
                 (angle_deg <  8'd113) ? 3'd2 :
                 (angle_deg <  8'd158) ? 3'd3 : 3'd4;

endmodule
