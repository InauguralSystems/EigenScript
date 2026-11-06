local function t(x) return x, math.type(x) end
print(t(math.min(9007199254740993, 9007199254740994)))
print(t(math.min(3, 3.5)))
print(t(math.min(4, 3.5)))
print(t(math.min(7)))
print(t(math.min(3, 3.0)))
print(t(math.min(3.0, 3)))
