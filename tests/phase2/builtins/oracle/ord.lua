local function t(x) return x, math.type(x) end
print(t(string.byte("A")))
print(select("#", string.byte("")))
