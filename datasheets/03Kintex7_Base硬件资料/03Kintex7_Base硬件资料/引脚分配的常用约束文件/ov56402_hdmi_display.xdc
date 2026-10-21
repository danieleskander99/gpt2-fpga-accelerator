set_property PACKAGE_PIN E22 [get_ports HDMI_OUT_EN1]
set_property IOSTANDARD LVCMOS33 [get_ports HDMI_OUT_EN1]

set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cmos_data2[0]}]


set_property IOSTANDARD LVCMOS33 [get_ports cmos_reset2]
set_property IOSTANDARD LVCMOS33 [get_ports cmos_scl2]
set_property IOSTANDARD LVCMOS33 [get_ports cmos_sda2]
set_property IOSTANDARD LVCMOS33 [get_ports rstn]
set_property PACKAGE_PIN D26 [get_ports rstn]

set_property PACKAGE_PIN A14 [get_ports cmos_reset2]
set_property PACKAGE_PIN C14 [get_ports cmos_scl2]
set_property PACKAGE_PIN B14 [get_ports cmos_sda2]

set_property PACKAGE_PIN A23 [get_ports cmos_conf_done2]
set_property IOSTANDARD LVCMOS33 [get_ports cmos_conf_done2]

set_property PACKAGE_PIN B12 [get_ports {cmos_data2[0]}]
set_property PACKAGE_PIN D9 [get_ports {cmos_data2[1]}]
set_property PACKAGE_PIN D10 [get_ports {cmos_data2[2]}]
set_property PACKAGE_PIN C13 [get_ports {cmos_data2[3]}]
set_property PACKAGE_PIN C12 [get_ports {cmos_data2[4]}]
set_property PACKAGE_PIN E12 [get_ports {cmos_data2[5]}]
set_property PACKAGE_PIN D14 [get_ports {cmos_data2[6]}]
set_property PACKAGE_PIN D13 [get_ports {cmos_data2[7]}]

set_property IOSTANDARD LVCMOS33 [get_ports cmos_href2]

set_property IOSTANDARD LVCMOS33 [get_ports cmos_pclk2]
set_property PACKAGE_PIN D11 [get_ports cmos_href2]

set_property PACKAGE_PIN B11 [get_ports cmos_pclk2]
set_property PACKAGE_PIN E10 [get_ports cmos_vsync2]
set_property IOSTANDARD LVCMOS33 [get_ports cmos_vsync2]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cmos_pclk2_IBUF]


set_property PACKAGE_PIN G22 [get_ports clk50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk50m]

set_property PACKAGE_PIN F17 [get_ports TMDS_CLK_P1]
set_property PACKAGE_PIN J15 [get_ports {TMDS_DATA_P1[0]}]
set_property PACKAGE_PIN E15 [get_ports {TMDS_DATA_P1[1]}]
set_property PACKAGE_PIN G17 [get_ports {TMDS_DATA_P1[2]}]

