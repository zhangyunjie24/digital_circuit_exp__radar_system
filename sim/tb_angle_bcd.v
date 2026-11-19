`timescale 1us/1ns
// tb_angle_bcd —— 穷举 0~180 全部角度，检查 double dabble 转换正确
module tb_angle_bcd;

reg [7:0] a;
wire [11:0] bcd;
angle_bcd dut(.angle_deg(a), .bcd(bcd));

integer i, errors;
integer h, t, o;
initial begin
	errors = 0;
	for (i = 0; i <= 180; i = i + 1) begin
		a = i[7:0];
		#1;
		h = i / 100;
		t = (i / 10) % 10;
		o = i % 10;
		if (bcd[11:8] !== h[3:0] || bcd[7:4] !== t[3:0] || bcd[3:0] !== o[3:0]) begin
			$display("  [FAIL] %0d -> %0d%0d%0d, expect %0d%0d%0d",
			         i, bcd[11:8], bcd[7:4], bcd[3:0], h, t, o);
			errors = errors + 1;
		end
	end
	if (errors == 0) $display("==== RESULT: PASS (0..180 all correct) ====");
	else             $display("==== RESULT: FAIL (%0d errors) ====", errors);
	$finish;
end
endmodule
