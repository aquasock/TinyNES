# SPDX-License-Identifier: MIT
# Four Wii Classic Controller inputs on PMOD0. Load after the ae350_soc
# image is in the FPGA:
#   tools/load_ae350.py build/firmware/apps/pad_test/pad_test.elf

APP     := pad_test
SOURCES := main.c
PAD_QUARTER ?= 187
CPPFLAGS += -DPAD_QUARTER=$(PAD_QUARTER)

include ../../rt/rt.mk
