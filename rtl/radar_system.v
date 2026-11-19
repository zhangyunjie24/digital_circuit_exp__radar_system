// radar_system —— 简易雷达报警系统 顶层
//
// 子模块：timebase / sys_fsm / key_debounce / scan_engine / servo_pwm / ultrasonic / angle_bcd
//         dist_band / result_reg / disp_ctrl / seg_scan / matrix_driver / matrix_ctrl / dir_mem
//         alarm_ctrl / buzzer_ctrl / lcd_ctrl / report_ctrl / uart_tx
//         （report_ctrl + uart_tx：每次测距发一行测量结果，9600bps 8N1，TX1 = PIN_85）
//
// 设计约定见 docs/modules.md：单一时钟域（clk=1MHz），rst = ~sw7 高有效异步复位
module radar_system(
	input clk,					// PIN_18，1MHz
	input sw7,					// 系统总开关，rst = ~sw7
	input btn_mode,				// SCAN_STEP <-> SCAN_CONT 切换键
	input echo,					// HC-SR04 回波
	
	output trig,				// HC-SR04 触发
	output servo,				// 舵机 PWM（与 DISP7 小数点共用 PIN_51）
	output [6:0] seg,			// 数码管段码，高有效（不含小数点）
	output [7:0] cat,			// 数码管位选，低有效
	output [15:0] ld,			// 16 个 LED
	output [7:0] row,			// 点阵行选，低有效
	output [15:0] row_color,	// 点阵列数据（红/绿两通道）
	output buzzer,				// 蜂鸣器
	
	// LCD12864（ST7565R，8080 并口）
	output [7:0] lcd_d,
	output lcd_cs_n,
	output lcd_a0,				// 0=命令 1=数据
	output lcd_wr_n,
	output lcd_rd_n,
	output lcd_rst_n,

	output uart_tx_pin			// 串口发送（9600bps 8N1）
);

wire rst = ~sw7;

// ============ 时基 ============
wire tick_1ms;
wire blink_2hz;
wire tone_2k;
wire blink_1hz;
wire beat_100ms;
timebase timebase_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.tone_2k(tone_2k),
	.blink_2hz(blink_2hz),
	.blink_1hz(blink_1hz),
	.beat_100ms(beat_100ms)
);

// ============ 按键消抖 ============
// 原先复用 exp7 的 8 路 key_filter（40 LE），加上 LCD 后放不下，换成单路的 key_debounce
wire btn_pulse;
key_debounce key_debounce_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.key(btn_mode),
	.pulse(btn_pulse)
);

// ============ 顶层状态机 ============
wire [1:0] phase;
wire phase_tick;
wire mode_cont;
wire restart;
sys_fsm sys_fsm_1(
	.clk(clk),
	.rst(rst),
	.phase_tick(phase_tick),
	.btn_pulse(btn_pulse),
	.phase(phase),
	.mode_cont(mode_cont),
	.restart(restart)
);

// ============ 舵机与扫描节拍 ============
wire [11:0] pulse_us;
wire [7:0]  angle_deg;
wire [2:0]  cur_dir;		// 当前角度就近取整得到的方向
wire        meas_start;		// 触发 ultrasonic 测一次
wire        us_oor;			// ultrasonic 超量程（scan_engine 据此在 STEP 下重测一次）

scan_engine scan_engine_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.scan_en(phase == 2'd2),
	.mode_cont(mode_cont),
	.restart(restart),
	.meas_oor(us_oor),
	.pulse_us(pulse_us),
	.angle_deg(angle_deg),
	.dir_idx(cur_dir),
	.meas_start(meas_start),
	.phase_tick(phase_tick)
);

servo_pwm servo_pwm_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.en(phase != 2'd0),		// 自检阶段不发 PWM，舵机不动
	.pulse_us(pulse_us),
	.servo(servo)
);

// ============ 超声波测距 ============
// 进入 SCAN 前、以及按键切换模式时清空扫描相关状态（result_reg / dir_mem / 进行中的测量）
wire        scan_clear = restart || (phase != 2'd2);
wire        us_done;
wire [15:0] us_mm_bcd;
ultrasonic ultrasonic_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.start(meas_start),
	.abort(scan_clear),			// 切换模式时中止测到一半的旧测量
	.echo(echo),
	.trig(trig),
	.done(us_done),
	.mm_bcd(us_mm_bcd),
	.oor(us_oor)
);

// 角度 → BCD，供数码管显示
wire [11:0] angle_bcd_w;
angle_bcd angle_bcd_1(
	.angle_deg(angle_deg),
	.bcd(angle_bcd_w)
);

