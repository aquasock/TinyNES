# SPDX-License-Identifier: MIT
#
# Build rules for TinyNES AE350 runtime programs: C and C++ (exceptions and
# RTTI on) with newlib and libstdc++, linked to run from the SDRAM after the
# boot ROM loads them (tools/load_ae350.py). An app Makefile sets APP and
# SOURCES (.c, .cpp, .S, relative to its directory) and includes this file.
# LIB_SOURCES are third-party .c and .cpp files, built with ARCHFLAGS, OPT,
# CPPFLAGS and LIB_CPPFLAGS plus LIB_CFLAGS or LIB_CXXFLAGS in place of the
# TinyNES warning and language flags. EXTRA_OBJECTS are linked in as well.
#
#   make                  build $(BUILD)/$(APP).elf
#   make BUILD=<dir>      choose the output directory
#   make OPT=<flags>      optimise with <flags> in place of -O2

RT_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT      := $(abspath $(RT_DIR)/../..)
BUILD     ?= $(ROOT)/build/firmware/apps/$(APP)

RISCV_BIN ?= $(HOME)/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin
CROSS     ?= $(RISCV_BIN)/riscv-none-elf-
CC        := $(CROSS)gcc
CXX       := $(CROSS)g++
SIZE      := $(CROSS)size

OPT       ?= -O2
ARCHFLAGS := -march=rv32imac_zicsr_zifencei -mabi=ilp32
CPPFLAGS  += -I$(RT_DIR)/include -I$(ROOT)/firmware/include -I$(ROOT)/firmware/common -MMD -MP
COMMON    := $(ARCHFLAGS) $(OPT) -g -ffunction-sections -fdata-sections \
             -Wall -Wextra -Werror
CFLAGS    += $(COMMON) -std=gnu11
CXXFLAGS  += $(COMMON) -std=gnu++20
ASFLAGS   += $(ARCHFLAGS) -g

# No default start files or libgloss: crt0 and syscalls.c stand in for them,
# crtbegin and crtend frame .eh_frame and .init_array for the unwinder.
crtfile    = $(shell $(CC) $(ARCHFLAGS) -print-file-name=$(1))
LDFLAGS   += $(ARCHFLAGS) -nostdlib -static -T $(RT_DIR)/link.ld \
             -Wl,--gc-sections -Wl,--orphan-handling=error \
             -Wl,--no-warn-rwx-segments \
             -Wl,-Map,$(BUILD)/$(APP).map
LDLIBS    += -Wl,--start-group -lstdc++ -lsupc++ -lm -lc -lgcc -Wl,--end-group

RT_SOURCES := $(RT_DIR)/crt0.S $(RT_DIR)/syscalls.c $(ROOT)/firmware/common/uart.c
objects     = $(patsubst %,$(BUILD)/obj/%.o,$(subst /,_,$(1)))
RT_OBJECTS := $(call objects,$(notdir $(RT_SOURCES)))
APP_OBJECTS := $(call objects,$(SOURCES))
lib_object  = $(patsubst $(ROOT)/%,$(BUILD)/lib/%.o,$(abspath $(1)))
LIB_OBJECTS := $(foreach s,$(LIB_SOURCES),$(call lib_object,$(s)))
LIB_COMMON  := $(ARCHFLAGS) $(OPT) -g -ffunction-sections -fdata-sections

all: $(BUILD)/$(APP).elf

$(BUILD)/$(APP).elf: $(RT_OBJECTS) $(APP_OBJECTS) $(LIB_OBJECTS) \
		$(EXTRA_OBJECTS) $(RT_DIR)/link.ld
	$(CXX) $(LDFLAGS) -o $@ $(call crtfile,crti.o) $(RT_OBJECTS) \
	    $(call crtfile,crtbegin.o) $(APP_OBJECTS) $(LIB_OBJECTS) \
	    $(EXTRA_OBJECTS) $(LDLIBS) \
	    $(call crtfile,crtend.o) $(call crtfile,crtn.o)
	$(SIZE) $@

define compile
$(call objects,$(1)): $(2) $(MAKEFILE_LIST)
	@mkdir -p $$(dir $$@)
	$$(if $$(filter %.cpp,$(2)),$$(CXX) $$(CPPFLAGS) $$(CXXFLAGS),$$(if $$(filter %.S,$(2)),$$(CC) $$(CPPFLAGS) $$(ASFLAGS),$$(CC) $$(CPPFLAGS) $$(CFLAGS))) -c -o $$@ $(2)
endef
$(foreach s,$(RT_SOURCES),$(eval $(call compile,$(notdir $(s)),$(s))))
$(foreach s,$(SOURCES),$(eval $(call compile,$(s),$(s))))

define compile_lib
$(call lib_object,$(1)): $(1) $(MAKEFILE_LIST)
	@mkdir -p $$(dir $$@)
	$$(if $$(filter %.cpp,$(1)),$$(CXX) $$(CPPFLAGS) $$(LIB_CPPFLAGS) $$(LIB_COMMON) $$(LIB_CXXFLAGS),$$(CC) $$(CPPFLAGS) $$(LIB_CPPFLAGS) $$(LIB_COMMON) $$(LIB_CFLAGS)) -c -o $$@ $(1)
endef
$(foreach s,$(LIB_SOURCES),$(eval $(call compile_lib,$(s))))

clean:
	rm -rf $(BUILD)

-include $(wildcard $(BUILD)/obj/*.d) $(LIB_OBJECTS:.o=.d)

.PHONY: all clean
