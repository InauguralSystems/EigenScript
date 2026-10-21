local function t(x) return x, math.type(x) end
print(t(-1 >> 1))
print(1 >> 64, 1 >> -1)
print(pcall(function() return 16 >> 1.5 end))
print(t(16.0 >> 2.0))
