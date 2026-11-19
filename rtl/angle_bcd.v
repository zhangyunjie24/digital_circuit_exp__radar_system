// angle_bcd —— 角度（0~180 二进制）→ 3 位 BCD，仅用于数码管显示（纯组合）
//
// 不能写成 r/10、r%10：Quartus 会各综合出一个完整的除法器，两个加起来 111 个逻辑单元。
// 改用 double dabble（移位加 3）：百位单独判断，余下 0~99 用 7 级移位转成两位 BCD。
module angle_bcd(
	input [7:0] angle_deg,
	output reg [11:0] bcd		// {百位, 十位, 个位}
);

integer i;
reg [7:0]  r;					// 去掉百位之后的余数 0~99
reg [14:0] sh;					// [14:11]=十位, [10:7]=个位, [6:0]=待转换的二进制

always@(*) begin
	if (angle_deg >= 8'd100) begin
		bcd[11:8] = 4'd1;
		r         = angle_deg - 8'd100;			// 100~180 → 0~80（必须整 8 位相减）
	end
	else begin
		bcd[11:8] = 4'd0;
		r         = angle_deg;					// 0~99
	end
	sh = {8'd0, r[6:0]};
	
	for (i = 0; i < 7; i = i + 1) begin
		if (sh[10:7]  >= 4'd5) sh[10:7]  = sh[10:7]  + 4'd3;
		if (sh[14:11] >= 4'd5) sh[14:11] = sh[14:11] + 4'd3;
		sh = sh << 1;
	end
	
	bcd[7:4] = sh[14:11];
	bcd[3:0] = sh[10:7];
end

endmodule
