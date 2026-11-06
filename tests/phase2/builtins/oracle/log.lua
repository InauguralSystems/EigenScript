local function t(x) return x, math.type(x), string.format("%.17g", x) end
print(t(math.log(1)))
print(t(math.log(8)))
