local function t(x) return x, math.type(x), string.format("%.17g", x) end
print(t(2 ^ 10))
print(t(2 ^ 0.5))
