-- char_at of [s, i] is 0-based; Lua string.sub(s, i + 1, i + 1)
print(string.sub("hello", 2, 2))
print(pcall(string.sub, "hello", 2.5, 2.5))
print(string.sub("hello", 2.0, 2.0), string.sub("hello", -1, -1))
