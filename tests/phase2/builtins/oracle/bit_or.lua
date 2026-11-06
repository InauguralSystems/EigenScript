local function t(x) return x, math.type(x) end
print(t(9007199254740992 | 1))
print(pcall(function() return 1.5 | 1 end))
print(t(4.0 | 1.0))
