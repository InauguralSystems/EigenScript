local function t(x) return x, math.type(x) end
print(t(1 << 63))
print(1 << 64, 8 << -1)
print(pcall(function() return 1 << 1.5 end))
print(t(1.0 << 4.0))
