`timescale 1us/1ns
// tb_scan —— scan_engine + servo_pwm 测试台
//
// 第一部分测 scan_engine：把 tick_1ms 加速成"每个时钟一拍"，
//   这样 STEP 的 2000ms 节拍只要 2000 个时钟，一整圈 16 秒 → 16000 时钟，秒出结果。
// 第二部分测 servo_pwm：用真实时序量高电平宽度和周期。
module tb_scan;

reg clk = 0;
always #0.5 clk = ~clk;

reg rst, tick_1ms, scan_en, mode_cont, restart, meas_oor;
wire [11:0] pulse_us;
wire [7:0]  angle_deg;
wire [2:0]  dir_idx;
wire meas_start;

scan_engine scan_engine_1(
	.clk(clk), .rst(rst), .tick_1ms(tick_1ms),
	.scan_en(scan_en), .mode_cont(mode_cont), .restart(restart), .meas_oor(meas_oor),
	.pulse_us(pulse_us), .angle_deg(angle_deg),
	.dir_idx(dir_idx), .meas_start(meas_start));

reg servo_en;
reg [11:0] servo_pulse;
wire servo;
// servo_pwm 用真实的 1ms 节拍（scan_engine 那部分的 tick_1ms 是加速过的）
reg [9:0] us_cnt = 0;
reg servo_tick = 0;
always@(posedge clk) begin
	if (us_cnt == 999) begin us_cnt <= 0; servo_tick <= 1; end
	else begin us_cnt <= us_cnt + 1'b1; servo_tick <= 0; end
end
servo_pwm servo_pwm_1(
	.clk(clk), .rst(rst), .tick_1ms(servo_tick), .en(servo_en), .pulse_us(servo_pulse), .servo(servo));

integer errors = 0;
task fail; input [8*60:1] msg; begin $display("  [FAIL] %0s", msg); errors = errors + 1; end endtask

// ============ 不变量：脉宽必须和角度对得上 ============
// 0°→500µs，180°→2500µs，线性：pulse = 500 + angle*100/9
// CONT 用累加实现，取整到 floor，误差 <1µs
integer want_pulse;
always@(posedge clk) begin
	if (!rst && scan_en) begin
		want_pulse = 500 + (angle_deg * 100) / 9;
		if (pulse_us !== want_pulse) begin
			$display("  [FAIL] angle=%0d 时 pulse=%0d, 期望 %0d", angle_deg, pulse_us, want_pulse);
			errors = errors + 1;
		end
	end
end

// ============ 方向取整检查 ============
integer want_dir;
always@(posedge clk) begin
	if (!rst) begin
		want_dir = (angle_deg < 23) ? 0 : (angle_deg < 68) ? 1 :
		           (angle_deg < 113) ? 2 : (angle_deg < 158) ? 3 : 4;
		if (dir_idx !== want_dir) begin
			$display("  [FAIL] angle=%0d 时 dir_idx=%0d, 期望 %0d", angle_deg, dir_idx, want_dir);
			errors = errors + 1;
		end
	end
end

// ============ 记录角度变化序列 + meas_start 计时 ============
reg [7:0] prev_angle;
integer beats, meas_cnt, ms_since_beat, meas_ms;
integer meas_in_beat, prev_beat_meas, first_ms;	// 本节拍/上一节拍 meas_start 次数、第一次的时刻（测 STEP 重测）
reg meas_seen_this_beat;

always@(posedge clk) begin
	if (rst) begin
		prev_angle <= 0; ms_since_beat = 0; meas_seen_this_beat = 0;
	end
	else begin
		if (tick_1ms) ms_since_beat = ms_since_beat + 1;
		
		if (meas_start) begin
			meas_cnt = meas_cnt + 1;
			meas_ms  = ms_since_beat;
			if (!meas_seen_this_beat) first_ms = ms_since_beat;
			if (meas_seen_this_beat && !meas_oor) fail("没有超量程，同一个节拍里 meas_start 却发了两次");
			meas_seen_this_beat = 1;
			meas_in_beat = meas_in_beat + 1;
		end
		
		if (angle_deg !== prev_angle) begin
			beats = beats + 1;
			if (!meas_seen_this_beat) fail("上一个节拍没有发 meas_start");
			prev_angle <= angle_deg;
			ms_since_beat = 0;
			meas_seen_this_beat = 0;
			prev_beat_meas = meas_in_beat;
			meas_in_beat = 0;
		end
	end
end

// ============ 测 servo_pwm ============
task check_servo;
	input [11:0] p;
	integer high, total, t;
	begin
		servo_pulse = p; servo_en = 1;
		@(posedge clk);
		// 等一个新周期开始（servo 刚拉高）
		while (servo !== 1'b0) @(posedge clk);
		while (servo !== 1'b1) @(posedge clk);
		high = 0; total = 0;
		// 量一整个周期
		for (t = 0; t < 20000; t = t + 1) begin
			if (servo) high = high + 1;
			@(posedge clk);
		end
		if (high < p - 2 || high > p + 2) begin
			$display("  [FAIL] pulse_us=%0d 实测高电平 %0d µs", p, high);
			errors = errors + 1;
		end
		else if (servo !== 1'b1) begin
			$display("  [FAIL] pulse_us=%0d：20000µs 后没有开始下一个周期", p);
			errors = errors + 1;
		end
		else
			$display("  [ok] servo pulse_us=%0d -> high=%0d us (period 20000)", p, high);
	end
endtask

// ============ 主流程 ============
integer i;
reg [7:0] seq [0:15];
initial begin
	rst = 1; tick_1ms = 0; scan_en = 0; mode_cont = 0; restart = 0; meas_oor = 0;
	meas_in_beat = 0;
	servo_en = 0; servo_pulse = 12'd1500;
	beats = 0; meas_cnt = 0;
	#5;
	if (pulse_us !== 12'd500 || angle_deg !== 0) fail("复位后没有回到 0 度/500us");
	if (servo !== 1'b0) fail("复位后 servo 不是低电平");
	rst = 0; #5;
	
	// ---- servo_pwm：en=0 应该恒低 ----
	servo_en = 0; servo_pulse = 12'd2500;
	for (i = 0; i < 25000; i = i + 1) begin
		@(posedge clk);
		if (servo !== 1'b0) begin fail("en=0 时 servo 仍在输出 PWM"); i = 25000; end
	end
	$display("  [ok] en=0 时 servo 恒低");
	
	// ---- servo_pwm：三个角度 ----
	check_servo(12'd500);	// 0
	check_servo(12'd1500);	// 90
	check_servo(12'd2500);	// 180
	servo_en = 0;
	
	// ---- scan_engine：STEP 模式，tick_1ms 加速 ----
	$display("  -- STEP mode --");
	mode_cont = 0; scan_en = 1;
	beats = 0; meas_cnt = 0;
	prev_angle = 0;
	
	// 跑 2 整圈 = 16 个节拍，记录角度序列
	for (i = 0; i < 16; i = i + 1) begin
		seq[i] = angle_deg;
		// 等到角度变化
		begin : wait_beat
			integer g;
			for (g = 0; g < 5000; g = g + 1) begin
				@(posedge clk); tick_1ms = 1; @(posedge clk); tick_1ms = 0;
				if (angle_deg !== seq[i]) disable wait_beat;
			end
			fail("STEP 节拍超时，角度一直没变");
		end
	end
	
	$write("  STEP 角度序列:");
	for (i = 0; i < 16; i = i + 1) $write(" %0d", seq[i]);
	$display("");
	// 期望 0,45,90,135,180,135,90,45 循环
	for (i = 0; i < 16; i = i + 1) begin
		case (i % 8)
			0: if (seq[i] !== 0)   fail("STEP 序列第 0 档应为 0");
			1: if (seq[i] !== 45)  fail("STEP 序列第 1 档应为 45");
			2: if (seq[i] !== 90)  fail("STEP 序列第 2 档应为 90");
			3: if (seq[i] !== 135) fail("STEP 序列第 3 档应为 135");
			4: if (seq[i] !== 180) fail("STEP 序列第 4 档应为 180");
			5: if (seq[i] !== 135) fail("STEP 序列第 5 档应为 135");
			6: if (seq[i] !== 90)  fail("STEP 序列第 6 档应为 90");
			7: if (seq[i] !== 45)  fail("STEP 序列第 7 档应为 45");
		endcase
	end
	if (meas_ms !== 500) begin
		$display("  [FAIL] STEP 的 meas_start 在节拍第 %0d ms，期望 500", meas_ms);
		errors = errors + 1;
	end
	else $display("  [ok] STEP: meas_start 在节拍第 500ms");

	// ---- STEP 超量程重测：500ms 测一次、600ms 再测一次，共 2 次 ----
	meas_oor = 1;
	begin : step_retry
		reg [7:0] a0;
		integer g;
		a0 = angle_deg;
		for (g = 0; g < 5000; g = g + 1) begin
			@(posedge clk); tick_1ms = 1; @(posedge clk); tick_1ms = 0;
			if (angle_deg !== a0) disable step_retry;
		end
	end
	meas_oor = 0;
	if (prev_beat_meas !== 2 || first_ms !== 500 || meas_ms !== 600) begin
		$display("  [FAIL] STEP 超量程重测：%0d 次，第一次 %0dms、最后一次 %0dms（期望 2 次，500/600ms）",
		         prev_beat_meas, first_ms, meas_ms);
		errors = errors + 1;
	end
	else $display("  [ok] STEP 超量程：500ms 测一次，600ms 重测一次");
	// 走回 0°，否则下面 restart 在节拍中途把角度拉回 0，监视器会误报"没有发 meas_start"
	begin : step_back0
		integer g;
		for (g = 0; g < 20000; g = g + 1) begin
			@(posedge clk); tick_1ms = 1; @(posedge clk); tick_1ms = 0;
			if (angle_deg == 0) disable step_back0;
		end
	end

	// ---- restart：立刻回零 ----
	@(posedge clk); restart = 1; @(posedge clk); restart = 0; @(posedge clk);
	if (angle_deg !== 0 || pulse_us !== 500) fail("restart 后没有回到 0 度");
	else $display("  [ok] restart 回零位");
	
	// ---- scan_en=0 ----
	scan_en = 0; @(posedge clk); @(posedge clk);
	if (angle_deg !== 0 || pulse_us !== 500) fail("scan_en=0 时没有回到 0 度");
	else $display("  [ok] scan_en=0 回零位");
	@(posedge clk); restart = 1; @(posedge clk); restart = 0;		// scan_en=0 期间 ms_cnt 在给 sys_fsm 计时，重新开始扫描前清零
	
	// ---- CONT 模式：走满一个单程，检查端点 ----
	$display("  -- CONT mode --");
	mode_cont = 1; scan_en = 1;
	prev_angle = 0;
	ms_since_beat = 0;		// STEP 段最后一个 tick 会残留 1ms，这里从零开始计
	// 第一个节拍：500ms 才前进、480ms 时测距（等舵机从任意位置回到 0°）
	begin : cont_first
		integer g;
		for (g = 0; g < 1000; g = g + 1) begin
			@(posedge clk); tick_1ms = 1; @(posedge clk); tick_1ms = 0;
			if (angle_deg != 0) disable cont_first;
		end
	end
	if (meas_ms !== 480) begin
		$display("  [FAIL] CONT 第一个节拍：meas_start 在第 %0d ms（期望 480）", meas_ms);
		errors = errors + 1;
	end
	else $display("  [ok] CONT 第一个节拍 500ms，meas_start 在第 480ms");
	meas_oor = 1;			// CONT 不重测：即使超量程，每个节拍也只发一次
	begin : cont_sweep
		integer g, hit180;
		hit180 = 0;
		for (g = 0; g < 400000; g = g + 1) begin
			@(posedge clk); tick_1ms = 1; @(posedge clk); tick_1ms = 0;
			if (angle_deg == 180) hit180 = 1;
			if (hit180 && angle_deg == 0) disable cont_sweep;
		end
		fail("CONT 没能在限定时间内走完 0->180->0");
	end
	$display("  [ok] CONT 走完 0->180->0，端点脉宽 500/2500 已由不变量检查覆盖");
	if (meas_ms !== 20) begin
		$display("  [FAIL] CONT 的 meas_start 在节拍第 %0d ms，期望 20", meas_ms);
		errors = errors + 1;
	end
	else $display("  [ok] CONT: meas_start 在节拍第 20ms");
	if (prev_beat_meas !== 1) begin
		$display("  [FAIL] CONT 超量程时一个节拍发了 %0d 次 meas_start（期望 1，不重测）", prev_beat_meas);
		errors = errors + 1;
	end
	else $display("  [ok] CONT 超量程不重测");
	meas_oor = 0;
	
	$display("");
	if (errors == 0) $display("==== RESULT: PASS (0 errors) ====");
	else             $display("==== RESULT: FAIL (%0d errors) ====", errors);
	$finish;
end

endmodule
