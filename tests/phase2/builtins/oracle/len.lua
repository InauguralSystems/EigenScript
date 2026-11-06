local function t(x) return x, math.type(x) end
print(t(#{1, 2}))
print(t(#"hello"))
