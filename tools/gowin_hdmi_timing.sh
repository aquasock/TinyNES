#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Measurement only, never the project's build: builds fpga/ae350_soc with
# Gowin EDA, headless (core-reference TOOL-021), to read the vendor's static
# timing of the HDMI output stage, which the open flow does not time
# (TOOL-023). Gowin's analysis uses its slow model (hot, low voltage, slow
# silicon) for setup and its fast model (cold) for hold, so one run reports
# both ends of the commercial range.
#
#   tools/gowin_hdmi_timing.sh [out-dir]      default build/gowin_hdmi
#
# The sources, the boot ROM image and the desk font are staged with absolute
# paths; the constraints are the project's .cst with Gowin's clock
# definitions. The reports land in <out-dir>/impl/pnr/.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="${1:-$root/build/gowin_hdmi}"
gowin="${GOWINHOME:-$HOME/tools/gowin-1.9.11.03}"
src="$root/fpga/ae350_soc"

[[ -x "$gowin/IDE/bin/gw_sh" ]] || { echo "missing Gowin EDA: $gowin" >&2; exit 2; }
make -s -C "$root/firmware/boot"
rm -rf "$out"
mkdir -p "$out/src"
for f in "$src"/*.sv; do
    sed -e "s#\"build/firmware/boot/boot.hex\"#\"$root/build/firmware/boot/boot.hex\"#" \
        -e "s#\"fpga/ae350_soc/desk_font.hex\"#\"$src/desk_font.hex\"#" \
        "$f" >"$out/src/$(basename "$f")"
done
cp "$src/ae350_soc.cst" "$out/src/ae350_soc.cst"

# Every clock from the 50 MHz input, so that the PLLs' relations are known:
# 50 * 15 / 10 = 75 MHz bus, 50 * 15 = 750 MHz core, 50 * 27 / 50 = 27 MHz,
# 27 * 55 / 4 = 371.25 MHz serial, / 5 = 74.25 MHz pixel. The pixel and bus
# domains only meet through synchronisers and handshakes.
cat >"$out/src/ae350_soc.sdc" <<'EOF'
create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
create_generated_clock -name bus_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 3 -divide_by 2 [get_pins {cpu_pll/CLKOUT0}]
create_generated_clock -name core_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 15 [get_pins {cpu_pll/CLKOUT1}]
create_generated_clock -name clk27 -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 27 -divide_by 50 [get_pins {hdmi_pll27/CLKOUT0}]
create_generated_clock -name pix_clk5 -source [get_pins {hdmi_pll27/CLKOUT0}] -master_clock clk27 -multiply_by 55 -divide_by 4 [get_pins {hdmi_pll/CLKOUT0}]
create_generated_clock -name pix_clk -source [get_pins {hdmi_pll/CLKOUT0}] -master_clock pix_clk5 -divide_by 5 [get_pins {pix_div/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk bus_clk core_clk}] -group [get_clocks {clk27 pix_clk5 pix_clk}]
report_timing -setup -to_clock [get_clocks {pix_clk}] -max_paths 200
report_timing -hold -to_clock [get_clocks {pix_clk}] -max_paths 200
report_timing -setup -to_clock [get_clocks {pix_clk5}] -max_paths 50
report_timing -hold -to_clock [get_clocks {pix_clk5}] -max_paths 50
EOF

cat >"$out/build.tcl" <<EOF
set_device GW5AST-LV138PG484AC1/I0 -device_version C
foreach f [glob $out/src/*.sv] { add_file -type verilog \$f }
add_file -type cst $out/src/ae350_soc.cst
add_file -type sdc $out/src/ae350_soc.sdc
set_option -synthesis_tool gowinsynthesis
set_option -top_module ae350_soc_top
set_option -output_base_name ae350_soc
set_option -verilog_std sysv2017
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -gen_text_timing_rpt 1
run all
EOF

cd "$out"
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfreetype.so.6 QT_QPA_PLATFORM=offscreen \
    "$gowin/IDE/bin/gw_sh" build.tcl >build.log 2>&1 || { tail -40 build.log >&2; exit 1; }
ls impl/pnr/
