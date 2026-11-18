- `http_post` sends every validated request header whole and in order, within
  the 65,536-byte limit, instead of truncating long values or dropping the 33rd
  and later headers. (#2358)
