`timescale 1us/1ns
// tb_top —— 顶层整体仿真：上电 → 自检 → 待机 → STEP 扫描走完 0°~180°
//
// HC-SR04 行为模型按舵机当前角度返回不同距离，让 5 个方向各落在不同分级：
//   0°→170mm(红)  45°→340mm(橙)  90°→510mm(黄)  135°→680mm(黄绿)  180°→无回波(超量程=绿，STEP 下会重测一次)
// 每次测距完成后核对：result_reg 锁存值、dir_mem 对应方向颜色、点阵输出确实有像素点亮。
// 之后按键切到 CONT 跑 3 秒，再按键切回 STEP：
//   CONT 第一个节拍 500ms（480ms 测距，等舵机回 0°），之后每 100ms 测一次、角度 +2°，
//   测得的颜色写到就近的方向上。
// 真实时序共跑约 20 秒（2000 万个时钟），需要一两分钟。
module tb_top;

reg clk = 0;
always #0.5 clk = ~clk;

reg sw7 = 0;
reg btn_mode = 0;
reg echo = 0;
wire trig, servo, buzzer;
wire [7:0] lcd_d;
wire lcd_cs_n, lcd_a0, lcd_wr_n, lcd_rd_n, lcd_rst_n;
wire [6:0] seg;
wire [7:0] cat, row;
wire [15:0] ld, row_color;

radar_system dut(
	.clk(clk), .sw7(sw7), .btn_mode(btn_mode), .echo(echo),
	.trig(trig), .servo(servo), .seg(seg), .cat(cat), .ld(ld),
	.row(row), .row_color(row_color), .buzzer(buzzer),
	.lcd_d(lcd_d), .lcd_cs_n(lcd_cs_n), .lcd_a0(lcd_a0), .lcd_wr_n(lcd_wr_n),
	.lcd_rd_n(lcd_rd_n), .lcd_rst_n(lcd_rst_n));

integer errors = 0;

// ---- HC-SR04 模型：Trig 下降沿后 450µs 给回波，距离按当前所属方向（就近取整）决定 ----
integer echo_us;
always@(negedge trig) begin
	case (dut.cur_dir)
		0: echo_us = 1000;		// 170mm → band 4 → 颜色 5 红
		1: echo_us = 2000;		// 340mm → band 3 → 颜色 4 橙
		2: echo_us = 3000;		// 510mm → band 2 → 颜色 3 黄
		3: echo_us = 4000;		// 680mm → band 1 → 颜色 2 黄绿
		default: echo_us = 0;	// 无回波 → 超量程 → band 0 → 颜色 1 绿
	endcase
	if (echo_us > 0) begin
		#(450.3);
		echo = 1;
		#(echo_us);
		echo = 0;
	end
end

// ---- 每次 done 之后核对 ----
integer n_done = 0;
reg [2:0] want_color;
// CONT 段统计
integer cont_n = 0, cont_bad = 0;
realtime cont_t0, cont_prev_t;
integer cont_prev_a;
function integer bcd2int;
	input [11:0] b;
	begin
		bcd2int = b[11:8] * 100 + b[7:4] * 10 + b[3:0];
	end
endfunction
always@(posedge clk) begin
	if (dut.r_strobe) begin
		n_done = n_done + 1;
		if (dut.mode_cont) begin
			// 第 1 次：restart 后约 480ms、角度 0；之后每次间隔 100ms、角度 +2
			if (cont_n == 0) begin
				if ($realtime - cont_t0 < 480000 || $realtime - cont_t0 > 482000 || bcd2int(dut.r_angle_bcd) != 0) begin
					$display("  [FAIL] CONT 第 1 次测距：restart 后 %0.1fms、角度 %h（期望约 480ms、000）",
					         ($realtime - cont_t0) / 1000, dut.r_angle_bcd);
					errors = errors + 1;
				end
			end
			else if (cont_n == 1) begin
				// 第 1 个节拍 500ms 结束 → 角度 2，节拍第 20ms 测 → 距上次约 40ms
				if (bcd2int(dut.r_angle_bcd) != 2 || $realtime - cont_prev_t < 39000 || $realtime - cont_prev_t > 41000) begin
					$display("  [FAIL] CONT 第 2 次测距：间隔 %0.1fms、角度 %h（期望约 40ms、002）",
					         ($realtime - cont_prev_t) / 1000, dut.r_angle_bcd);
					errors = errors + 1;
				end
			end
			else if (bcd2int(dut.r_angle_bcd) != cont_prev_a + 2 ||
			         $realtime - cont_prev_t < 99000 || $realtime - cont_prev_t > 101000) begin
				if (cont_bad < 5)
					$display("  [FAIL] CONT 第 %0d 次测距：间隔 %0.1fms、角度 %h（上次 %0d）", cont_n + 1,
					         ($realtime - cont_prev_t) / 1000, dut.r_angle_bcd, cont_prev_a);
				cont_bad = cont_bad + 1;
				errors = errors + 1;
			end
			cont_prev_t = $realtime;
			cont_prev_a = bcd2int(dut.r_angle_bcd);
			cont_n = cont_n + 1;
		end
		// 颜色检查两种模式都做；逐次打印只在 STEP 做（CONT 每 100ms 一次会刷屏）
		case (dut.cur_dir)
			0: want_color = 5;
			1: want_color = 4;
			2: want_color = 3;
			3: want_color = 2;
			default: want_color = 1;
		endcase
		if (!dut.mode_cont) $display("  t=%0.3fs  done：角度=%h 距离=%h oor=%b band=%0d  dir_mem=%o",
		         $realtime / 1e6, dut.r_angle_bcd, dut.r_dist_bcd, dut.r_oor, dut.r_band, dut.colors);
		if (dut.colors[dut.cur_dir*3 +: 3] !== want_color) begin
			$display("  [FAIL] 方向 %0d 颜色=%0d，期望 %0d", dut.cur_dir,
			         dut.colors[dut.cur_dir*3 +: 3], want_color);
			errors = errors + 1;
		end
		if (dut.r_band + 1 !== want_color) begin
			$display("  [FAIL] r_band=%0d，期望 %0d", dut.r_band, want_color - 1);
			errors = errors + 1;
		end
	end
end

// ---- 统计点阵在一段时间内是否有像素被点亮 ----
integer lit_cycles;
task count_lit;
	input integer us;
	integer k;
	begin
		lit_cycles = 0;
		for (k = 0; k < us; k = k + 1) begin
			@(posedge clk);
			if (row_color !== 16'h0000) lit_cycles = lit_cycles + 1;
		end
	end
endtask

// ---- 按键：按住 50ms 再松开（key_debounce 每 10ms 采样，需稳定 20ms）----
task press_btn;
	begin
		btn_mode = 1;
		@(posedge dut.restart);
		cont_t0 = $realtime;
		#(50000);
		btn_mode = 0;
		#(1000);
	end
endtask

initial begin
	#(10.3);
	sw7 = 1;
	$display("==== 上电，等自检+待机 4 秒 ====");
	#(4050000);			// 状态机在第 4.00001s 才进入 SCAN，留 50ms 余量
	if (dut.phase !== 2) begin
		$display("  [FAIL] 4 秒后 phase=%0d，期望 2(SCAN)", dut.phase); errors = errors + 1;
	end
	// 刚进入扫描、还没测过：点阵应全暗
	count_lit(20000);
	if (lit_cycles != 0) begin
		$display("  [FAIL] 扫描开始、未测距时点阵不应点亮（亮了 %0d 个周期）", lit_cycles);
		errors = errors + 1;
	end
	else
		$display("  [ok]   进入扫描、尚未测距：点阵全暗");

	$display("==== 走完 0°→180°（6 次测距）====");
	#(8950000);			// 到 13s：0/45/90/135 各测一次，180° 无回波 → 600ms 时重测一次，共 6 次
	if (n_done != 6) begin
		$display("  [FAIL] done 次数 %0d，期望 6（180° 超量程重测一次）", n_done); errors = errors + 1;
	end
	if (dut.colors !== {3'd1, 3'd2, 3'd3, 3'd4, 3'd5}) begin
		$display("  [FAIL] dir_mem=%o，期望 12345（八进制，180°在最高位）", dut.colors);
		errors = errors + 1;
	end
	else
		$display("  [ok]   dir_mem 5 个方向：红 橙 黄 黄绿 绿");
	count_lit(20000);
	if (lit_cycles == 0) begin
		$display("  [FAIL] 5 个方向都有颜色了，点阵却没有任何像素点亮");
		errors = errors + 1;
	end
	else
		$display("  [ok]   点阵输出有像素点亮（%0d/20000 个周期 row_color 非零）", lit_cycles);

	$display("==== 按键切到 CONT（按住 50ms）====");
	press_btn;
	if (dut.mode_cont !== 1 || dut.colors !== 0 || dut.r_valid !== 0 || dut.angle_deg !== 0) begin
		$display("  [FAIL] 切换后：mode_cont=%b dir_mem=%o r_valid=%b angle=%0d（期望 1/0/0/0）",
		         dut.mode_cont, dut.colors, dut.r_valid, dut.angle_deg);
		errors = errors + 1;
	end
	else
		$display("  [ok]   切到 CONT：点阵/结果清空，舵机目标回 0°");
	#(3000000 - (dut.mode_cont ? ($realtime - cont_t0) : 0));	// restart 后共 3 秒
	// 480ms 一次 + 之后 520、620、…、2920ms 共 25 次
	if (cont_n != 26) begin
		$display("  [FAIL] CONT 3 秒内测距 %0d 次，期望 26", cont_n); errors = errors + 1;
	end
	else if (cont_bad == 0)
		$display("  [ok]   CONT 3 秒测距 26 次：首次 480ms，之后每 100ms 一次、角度每次 +2°（最后 %0d°）", cont_prev_a);
	// 角度 0~22 属于 0° 方向（红），24~50 属于 45° 方向（橙），其余方向还没扫到
	if (dut.colors !== {3'd0, 3'd0, 3'd0, 3'd4, 3'd5}) begin
		$display("  [FAIL] CONT 3 秒后 dir_mem=%o，期望 00045", dut.colors); errors = errors + 1;
	end
	else
		$display("  [ok]   dir_mem=00045：0° 方向红、45° 方向橙（按就近取整写入）");
	
	$display("==== 再按一次切回 STEP ====");
	n_done = 0;
	press_btn;
	if (dut.mode_cont !== 0 || dut.colors !== 0 || dut.r_valid !== 0) begin
		$display("  [FAIL] 切回 STEP 后状态没清空"); errors = errors + 1;
	end
	#(600000);
	if (n_done != 1 || dut.r_angle_bcd !== 12'h000) begin
		$display("  [FAIL] 切回 STEP 600ms 内应在 0° 测一次（实际 %0d 次、角度 %h）", n_done, dut.r_angle_bcd);
		errors = errors + 1;
	end
	else
		$display("  [ok]   切回 STEP：500ms 后在 0° 测距，按 STEP 节奏继续");
	
	$display("");
	if (errors == 0)
		$display("==== ALL PASS ====");
	else
		$display("==== %0d ERROR(S) ====", errors);
	$finish;
end

endmodule
