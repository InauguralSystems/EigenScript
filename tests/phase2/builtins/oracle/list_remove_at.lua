-- list_remove_at of [xs, i] is 0-based; Lua table.remove(t, i + 1)
local t = {1, 2, 3, 4}
table.remove(t, 2); print(table.concat(t, ","))
print(pcall(table.remove, t, 1.5))
table.remove(t, 1.0); print(table.concat(t, ","))
