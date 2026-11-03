# ============================================================
# SSVEP generator CDC constraints
# 当前文件作用于 system_SSVEP_Hardware_Gener_0_0 模块
# 仅切断异步信号到第一级同步寄存器的路径
# ============================================================

set_false_path -to [get_pins {inst/btn_sync1_reg/D}]

set_false_path -to [get_pins {inst/stim_en_sync1_reg/D}]

set_false_path -to [get_pins {inst/fb_sync1_reg[0]/D}]

set_false_path -to [get_pins {inst/fb_sync1_reg[1]/D}]