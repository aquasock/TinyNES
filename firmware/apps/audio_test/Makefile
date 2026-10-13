# SPDX-License-Identifier: MIT
# 1 kHz left and 2 kHz right through the Pmod I2S2 on PMOD1. Load after the
# ae350_soc image is in the FPGA:
#   tools/load_ae350.py --tinytang build/firmware/apps/audio_test/audio_test.elf

APP     := audio_test
SOURCES := main.c
TEST_SECONDS ?= 5
CPPFLAGS += -DTEST_SECONDS=$(TEST_SECONDS)u

include ../../rt/rt.mk
