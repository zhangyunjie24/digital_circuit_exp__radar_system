// seg_decoder —— 七段译码（沿用 exp2/seg_decoder.v 的段码表，去掉其中写死的 cat）
// seg[6:0] 高有效（1=点亮），位序为 seg[6]=a … seg[0]=g
// 扩充两个符号码：A = 横线"-"（只亮 g 段），F = 空白（全灭）
// 不含小数点：DP(PIN_51) 不在本总线里，留给舵机信号复用
//
// 【注意】母目录里存在两套段码表，不能混用：
//   exp2/exp3/exp4：7 位表（"0"=7'b111_1110），配 .qsf 里 PIN_52→seg[0] … PIN_62→seg[6]
//   exp5/seg.v    ：8 位标准表（"0"=8'h3F，seg[0]=a、seg[7]=dp），配 PIN_62→seg[0] … PIN_51→seg[7]
// 两套各自和自己的引脚顺序配套，落到物理引脚上结果一致（都是 PIN_52 灭、其余亮）。
// 本工程用的是前者（modules.md 第2节的引脚表就是 exp2 顺序），
// 好处是 seg 只有 7 位、PIN_51 天然不在总线里，不必额外屏蔽小数点。
module seg_decoder(
	input [3:0] a,
	output reg [6:0] seg
);

always@(*) begin
	case(a)
		4'h0: seg = 7'b111_1110;
		4'h1: seg = 7'b011_0000;
		4'h2: seg = 7'b110_1101;
		4'h3: seg = 7'b111_1001;
		4'h4: seg = 7'b011_0011;
		4'h5: seg = 7'b101_1011;
		4'h6: seg = 7'b101_1111;
		4'h7: seg = 7'b111_0000;
		4'h8: seg = 7'b111_1111;
		4'h9: seg = 7'b111_1011;
		4'hA: seg = 7'b000_0001;	// "-"
		default: seg = 7'b000_0000;	// F 及其余：空白
	endcase
end

endmodule
