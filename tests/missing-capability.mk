# Auxiliary link only: never relink the suite CLI. Owning variant is explicit.
include Makefile
COLD_VARIANT ?= release
COLD_BINARY := build/$(COLD_VARIANT)/test_missing_capability
$(COLD_BINARY): tests/test_missing_capability.c $(filter-out build/$(COLD_VARIANT)/main.o,$(OBJ_$(COLD_VARIANT)))
	$(CC) $(FLAGS_$(COLD_VARIANT)) -Isrc -o $@ $^ $(LIBS_$(COLD_VARIANT))
