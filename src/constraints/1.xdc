# ==============================================================================
# PYNQ-Z2 物理管脚约束文件 (SSVEP BCI 系统)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 物理按键 (Button)
# ------------------------------------------------------------------------------
# 将 btn_start 绑定到 PYNQ-Z2 的 BTN0
set_property -dict { PACKAGE_PIN D19   IOSTANDARD LVCMOS33 } [get_ports { btn_start }];


# ------------------------------------------------------------------------------
# 2. HDMI TX 输出接口 (连接到 rgb2dvi IP 的 TMDS 外部端口)
# ------------------------------------------------------------------------------
# HDMI 时钟通道 (Clock)
set_property -dict { PACKAGE_PIN L16   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_p }];
set_property -dict { PACKAGE_PIN L17   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_n }];

# HDMI 数据通道 0 (Data 0)
set_property -dict { PACKAGE_PIN K17   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_p[0] }];
set_property -dict { PACKAGE_PIN K18   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_n[0] }];

# HDMI 数据通道 1 (Data 1)
set_property -dict { PACKAGE_PIN K19   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_p[1] }];
set_property -dict { PACKAGE_PIN J19   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_n[1] }];

# HDMI 数据通道 2 (Data 2)
set_property -dict { PACKAGE_PIN J18   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_p[2] }];
set_property -dict { PACKAGE_PIN H18   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_data_n[2] }];