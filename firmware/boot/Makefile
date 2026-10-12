# SPDX-License-Identifier: MIT
#
# TinyNES AE350 boot ROM program.
#
#   make                  build $(BUILD)/boot.hex
#   make BUILD=<dir>      choose the output directory
#
# boot.hex is the whole 32 KiB ROM, one 32-bit little-endian word per line in
# hex, padded with zeros, for $readmemh in fpga/ae350_soc/ahb_boot_rom.sv.

ROOT      := $(abspath ../..)
BUILD     ?= $(ROOT)/build/firmware/boot

RISCV_BIN ?= $(HOME)/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin
CROSS     ?= $(RISCV_BIN)/riscv-none-elf-
CC        := $(CROSS)gcc
OBJCOPY   := $(CROSS)objcopy
SIZE      := $(CROSS)size

ARCHFLAGS := -march=rv32imac_zicsr_zifencei -mabi=ilp32
CFLAGS    := $(ARCHFLAGS) -Os -g -std=gnu11 -ffreestanding -fno-builtin \
             -fno-tree-loop-distribute-patterns -ffunction-sections \
             -fdata-sections -Wall -Wextra -Werror -I../include -I../common
LDFLAGS   := -nostdlib -nostartfiles -T link.ld -Wl,--gc-sections \
             -Wl,-Map,$(BUILD)/boot.map

ROM_BYTES := 32768
SOURCES   := crt0.S main.c load.c ../common/memtest.c ../common/uart.c

all: $(BUILD)/boot.hex

$(BUILD)/boot.elf: $(SOURCES) load.h ../include/tinynes.h ../common/memtest.h \
                   ../common/uart.h link.ld Makefile
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) -lgcc
	$(SIZE) $@

$(BUILD)/boot.hex: $(BUILD)/boot.elf
	$(OBJCOPY) -O binary $< $(BUILD)/boot.bin
	test $$(stat -c %s $(BUILD)/boot.bin) -le $(ROM_BYTES)
	truncate -s $(ROM_BYTES) $(BUILD)/boot.bin
	od -An -v -tx4 -w4 $(BUILD)/boot.bin | tr -d ' ' > $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
