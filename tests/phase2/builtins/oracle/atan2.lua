local function t(x) return x, math.type(x), string.format("%.17g", x) end
print(t(math.atan(1, 1)))
print(t(math.atan(0, -1)))
