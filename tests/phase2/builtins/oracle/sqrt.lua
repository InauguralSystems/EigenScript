local function t(x) return x, math.type(x), string.format("%.17g", x) end
print(t(math.sqrt(4)))
print(t(math.sqrt(2)))
