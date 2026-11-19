import pytest

from radar_viz.parser import LineAssembler, Measurement, ParseError, band_of, format_line, parse_line


def test_parse_normal():
    assert parse_line("A=045 D=0623 L=1\r\n") == Measurement(45, 623, 1)
    assert parse_line("A=180 D=0150 L=4") == Measurement(180, 150, 4)


def test_parse_out_of_range():
    assert parse_line("A=090 D=---- L=0\r\n") == Measurement(90, None, 0)


@pytest.mark.parametrize("dist,level", [
    (0, 4), (199, 4), (200, 3), (399, 3), (400, 2), (599, 2),
    (600, 1), (799, 1), (800, 0), (3999, 0), (None, 0),
])
def test_band_boundaries(dist, level):
    assert band_of(dist) == level


@pytest.mark.parametrize("line", [
    "A=045 D=0000 L=7",         # 切换撞上发送：后半截是清零值
    "A=045 D=0623 L=2",         # 分级与距离不符
    "A=181 D=0623 L=1",         # 角度超范围
    "A=047 D=0623 L=1",         # 奇数角只能是 45/135
    "A=045 D=4000 L=0",         # 距离超范围
    "A=45 D=623 L=1",           # 不是定长格式
    "A=045 D=0623 L=1 junk",
    "",
    "��",
])
def test_parse_rejects(line):
    with pytest.raises(ParseError):
        parse_line(line)


def test_format_roundtrip():
    for m in [Measurement(0, 20, 4), Measurement(135, None, 0), Measurement(178, 3999, 0)]:
        line = format_line(m)
        assert len(line) == 18
        assert parse_line(line) == m


def test_assembler_split_chunks():
    asm = LineAssembler()
    assert asm.feed(b"A=045 D=06") == []
    assert asm.feed(b"23 L=1\r\nA=090 D=") == ["A=045 D=0623 L=1"]
    assert asm.feed(b"---- L=0\r\n") == ["A=090 D=---- L=0"]


def test_assembler_garbage():
    asm = LineAssembler(max_len=64)
    out = asm.feed(bytes([0xFF]) * 100)
    assert len(out) == 1 and "�" in out[0]
    assert asm.feed(b"A=000 D=0500 L=2\r\n") == ["A=000 D=0500 L=2"]
