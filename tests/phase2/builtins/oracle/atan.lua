local function t(x) return x, math.type(x), string.format("%.17g", x) end
for _, v in ipairs({1, 0}) do print(t(math.atan(v))) end
