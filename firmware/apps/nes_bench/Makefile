# SPDX-License-Identifier: MIT
#
# Headless Nestopia benchmark. Needs the core, fetched by
# tools/fetch_nestopia.sh, and a cartridge image, which is built in:
#
#   make ROM=<file.nes>         AE350 program, build/firmware/apps/nes_bench/
#   make ROM=<file.nes> host    the same program for this PC, in host/ there
#
# FRAMES=<n> and INPUT="<script>" replace the defaults in main.cpp. The
# programs contain Nestopia and are GPL-2.0 (third_party/nestopia/COPYING);
# with the cartridge image built in they are for local use only.

APP     := nes_bench
SOURCES := main.cpp rom.S

NST_DIR := $(abspath ../../../third_party/nestopia)
ifeq ($(wildcard $(NST_DIR)/libretro/Makefile.common),)
$(error Nestopia not found in $(NST_DIR): run tools/fetch_nestopia.sh)
endif
CORE_DIR := $(NST_DIR)
include $(NST_DIR)/libretro/Makefile.common

# Upstream's flags for a GCC build (libretro/Makefile), with gnu++11 in
# place of c++98; both build.
LIB_SOURCES  := $(SOURCES_CXX) $(SOURCES_C)
LIB_CPPFLAGS := -D__LIBRETRO__ -DNST_NO_ZLIB -DNDEBUG $(INCFLAGS)
LIB_CFLAGS   := -std=gnu99
LIB_CXXFLAGS := -std=gnu++11 -fno-rtti

APP_DEFS := $(if $(FRAMES),-DNES_FRAMES=$(FRAMES)) \
            $(if $(INPUT),-DNES_INPUT='"$(INPUT)"')
CPPFLAGS += -I$(LIBRETRO_COMM_DIR)/include $(APP_DEFS)

include ../../rt/rt.mk

ASFLAGS += -DNES_ROM_FILE='"$(BUILD)/rom.nes"'
$(call objects,rom.S): $(BUILD)/rom.nes

# Copied so that the image path may hold spaces, and only when it changes.
$(BUILD)/rom.nes: FORCE
	@test -n "$(ROM)" || { echo "set ROM=<file.nes>" >&2; exit 1; }
	@mkdir -p $(dir $@)
	@cmp -s "$(ROM)" $@ || cp "$(ROM)" $@

# The PC build: the same sources with the host compiler.
HOST     := $(BUILD)/host
HOST_CC  ?= gcc
HOST_CXX ?= g++
host_object = $(patsubst $(ROOT)/%,$(HOST)/obj/%.o,$(abspath $(1)))
HOST_LIB_OBJECTS := $(foreach s,$(LIB_SOURCES),$(call host_object,$(s)))
HOST_APP_OBJECTS := $(foreach s,$(SOURCES),$(call host_object,$(s)))

host: $(HOST)/$(APP)

$(HOST)/$(APP): $(HOST_APP_OBJECTS) $(HOST_LIB_OBJECTS)
	$(HOST_CXX) -o $@ $^

define host_compile
$(call host_object,$(1)): $(1) $(MAKEFILE_LIST)
	@mkdir -p $$(dir $$@)
	$(2) -c -o $$@ $(1)
endef
$(foreach s,$(filter %.cpp,$(LIB_SOURCES)),$(eval $(call host_compile,$(s),$$(HOST_CXX) -MMD -MP $$(LIB_CPPFLAGS) -O2 $$(LIB_CXXFLAGS))))
$(foreach s,$(filter %.c,$(LIB_SOURCES)),$(eval $(call host_compile,$(s),$$(HOST_CC) -MMD -MP $$(LIB_CPPFLAGS) -O2 $$(LIB_CFLAGS))))
$(eval $(call host_compile,main.cpp,$$(HOST_CXX) -MMD -MP $$(CPPFLAGS) -O2 -std=gnu++20 -Wall -Wextra -Werror))
$(eval $(call host_compile,rom.S,$$(HOST_CC) $$(APP_DEFS) -DNES_ROM_FILE='"$$(BUILD)/rom.nes"'))
$(call host_object,rom.S): $(BUILD)/rom.nes

-include $(HOST_LIB_OBJECTS:.o=.d) $(HOST_APP_OBJECTS:.o=.d)

.PHONY: host FORCE
