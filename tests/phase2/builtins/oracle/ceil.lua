local function t(x) return x, math.type(x) end
print(t(math.ceil(9007199254740993)))
print(t(math.ceil(-2.5)))
print(t(math.ceil(1e300)))
