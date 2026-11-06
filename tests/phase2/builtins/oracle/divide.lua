local function t(x) return x, math.type(x), string.format("%.17g", x) end
print(t(7 / 2))
print(t(6 / 3))
