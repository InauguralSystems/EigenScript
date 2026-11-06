local function t(x) return x, math.type(x) end
print(t(math.max(9007199254740993, 9007199254740992)))
print(t(math.max(3, 2.5)))
print(t(math.max(2, 2.5)))
print(t(math.max(7)))
print(t(math.max(3, 3.0)))
print(t(math.max(3.0, 3)))
