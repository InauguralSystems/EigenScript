local function t(x) return x, math.type(x) end
print(t(~9007199254740992))
print(pcall(function() return ~1.5 end))
print(t(~0.0))
