local function t(x) return x, math.type(x), string.format("%.17g", x) end
for _, v in ipairs({0, 1}) do print(t(math.sin(v))) end
