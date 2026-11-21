-- list_insert_at of [xs, i, v] is 0-based; Lua table.insert(t, i + 1, v)
local t = {1, 2, 3}
table.insert(t, 2, 9); print(table.concat(t, ","))
print(pcall(table.insert, t, 2.5, 8))
table.insert(t, 1.0, 7); print(table.concat(t, ","))
