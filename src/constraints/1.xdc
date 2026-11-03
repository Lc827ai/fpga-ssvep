# ==============================================================================
# PYNQ-Z2 SSVEP系统约束文件
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. BTN0
# ------------------------------------------------------------------------------
set_property -dict {
    PACKAGE_PIN D19
    IOSTANDARD LVCMOS33
} [get_ports {btn_start}]


# ------------------------------------------------------------------------------
# 2. HDMI TX
# ------------------------------------------------------------------------------

# HDMI Clock
set_property -dict {
    PACKAGE_PIN L16
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_clk_p}]

set_property -dict {
    PACKAGE_PIN L17
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_clk_n}]

# HDMI Data 0
set_property -dict {
    PACKAGE_PIN K17
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_data_p[0]}]

set_property -dict {
    PACKAGE_PIN K18
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_data_n[0]}]

# HDMI Data 1
set_property -dict {
    PACKAGE_PIN K19
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_data_p[1]}]

set_property -dict {
    PACKAGE_PIN J19
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_data_n[1]}]

# HDMI Data 2
set_property -dict {
    PACKAGE_PIN J18
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_data_p[2]}]

set_property -dict {
    PACKAGE_PIN H18
    IOSTANDARD TMDS_33
} [get_ports {hdmi_tx_data_n[2]}]

