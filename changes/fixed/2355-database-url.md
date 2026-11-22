- `db_connect` uses libpq to parse `DATABASE_URL` and connect with the parsed
parameters. Both connection URIs and keyword/value strings work without
truncation or changing the database name. A default `connect_timeout=3` is
added only when absent; parser failures return the error status with libpq's
message (#2355).