// ============ 距离分级 + 结果锁存 ============
// 一次测距的数据流：scan_engine 发 meas_start → ultrasonic 测完发 us_done →
// result_reg 同一拍锁存角度/距离/分级，dir_mem 同一拍写入该方向颜色
wire [2:0] us_band;
dist_band dist_band_1(
	.mm_bcd(us_mm_bcd),
	.oor(us_oor),
	.band(us_band)
);

wire [11:0] r_angle_bcd;
wire [15:0] r_dist_bcd;
wire        r_valid;
wire        r_oor;
wire [2:0]  r_band;
wire        r_strobe;

result_reg result_reg_1(
	.clk(clk),
	.rst(rst),
	.clear(scan_clear),
	.done(us_done),
	.angle_bcd(angle_bcd_w),
	.mm_bcd(us_mm_bcd),
	.oor(us_oor),
	.band(us_band),
	.r_angle_bcd(r_angle_bcd),
	.r_dist_bcd(r_dist_bcd),
	.r_valid(r_valid),
	.r_oor(r_oor),
	.r_band(r_band),
	.r_strobe(r_strobe)
);

// ============ 数码管 ============
wire [31:0] digits;
disp_ctrl disp_ctrl_1(
	.phase(phase),
	.blink_2hz(blink_2hz),
	.r_angle_bcd(r_angle_bcd),
	.r_dist_bcd(r_dist_bcd),
	.r_valid(r_valid),
	.r_oor(r_oor),
	.digits(digits)
);

seg_scan seg_scan_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.digits(digits),
	.seg(seg),
	.cat(cat)
);

// ============ LCD 雷达图 ============
lcd_ctrl lcd_ctrl_1(
	.clk(clk),
	.rst(rst),
	.tick_1ms(tick_1ms),
	.blink_2hz(blink_2hz),
	.phase(phase),
	.mode_cont(mode_cont),
	.restart(restart),
	.r_strobe(r_strobe),
	.r_angle_bcd(r_angle_bcd),
	.r_dist_bcd(r_dist_bcd),
	.r_valid(r_valid),
	.r_oor(r_oor),
	.angle_deg(angle_deg),
	.lcd_d(lcd_d),
	.lcd_cs_n(lcd_cs_n),
	.lcd_a0(lcd_a0),
	.lcd_wr_n(lcd_wr_n),
	.lcd_rd_n(lcd_rd_n),
	.lcd_rst_n(lcd_rst_n)
);

// ============ 串口汇报 ============
wire [7:0] uart_data;
wire       uart_send;
wire       uart_busy;
report_ctrl report_ctrl_1(
	.clk(clk),
	.rst(rst),
	.r_strobe(r_strobe),
	.r_angle_bcd(r_angle_bcd),
	.r_dist_bcd(r_dist_bcd),
	.r_oor(r_oor),
	.r_band(r_band),
	.uart_data(uart_data),
	.uart_send(uart_send),
	.uart_busy(uart_busy)
);

uart_tx uart_tx_1(
	.clk(clk),
	.rst(rst),
	.data(uart_data),
	.send(uart_send),
	.busy(uart_busy),
	.tx(uart_tx_pin)
);

// ============ 点阵 ============
// 5 个方向的颜色：初始为"灭"，被扫到并测出距离后才亮起；SCAN 以外的阶段和模式切换时清空
wire [14:0] colors;

dir_mem dir_mem_1(
	.clk(clk),
	.rst(rst),
	.clear(scan_clear),
	.wr_en(us_done),
	.wr_idx(cur_dir),				// done 时舵机仍在本档，cur_dir 就是测的方向
	.wr_color(us_band + 3'd1),		// 颜色码 = band + 1
	.colors(colors)
);

wire [2:0]  row_idx;
wire [7:0]  col_on;
wire [8:0]  grp_color;

matrix_ctrl matrix_ctrl_1(
	.phase(phase),
	.blink_2hz(blink_2hz),
	.cur_dir(cur_dir),
	.colors(colors),
	.row_idx(row_idx),
	.col_on(col_on),
	.grp_color(grp_color)
);

matrix_driver matrix_driver_1(
	.clk(clk),
	.rst(rst),
	.col_on(col_on),
	.grp_color(grp_color),
	.row_idx(row_idx),
	.row(row),
	.row_color(row_color)
);

// ============ 声光报警 ============
alarm_ctrl alarm_ctrl_1(
	.rst(rst),
	.phase(phase),
	.blink_2hz(blink_2hz),
	.r_band(r_band),
	.ld(ld)
);

buzzer_ctrl buzzer_ctrl_1(
	.clk(clk),
	.rst(rst),
	.tone_2k(tone_2k),
	.beat_100ms(beat_100ms),
	.blink_2hz(blink_2hz),
	.blink_1hz(blink_1hz),
	.phase(phase),
	.r_band(r_band),
	.buzzer(buzzer)
);

endmodule
