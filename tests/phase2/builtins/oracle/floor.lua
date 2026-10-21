local function t(x) return x, math.type(x) end
print(t(math.floor(9007199254740993)))
print(t(math.floor(-2.5)))
print(t(math.floor(1e300)))
