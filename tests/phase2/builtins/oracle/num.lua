for _, s in ipairs({"3", "3.0", "9007199254740993", "9223372036854775808", " 12 ", "+5", "-0x10", "0x1F", "0X1f", "0xFFFFFFFFFFFFFFFF", ".5", "1.", "1e5", "12abc", "0b101", "0o17", "1_000", "", " ", "inf", "nan", "1.2.3", "0x", "0x1p4", "-9223372036854775808"}) do
  local v = tonumber(s)
  print(string.format("%q", s), v, math.type(v))
end
