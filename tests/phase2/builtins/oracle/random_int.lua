local function t(x) return x, math.type(x) end
math.randomseed(7)
print(t(math.random(5, 5)))
print(t(math.random(9007199254740993, 9007199254740993)))
print(pcall(math.random, 1.5, 3))
print(t(math.random(2.0, 2.0)))
