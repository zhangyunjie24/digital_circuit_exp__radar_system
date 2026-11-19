`timescale 1us/1ns
// tb_ultrasonic —— ultrasonic 测试台
//
// 用行为模型代替 HC-SR04：Trig 下降沿后延迟一段时间，再给出指定宽度的 Echo 高电平。
// 期望距离 = floor(t × 17 / 100) mm。Echo 的跳变故意不对齐时钟沿（模拟异步输入）。
//
// 场景：量程下限、各分级边界（200/400/600/800 附近）、999↔1000 的 BCD 进位、
//       3999 不超量程、Echo 过长判超量程（不等下降沿）、无回波超时、
//       上一次 Echo 还没落下就来了新 start、测量中途再来 start 应被忽略、
//       Echo 毛刺（< 20mm）应被丢掉。
module tb_ultrasonic;

reg clk = 0;
always #0.5 clk = ~clk;

reg rst, start, echo, abort;
// 1ms 节拍（等 Echo 超时按 ms 数）
integer us_n = 0;
reg tick_1ms = 0;
always@(posedge clk) begin
	us_n = us_n + 1;
	tick_1ms <= (us_n % 1000 == 0);
end
wire trig, done, oor;
wire [15:0] mm_bcd;

ultrasonic ultrasonic_1(
	.clk(clk), .rst(rst), .tick_1ms(tick_1ms), .start(start), .abort(abort), .echo(echo),
	.trig(trig), .done(done), .mm_bcd(mm_bcd), .oor(oor));

integer errors = 0;

// ---- 十进制 → 4 位 BCD ----
function [15:0] to_bcd;
	input integer v;
	reg [3:0] a, b, c, d;
	begin
		a = v / 1000 % 10;
		b = v / 100 % 10;
		c = v / 10 % 10;
		d = v % 10;
		to_bcd = {a, b, c, d};
	end
endfunction

// ---- 监视：Trig 宽度、done 次数 ----
integer trig_w = 0, trig_last_w = 0, trig_cnt = 0;
integer done_cnt = 0;
always@(posedge clk) begin
	if (trig) trig_w = trig_w + 1;
	else if (trig_w != 0) begin
		trig_last_w = trig_w;
		trig_cnt = trig_cnt + 1;
		trig_w = 0;
	end
	if (done) done_cnt = done_cnt + 1;
end

// done 必须是单周期
always@(posedge clk) begin
	if (done) begin
		@(posedge clk);
		#0.1;
		if (done) begin
			$display("  [FAIL] done 持续超过 1 个周期");
			errors = errors + 1;
		end
	end
end

// ---- 发一个 start 脉冲（对齐到时钟下降沿，避免竞争）----
task pulse_start;
	begin
		@(negedge clk);
		start = 1;
		@(negedge clk);
		start = 0;
	end
endtask

// ---- 等 done，超时报错；返回 done 时刻 ----
realtime t_done;
task wait_done;
	input integer max_us;
	integer k;
	begin : wd
		for (k = 0; k < max_us; k = k + 1) begin
			@(posedge clk);
			#0.1;
			if (done) begin
				t_done = $realtime;
				disable wd;
			end
		end
		$display("  [FAIL] %0dµs 内没有等到 done", max_us);
		errors = errors + 1;
	end
endtask

// ---- 检查结果 ----
task check;
	input [8*24:1] name;
	input integer want_mm;		// want_oor=1 时忽略
	input want_oor;
	begin
		if (want_oor) begin
			if (oor !== 1'b1) begin
				$display("  [FAIL] %0s: 期望超量程，实际 oor=%b mm=%h", name, oor, mm_bcd);
				errors = errors + 1;
			end
			else
				$display("  [ok]   %0s: oor", name);
		end
		else begin
			if (oor !== 1'b0 || mm_bcd !== to_bcd(want_mm)) begin
				$display("  [FAIL] %0s: 期望 %0dmm，实际 oor=%b mm=%h", name, want_mm, oor, mm_bcd);
				errors = errors + 1;
			end
			else
				$display("  [ok]   %0s: %hmm", name, mm_bcd);
		end
	end
endtask

// ---- 一次完整测量：start → 等 Trig 结束 → 延迟 → Echo 高 t µs ----
task measure;
	input [8*24:1] name;
	input integer t_us;			// Echo 高电平宽度
	input integer want_oor;
	integer d0;
	begin
		d0 = done_cnt;
		pulse_start;
		@(negedge trig);
		#(450.3);					// 模块发 8 个 40kHz 脉冲的时间，取个非整数
		echo = 1;
		#(t_us);
		echo = 0;
		if (!want_oor)
			wait_done(20);
		#(1000);					// 两次测量之间的间隔（也等监视器把 done 计上）
		if (done_cnt != d0 + 1) begin
			$display("  [FAIL] %0s: done 次数 %0d，期望 1", name, done_cnt - d0);
			errors = errors + 1;
		end
		check(name, (t_us * 17) / 100, want_oor);
		if (trig_last_w != 12) begin
			$display("  [FAIL] %0s: Trig 宽度 %0dµs，期望 12", name, trig_last_w);
			errors = errors + 1;
		end
	end
endtask

realtime t_rise;
integer d0, tc0;

initial begin
	rst = 1; start = 0; echo = 0; abort = 0;
	#(10.3);
	rst = 0;
	#(20);

	$display("==== 1. 正常测距（含分级边界、BCD 进位）====");
	measure("下限 20mm",      118,   0);	// 20.06 → 20
	measure("199mm",          1176,  0);	// 199.92
	measure("200mm",          1177,  0);	// 200.09
	measure("399mm",          2352,  0);	// 399.84
	measure("400mm",          2353,  0);	// 400.01
	measure("599mm",          3529,  0);	// 599.93
	measure("600mm",          3530,  0);	// 600.1
	measure("799mm",          4705,  0);	// 799.85
	measure("800mm",          4706,  0);	// 800.02
	measure("999mm",          5882,  0);	// 999.94
	measure("1000mm",         5883,  0);	// 1000.11
	measure("3999mm",         23529, 0);	// 3999.93

	$display("==== 2. Echo 过长 → 计到 4000 即判超量程，不等下降沿 ====");
	d0 = done_cnt;
	pulse_start;
	@(negedge trig);
	#(450.3);
	echo = 1;
	t_rise = $realtime;
	wait_done(30000);
	check("Echo 38ms", 0, 1);
	if ($realtime - t_rise > 23540 || $realtime - t_rise < 23525) begin
		$display("  [FAIL] 超量程判定时刻 %0.1fµs（期望约 23530µs）", $realtime - t_rise);
		errors = errors + 1;
	end
	else
		$display("  [ok]   Echo 上升后 %0.1fµs 判超量程", $realtime - t_rise);

	$display("==== 3. 上一次 Echo 还没落下就来了新 start（按上升沿判断，不能误测）====");
	// 此时 Echo 仍为高（模拟无障碍时 HC-SR04 拉高 38ms）
	pulse_start;
	#(3000);
	echo = 0;			// 上一次的 Echo 落下
	#(500.3);
	echo = 1;			// 这一次的真回波
	#(2941);			// 499.97 → 499
	echo = 0;
	wait_done(20);
	check("旧 Echo 未落下", 499, 0);
	#(1000);

	$display("==== 4. 无回波 → 10ms 超时判超量程 ====");
	pulse_start;
	@(negedge trig);
	t_rise = $realtime;
	wait_done(11000);
	check("无回波", 0, 1);
	if ($realtime - t_rise > 10010 || $realtime - t_rise < 8990) begin	// 按 tick_1ms 数 10 下：9~10ms
		$display("  [FAIL] 超时时刻 %0.1fµs（期望 9000~10000µs）", $realtime - t_rise);
		errors = errors + 1;
	end
	else
		$display("  [ok]   Trig 结束后 %0.1fµs 超时", $realtime - t_rise);
	#(1000);

	$display("==== 5. 测量中途再来 start → 忽略 ====");
	tc0 = trig_cnt;
	d0  = done_cnt;
	pulse_start;
	@(negedge trig);
	#(450.3);
	echo = 1;
	#(1000);
	pulse_start;		// 中途插入
	#(1000);
	echo = 0;			// 总宽 2000µs → 340mm
	wait_done(20);
	#(100);
	check("中途 start", 340, 0);
	if (trig_cnt != tc0 + 1 || done_cnt != d0 + 1) begin
		$display("  [FAIL] 中途 start 未被忽略：Trig %0d 次、done %0d 次", trig_cnt - tc0, done_cnt - d0);
		errors = errors + 1;
	end

	$display("==== 6. done 之后 mm_bcd 保持不变 ====");
	#(5000);
	check("保持", 340, 0);
	
	$display("==== 7. 测到一半 abort → 不发 done，之后能正常测量 ====");
	d0 = done_cnt;
	pulse_start;
	@(negedge trig);
	#(450.3);
	echo = 1;
	#(1000);
	@(negedge clk); abort = 1; @(negedge clk); abort = 0;
	#(2000);
	echo = 0;
	#(30000);
	if (done_cnt != d0) begin
		$display("  [FAIL] abort 之后仍发了 %0d 次 done", done_cnt - d0); errors = errors + 1;
	end
	else
		$display("  [ok]   abort：没有发 done");
	measure("abort 之后", 2941, 0);	// 499mm

	$display("==== 8. Echo 毛刺（< 20mm）→ 丢掉，接着等真回波 ====");
	d0 = done_cnt;
	pulse_start;
	@(negedge trig);
	#(200.3);
	echo = 1; #(3);   echo = 0;		// 3µs 毛刺
	#(100);
	echo = 1; #(117); echo = 0;		// 19.89mm，刚好低于下限
	#(150);
	echo = 1; #(2941); echo = 0;	// 真回波 499mm
	wait_done(20);
	#(1000);
	check("毛刺后真回波", 499, 0);
	if (done_cnt != d0 + 1) begin
		$display("  [FAIL] 毛刺场景 done 次数 %0d，期望 1", done_cnt - d0); errors = errors + 1;
	end

	// 只有毛刺、没有真回波 → 照常 10ms 超时
	pulse_start;
	@(negedge trig);
	t_rise = $realtime;
	#(450.3);
	echo = 1; #(5); echo = 0;
	wait_done(11000);
	check("只有毛刺", 0, 1);
	if ($realtime - t_rise > 10010 || $realtime - t_rise < 8990) begin
		$display("  [FAIL] 超时时刻 %0.1fµs（期望 9000~10000µs）", $realtime - t_rise);
		errors = errors + 1;
	end
	else
		$display("  [ok]   毛刺后 Trig 结束 %0.1fµs 超时", $realtime - t_rise);
	#(1000);

	$display("");
	if (errors == 0)
		$display("==== ALL PASS ====");
	else
		$display("==== %0d ERROR(S) ====", errors);
	$finish;
end

endmodule
