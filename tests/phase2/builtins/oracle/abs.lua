local function t(x) return x, math.type(x) end
print(t(math.abs(-9007199254740993)))
print(t(math.abs(-2.5)))
print(t(math.abs(math.mininteger)))
