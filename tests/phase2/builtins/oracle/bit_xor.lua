local function t(x) return x, math.type(x) end
print(t(9007199254740993 ~ 1))
print(pcall(function() return 1.5 ~ 1 end))
print(t(6.0 ~ 3.0))
