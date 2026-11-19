`timescale 1us/1ns
// tb_alarm —— 第 5 步测试台：dist_band + result_reg + alarm_ctrl + buzzer_ctrl
//
// 1. dist_band：0~3999mm 穷举 + 超量程
// 2. result_reg：done 时锁存、strobe 晚一拍、clear 回到"尚无数据"
// 3. alarm_ctrl：所有 phase × band × blink 组合
// 4. buzzer_ctrl：用真实 1ms 节拍，每个分级跑 2 秒，统计"响了几段、共响多少 ms"，并量音调周期
module tb_alarm;

reg clk = 0;
always #0.5 clk = ~clk;

reg rst;
integer errors = 0;

// ---- 真实时基（buzzer_ctrl 的节奏、音调都取自 timebase）----
wire tick_1ms, tone_2k, tb_blink_2hz, tb_blink_1hz, beat_100ms;
timebase timebase_1(
	.clk(clk), .rst(rst), .tick_1ms(tick_1ms), .tone_2k(tone_2k),
	.blink_2hz(tb_blink_2hz), .blink_1hz(tb_blink_1hz), .beat_100ms(beat_100ms));

// ============ 被测模块 ============
reg [15:0] mm_bcd;
reg oor;
wire [2:0] band;
dist_band dist_band_1(.mm_bcd(mm_bcd), .oor(oor), .band(band));

reg clear, done;
reg [11:0] angle_bcd;
wire [11:0] r_angle_bcd;
wire [15:0] r_dist_bcd;
wire r_valid, r_oor, r_strobe;
wire [2:0] r_band;
result_reg result_reg_1(
	.clk(clk), .rst(rst), .clear(clear), .done(done),
	.angle_bcd(angle_bcd), .mm_bcd(mm_bcd), .oor(oor), .band(band),
	.r_angle_bcd(r_angle_bcd), .r_dist_bcd(r_dist_bcd), .r_valid(r_valid),
	.r_oor(r_oor), .r_band(r_band), .r_strobe(r_strobe));

reg [1:0] phase;
reg blink_2hz;
reg [2:0] t_band;		// alarm/buzzer 的分级输入，直接由测试台给
wire [15:0] ld;
alarm_ctrl alarm_ctrl_1(.rst(rst), .phase(phase), .blink_2hz(blink_2hz), .r_band(t_band), .ld(ld));

wire buzzer;
buzzer_ctrl buzzer_ctrl_1(
	.clk(clk), .rst(rst), .tone_2k(tone_2k), .beat_100ms(beat_100ms),
	.blink_2hz(tb_blink_2hz), .blink_1hz(tb_blink_1hz),
	.phase(phase), .r_band(t_band), .buzzer(buzzer));

// ---- 工具 ----
function [15:0] to_bcd;
	input integer v;
	reg [3:0] a, b, c, d;
	begin
		a = v / 1000 % 10; b = v / 100 % 10; c = v / 10 % 10; d = v % 10;
		to_bcd = {a, b, c, d};
	end
endfunction

function [2:0] want_band;
	input integer v;
	begin
		want_band = (v >= 800) ? 0 : (v >= 600) ? 1 : (v >= 400) ? 2 : (v >= 200) ? 3 : 4;
	end
endfunction

// 和 alarm_ctrl 里的占位掩码保持一致
localparam [15:0] MASK_BLUE = 16'h000F, MASK_GREEN = 16'h00F0,
                  MASK_YELLOW = 16'h0F00, MASK_RED = 16'hF000;

function [15:0] want_ld;
	input [1:0] ph;
	input bl;
	input [2:0] b;
	reg [15:0] k;
	begin
		k = {16{bl}};
		if (ph == 0)      want_ld = k;
		else if (ph != 2) want_ld = 0;
		else case (b)
			0: want_ld = MASK_BLUE;
			1: want_ld = MASK_GREEN & k;
			2: want_ld = MASK_YELLOW & k;
			3: want_ld = MASK_RED & k;
			4: want_ld = k;
			default: want_ld = 0;
		endcase
	end
endfunction

// ---- 蜂鸣器统计：每 1ms 窗口里有没有翻转 → "这 1ms 在响" ----
integer bz_toggles = 0;		// 当前 1ms 窗口内的翻转次数
integer bz_on_ms   = 0;		// 累计响了多少 ms
integer bz_run     = 0;		// 当前这段连续响了多少 ms
integer bz_max_run = 0;		// 最长一段（窗口起点可能切在一段中间，所以不数段数）
reg     bz_prev_ms_on = 0;
reg     bz_prev = 0;
integer bz_last_edge = -1, bz_min_half = 1000000, bz_max_half = 0, now_us = 0;
always@(posedge clk) begin
	now_us = now_us + 1;
	if (buzzer !== bz_prev) begin
		bz_toggles = bz_toggles + 1;
		if (bz_last_edge >= 0 && bz_prev_ms_on) begin
			if (now_us - bz_last_edge < bz_min_half) bz_min_half = now_us - bz_last_edge;
			if (now_us - bz_last_edge > bz_max_half) bz_max_half = now_us - bz_last_edge;
		end
		bz_last_edge = now_us;
		bz_prev = buzzer;
	end
	if (tick_1ms) begin
		if (bz_toggles > 0) begin
			bz_on_ms = bz_on_ms + 1;
			bz_run = bz_run + 1;
			if (bz_run > bz_max_run) bz_max_run = bz_run;
		end
		else
			bz_run = 0;
		bz_prev_ms_on = (bz_toggles > 0);
		bz_toggles = 0;
	end
end

task bz_reset;
	begin
		bz_on_ms = 0; bz_run = 0; bz_max_run = 0; bz_min_half = 1000000; bz_max_half = 0;
	end
endtask

// 跑 2000ms（各节奏周期的整数倍），核对：最长一段多长、总共响多少 ms。
// 1ms 统计窗口和响声边界不对齐，每段会多计约 1ms，所以总时长按 2% 放宽。
// 音调周期只在常响时量：一段响声的开头/结尾会把方波截成不完整的半周期。
task bz_check;
	input [1:0] ph;
	input [2:0] b;
	input integer want_run;
	input integer want_ms;
	begin
		phase = ph; t_band = b;
		#(1000);			// 让上一个设置的尾巴过去
		bz_reset;
		#(2000000);
		if (bz_max_run < want_run - 2 || bz_max_run > want_run + 2 ||
		    bz_on_ms < want_ms || bz_on_ms > want_ms + want_ms / 50 + 2) begin
			$display("  [FAIL] phase=%0d band=%0d：最长一段 %0dms、共响 %0dms，期望 %0dms、%0dms",
			         ph, b, bz_max_run, bz_on_ms, want_run, want_ms);
			errors = errors + 1;
		end
		else
			$display("  [ok]   phase=%0d band=%0d：最长一段 %0dms、共响 %0dms", ph, b, bz_max_run, bz_on_ms);
		if (want_run == 2000) begin
			// 音调取自 timebase 微秒计数器的第 8 位：半周期 256µs，计数器 999→0 回绕时有一次 232µs
			if (bz_min_half < 232 || bz_max_half > 256) begin
				$display("  [FAIL] 音调半周期 %0d~%0dµs，期望 232~256µs（约 2kHz）", bz_min_half, bz_max_half);
				errors = errors + 1;
			end
			else
				$display("  [ok]   音调半周期 %0d~%0dµs（约 2kHz）", bz_min_half, bz_max_half);
		end
	end
endtask

integer v, e, ph, bl, b;

initial begin
	rst = 1; mm_bcd = 0; oor = 0; clear = 0; done = 0; angle_bcd = 0;
	phase = 0; blink_2hz = 1; t_band = 4;
	#(10.3);
	// 复位态（SW7=0）：phase 停在 SELFTEST、blink=1 时 LED 也必须全灭
	if (ld !== 16'h0000) begin
		$display("  [FAIL] 复位时 ld=%h，应全灭（SW7=0 所有显示器件不显示）", ld);
		errors = errors + 1;
	end
	else
		$display("  [ok]   复位时 LED 全灭");
	blink_2hz = 0; t_band = 7;
	rst = 0;

	// ======================================================
	$display("==== 1. dist_band 穷举 0~3999mm + 超量程 ====");
	e = errors;
	for (v = 0; v < 4000; v = v + 1) begin
		mm_bcd = to_bcd(v); oor = 0;
		#(0.1);
		if (band !== want_band(v)) begin
			if (errors - e < 5) $display("  [FAIL] %0dmm → band=%0d，期望 %0d", v, band, want_band(v));
			errors = errors + 1;
		end
		oor = 1;
		#(0.1);
		if (band !== 0) begin
			if (errors - e < 5) $display("  [FAIL] %0dmm + oor → band=%0d，期望 0", v, band);
			errors = errors + 1;
		end
	end
	if (errors == e) $display("  [ok]   4000 个距离 × oor 全部正确");
	oor = 0;

	// ======================================================
	$display("==== 2. result_reg ====");
	@(negedge clk);
	if (r_valid !== 0 || r_band !== 7) begin
		$display("  [FAIL] 复位后应为尚无数据"); errors = errors + 1;
	end
	angle_bcd = 12'h135; mm_bcd = to_bcd(523); oor = 0;
	done = 1; @(negedge clk); done = 0;
	if (r_angle_bcd !== 12'h135 || r_dist_bcd !== 16'h0523 || r_valid !== 1 || r_oor !== 0 || r_band !== 2) begin
		$display("  [FAIL] 锁存错误：A=%h D=%h valid=%b oor=%b band=%0d", r_angle_bcd, r_dist_bcd, r_valid, r_oor, r_band);
		errors = errors + 1;
	end
	else
		$display("  [ok]   done 时锁存：A=%h D=%h band=%0d", r_angle_bcd, r_dist_bcd, r_band);
	if (r_strobe !== 1) begin
		$display("  [FAIL] r_strobe 应在 done 后一拍为 1"); errors = errors + 1;
	end
	// 输入变化但没有 done → 保持
	angle_bcd = 12'h180; mm_bcd = to_bcd(99);
	@(negedge clk);
	if (r_strobe !== 0) begin
		$display("  [FAIL] r_strobe 不是单周期"); errors = errors + 1;
	end
	if (r_angle_bcd !== 12'h135 || r_dist_bcd !== 16'h0523) begin
		$display("  [FAIL] 没有 done 时结果被改动"); errors = errors + 1;
	end
	else
		$display("  [ok]   没有 done 时保持不变");
	// 超量程
	oor = 1;
	done = 1; @(negedge clk); done = 0;
	if (r_oor !== 1 || r_band !== 0) begin
		$display("  [FAIL] 超量程锁存：oor=%b band=%0d", r_oor, r_band); errors = errors + 1;
	end
	else
		$display("  [ok]   超量程：oor=1 band=0");
	oor = 0;
	// clear
	clear = 1; @(negedge clk); clear = 0;
	if (r_valid !== 0 || r_band !== 7 || r_angle_bcd !== 0) begin
		$display("  [FAIL] clear 后应为尚无数据"); errors = errors + 1;
	end
	else
		$display("  [ok]   clear → 尚无数据（band=7）");

	// ======================================================
	$display("==== 3. alarm_ctrl 全组合 ====");
	e = errors;
	for (ph = 0; ph < 4; ph = ph + 1)
		for (bl = 0; bl < 2; bl = bl + 1)
			for (b = 0; b < 8; b = b + 1) begin
				phase = ph; blink_2hz = bl; t_band = b;
				#(0.1);
				if (ld !== want_ld(ph, bl, b)) begin
					$display("  [FAIL] phase=%0d blink=%0d band=%0d → ld=%h，期望 %h", ph, bl, b, ld, want_ld(ph, bl, b));
					errors = errors + 1;
				end
			end
	if (errors == e) $display("  [ok]   64 种组合全部正确");

	// ======================================================
	$display("==== 4. buzzer_ctrl（每项跑 2 秒）====");
	bz_check(2, 0, 0, 0);			// ≥800 不响
	bz_check(2, 1, 100, 200);		// 100ms/1000ms
	bz_check(2, 2, 100, 400);		// 100ms/500ms
	bz_check(2, 3, 100, 800);
	bz_check(2, 4, 2000, 2000);		// 常响
	bz_check(2, 7, 0, 0);			// 尚无数据不响
	bz_check(0, 4, 0, 0);			// 自检阶段不响
	bz_check(1, 4, 0, 0);			// 待机阶段不响
	// 从长周期跳到短周期：节奏取自公共时基，切换后立即按新周期响
	phase = 2; t_band = 1;
	#(800000);
	bz_check(2, 3, 100, 800);

	$display("");
	if (errors == 0)
		$display("==== ALL PASS ====");
	else
		$display("==== %0d ERROR(S) ====", errors);
	$finish;
end

endmodule
