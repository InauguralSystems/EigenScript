- `http_post` uses the curl library without starting a process, so request
  headers no longer appear in a curl command line or expose inherited server
  sockets to a child. (#2354)
