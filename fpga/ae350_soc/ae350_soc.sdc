create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
# HDMI 720p: 371.25 MHz serial clock and the 74.25 MHz pixel clock from its
# divider (synthesis renames the divider's output net, so its pin is named).
create_clock -name pix_clk5 -period 2.694 [get_nets {pix_clk5}]
create_clock -name pix_clk -period 13.468 [get_pins {pix_div/CLKOUT}]
