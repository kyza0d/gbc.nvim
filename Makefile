CC ?= cc
DEBUG ?= 0

HOST_CFLAGS := -std=c99 -Wall -Wextra -Wpedantic
SAMEBOY_CFLAGS := -std=gnu11 -fPIC
ifeq ($(DEBUG),1)
HOST_CFLAGS += -g -O0
SAMEBOY_CFLAGS += -g -O0
else
HOST_CFLAGS += -O2
SAMEBOY_CFLAGS += -O2
endif

NATIVE_DIR := native
TARGET := $(NATIVE_DIR)/sameboy-host
SOURCES := $(NATIVE_DIR)/sameboy-host.c
SAMEBOY_DIR := $(NATIVE_DIR)/vendor/SameBoy
SAMEBOY_CORE_DIR := $(SAMEBOY_DIR)/Core
SAMEBOY_BUILD_DIR := $(NATIVE_DIR)/.build

include $(SAMEBOY_DIR)/version.mk

SAMEBOY_COPYRIGHT_YEAR := $(shell grep -oE '20[2-9][0-9]' $(SAMEBOY_DIR)/LICENSE | tail -n 1)
SAMEBOY_DEFS := -D_GNU_SOURCE \
	-DGB_VERSION='"$(VERSION)"' \
	-DGB_COPYRIGHT_YEAR='"$(SAMEBOY_COPYRIGHT_YEAR)"' \
	-DGB_DISABLE_DEBUGGER \
	-DGB_DISABLE_CHEATS \
	-DGB_DISABLE_CHEAT_SEARCH \
	-DGB_DISABLE_REWIND
SAMEBOY_INCLUDES := -I$(SAMEBOY_DIR) -I$(SAMEBOY_CORE_DIR)
SAMEBOY_DISABLED_SOURCES := \
	$(SAMEBOY_CORE_DIR)/debugger.c \
	$(SAMEBOY_CORE_DIR)/sm83_disassembler.c \
	$(SAMEBOY_CORE_DIR)/symbol_hash.c \
	$(SAMEBOY_CORE_DIR)/cheats.c \
	$(SAMEBOY_CORE_DIR)/cheat_search.c \
	$(SAMEBOY_CORE_DIR)/rewind.c
SAMEBOY_CORE_SOURCES := $(filter-out $(SAMEBOY_DISABLED_SOURCES),$(wildcard $(SAMEBOY_CORE_DIR)/*.c))
SAMEBOY_CORE_HEADERS := $(wildcard $(SAMEBOY_CORE_DIR)/*.h) $(wildcard $(SAMEBOY_CORE_DIR)/graphics/*.inc)
SAMEBOY_CORE_OBJECTS := $(patsubst $(SAMEBOY_DIR)/%.c,$(SAMEBOY_BUILD_DIR)/%.o,$(SAMEBOY_CORE_SOURCES))
HOST_OBJECT := $(SAMEBOY_BUILD_DIR)/sameboy-host.o

LDFLAGS += -lm -ldl

.PHONY: all clean sameboy-lib test

all: $(TARGET)

sameboy-lib: $(TARGET)

$(SAMEBOY_BUILD_DIR)/Core/%.o: $(SAMEBOY_CORE_DIR)/%.c $(SAMEBOY_CORE_HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(SAMEBOY_CFLAGS) $(SAMEBOY_DEFS) $(SAMEBOY_INCLUDES) -DGB_INTERNAL -c $< -o $@

$(HOST_OBJECT): $(SOURCES) $(NATIVE_DIR)/protocol.h $(SAMEBOY_CORE_HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(HOST_CFLAGS) $(SAMEBOY_DEFS) $(SAMEBOY_INCLUDES) -c $< -o $@

$(TARGET): $(HOST_OBJECT) $(SAMEBOY_CORE_OBJECTS)
	$(CC) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)
	rm -rf $(SAMEBOY_BUILD_DIR)

test:
	NVIM_LOG_FILE=/tmp/gbc.nvim-test.log nvim --headless --clean -u NONE -l tests/run.lua
