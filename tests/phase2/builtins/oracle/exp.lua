local function t(x) return x, math.type(x), string.format("%.17g", x) end
print(t(math.exp(0)))
print(t(math.exp(1)))
