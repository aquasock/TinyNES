# SPDX-License-Identifier: MIT
#
# NES emulator benchmark: FCEUmm's emulation core, fetched by
# tools/fetch_fceumm.sh, driven by main.cpp in place of FCEUmm's libretro
# driver, with a cartridge image built in; on the AE350 it shows the game on
# HDMI.
#
#   make ROM=<file.nes>         AE350 program, build/firmware/apps/nes_bench/
#   make ROM=<file.nes> host    the same program for this PC, in host/ there
#
# FRAMES=<n> and INPUT="<script>" replace the defaults in main.cpp.
# PLAY=1 builds the playable version instead (AE350 only), with the Wii
# Classic Controllers as players 1 and 2, in build/firmware/apps/nes_play/.
# MCACHE=<mask> sets those mcache_ctl bits for the run (AE350 only), and
# OPT=<flags> replaces -O2 (rt.mk); give such builds their own BUILD=<dir>.
# The programs contain the core and are GPL-2.0 (third_party/fceumm/Copying);
# with the cartridge image built in they are for local use only.

APP     := nes_bench
SOURCES := main.cpp rom.S

FCEU_DIR := $(abspath ../../../third_party/fceumm)
ifeq ($(wildcard $(FCEU_DIR)/Makefile.common),)
$(error FCEUmm not found in $(FCEU_DIR): run tools/fetch_fceumm.sh)
endif
# Upstream's unix build (Makefile.libretro) without the NTSC filter and
# HD texture packs, and without its libretro driver, whose place main.cpp
# takes: the core's 8-bit picture is shown as it is, with no conversion.
CORE_DIR    := $(FCEU_DIR)/src
HAVE_NTSC   := 0
HAVE_HDPACK := 0
include $(FCEU_DIR)/Makefile.common

LIB_SOURCES  := $(filter-out $(CORE_DIR)/drivers/libretro/libretro.c \
                             $(CORE_DIR)/drivers/libretro/libretro_dipswitch.c,$(SOURCES_C))
LIB_CPPFLAGS := $(COREDEFINES) -DNDEBUG $(INCFLAGS)

ifeq ($(PLAY),1)
BUILD ?= $(abspath ../../../build/firmware/apps/nes_play)
endif
APP_DEFS := $(if $(filter 1,$(PLAY)),-DNES_PLAY) \
            $(if $(FRAMES),-DNES_FRAMES=$(FRAMES)) \
            $(if $(INPUT),-DNES_INPUT='"$(INPUT)"') \
            $(if $(MCACHE),-DNES_MCACHE=$(MCACHE))
CPPFLAGS += $(APP_DEFS)

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
$(foreach s,$(filter %.c,$(LIB_SOURCES)),$(eval $(call host_compile,$(s),$$(HOST_CC) -MMD -MP $$(LIB_CPPFLAGS) -O2 $$(LIB_CFLAGS))))
$(eval $(call host_compile,main.cpp,$$(HOST_CXX) -MMD -MP $$(CPPFLAGS) -O2 -std=gnu++20 -Wall -Wextra -Werror))
$(eval $(call host_compile,rom.S,$$(HOST_CC) $$(APP_DEFS) -DNES_ROM_FILE='"$$(BUILD)/rom.nes"'))
$(call host_object,rom.S): $(BUILD)/rom.nes

-include $(HOST_LIB_OBJECTS:.o=.d) $(HOST_APP_OBJECTS:.o=.d)

.PHONY: host FORCE
