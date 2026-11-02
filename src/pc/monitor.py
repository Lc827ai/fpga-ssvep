import sys
import struct
import socket
import threading
import numpy as np
from PyQt5.QtWidgets import (QApplication, QMainWindow, QVBoxLayout, QHBoxLayout, 
                             QWidget, QLabel, QComboBox, QSplitter, QTextEdit, QFrame)
from PyQt5.QtCore import QTimer, Qt, pyqtSignal, QObject
from PyQt5.QtGui import QFont, QColor
import pyqtgraph as pg
import time

class SimpleDCBlocker:
    def __init__(self, alpha=0.995):
        self.alpha = alpha
        self.dc = 0.0
        self.initialized = False

    def process(self, val):
        if not self.initialized:
            self.dc = val
            self.initialized = True
        self.dc = self.dc * self.alpha + val * (1 - self.alpha)
        return val - self.dc

class IIRFilter:
    def __init__(self, b, a):
        self.b, self.a = b, a
        self.x = [0.0] * len(b)
        self.y = [0.0] * (len(a) - 1)

    def process_sample(self, input_val):
        if np.isnan(input_val) or np.isinf(input_val): input_val = 0.0
        for i in range(len(self.x) - 1, 0, -1): self.x[i] = self.x[i - 1]
        self.x[0] = input_val
        output = sum(self.b[i] * self.x[i] for i in range(len(self.b)))
        output -= sum(self.a[i + 1] * self.y[i] for i in range(len(self.y)))
        output /= self.a[0]
        if np.isnan(output) or np.isinf(output):
            output = 0.0
            self.y = [0.0] * len(self.y) 
        for i in range(len(self.y) - 1, 0, -1): self.y[i] = self.y[i - 1]
        self.y[0] = output
        return output

class EegFilter500Hz:
    def __init__(self):
        self.dc_blocker = SimpleDCBlocker(alpha=0.98)
        self.filters = [
            IIRFilter([0.991824212, -3.967296848, 5.950945272, -3.967296848, 0.991824212], [1, -3.983581258, 5.950878429, -3.951012436, 0.983715267]),
            IIRFilter([0.046582906, 0.186331626, 0.279497439, 0.186331626, 0.046582906], [1, -0.782095198, 0.679978526, -0.182675697, 0.030118875]),
            IIRFilter([0.976529811, -1.580058426, 0.976529811], [1, -1.580058426, 0.953059623]),
            IIRFilter([0.976529811, -0.603528614, 0.976529811], [1, -0.603528614, 0.953059623])
        ]
    def process(self, val):
        val = self.dc_blocker.process(val)
        for f in self.filters: val = f.process_sample(val)
        return val

class EventSignal(QObject):
    update_text = pyqtSignal(str)
    update_stats = pyqtSignal(bool)
    update_blink = pyqtSignal(str)
    reset_stats = pyqtSignal()

class PureVisualizer(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("基于FPGA异构加速的脑电信号处理与控制系统")
        self.resize(1600, 1000)
        
        self.setStyleSheet("""
            QMainWindow { background-color: #1e1e1e; }
            QLabel { color: #ffffff; font-family: 'Segoe UI', Arial; }
            QComboBox { background-color: #333333; color: white; border: 1px solid #555; border-radius: 4px; padding: 5px; }
            QTextEdit { background-color: #2b2b2b; color: #00ff00; border: 1px solid #444; border-radius: 5px; font-family: Consolas; }
            QFrame#StatsFrame { background-color: #252526; border: 1px solid #3e3e42; border-radius: 8px; }
        """)
        
        self.fs = 500
        self.buffer_size = self.fs * 5  
        self.plot_data = np.zeros((8, self.buffer_size)) 
        self.raw_data = np.zeros((8, self.buffer_size))  
        self.eeg_filters = [EegFilter500Hz() for _ in range(8)]
        
        self.smooth_snr = np.zeros(8)
        self.smooth_wander = np.zeros(8)
        
        self.is_running = False
        self.data_lock = threading.Lock()
        
        self.zynq_ip = "192.168.2.99" 
        self.cmd_port = 8890
        self.last_cmd_time = 0  
        
        self.total_trials = 0
        self.correct_trials = 0
        
        self.event_signal = EventSignal()
        self.event_signal.update_text.connect(self.update_status_label)
        self.event_signal.update_stats.connect(self.update_accuracy_stats)
        self.event_signal.update_blink.connect(self.update_blink_label)
        self.event_signal.reset_stats.connect(self.reset_accuracy_stats)
        
        self.setup_ui()
        self.start_networking()

    def setup_ui(self):
        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        main_layout = QVBoxLayout(main_widget)
        main_layout.setContentsMargins(15, 15, 15, 15)

        top_layout = QHBoxLayout()
        self.lbl_status = QLabel("等待启动。")
        self.lbl_status.setStyleSheet("font-size: 20px; font-weight: bold; color: #1e1e1e; padding: 12px; background: #00ffaa; border-radius: 6px;")
        self.lbl_status.setAlignment(Qt.AlignCenter)
        top_layout.addWidget(self.lbl_status, stretch=4)
        
        self.combo_target = QComboBox()
        # 👑 修改 1：去除了 (索引X)
        self.combo_target.addItems(["目标: 7.5Hz", "目标: 10.0Hz", "目标: 12.0Hz"])
        self.combo_target.setCurrentIndex(1) 
        self.combo_target.setFont(QFont("Arial", 12))
        top_layout.addWidget(self.combo_target)
        
        self.combo_window = QComboBox()
        self.combo_window.addItems(["截断窗口: 1.0秒", "截断窗口: 1.5秒", "截断窗口: 2.0秒", "截断窗口: 2.5秒", "截断窗口: 3.0秒", "截断窗口: 4.0秒"])
        self.combo_window.setCurrentIndex(2) 
        self.combo_window.setFont(QFont("Arial", 12))
        top_layout.addWidget(self.combo_window)
        
        self.combo_snr = QComboBox()
        # 👑 修改 2：增加了 SNR: 前缀
        self.combo_snr.addItems(["SNR: 1秒", "SNR: 2秒", "SNR: 3秒", "SNR: 5秒"])
        self.combo_snr.setCurrentText("SNR: 2秒") 
        self.combo_snr.setFont(QFont("Arial", 12))
        self.combo_snr.currentIndexChanged.connect(self.update_snr_timer)
        top_layout.addWidget(self.combo_snr)
        
        main_layout.addLayout(top_layout)

        h_splitter = QSplitter(Qt.Horizontal)
        v_splitter = QSplitter(Qt.Vertical)
        pg.setConfigOptions(antialias=True, background='#1e1e1e', foreground='#aaaaaa')
        
        self.plot = pg.PlotWidget(title="实时 8 通道高精度脑电波形 (μV)")
        self.plot.showGrid(x=True, y=True, alpha=0.3)
        self.plot.setXRange(0, self.buffer_size, padding=0)
        self.plot.setYRange(0, 1350, padding=0)
        self.plot.disableAutoRange() 
        self.plot.setMouseEnabled(x=False, y=False)
        self.plot.setClipToView(True)
        
        self.colors = [(255, 87, 34), (33, 150, 243), (76, 175, 80), (156, 39, 176), 
                       (255, 193, 7), (0, 188, 212), (233, 30, 99), (205, 220, 57)]
        self.curves = []
        for i in range(8):
            curve = self.plot.plot(pen=pg.mkPen(color=self.colors[i], width=2.0))
            self.curves.append(curve)
            
        v_splitter.addWidget(self.plot)

        self.dashboard = pg.GraphicsLayoutWidget()
        
        # 👑 修改 3：去掉了“窄带”
        self.snr_plot = self.dashboard.addPlot(title="<span style='color: #00ffaa;'> 信噪比 SNR (dB)</span>")
        self.snr_plot.setYRange(0, 15) 
        self.snr_bars = pg.BarGraphItem(x=range(1, 9), height=np.zeros(8), width=0.5, brush='#555')
        self.snr_plot.addItem(self.snr_bars)
        
        # 👑 修改 4：去掉了“低频极化漂移”
        self.imp_plot = self.dashboard.addPlot(title="<span style='color: #ff5555;'>电极脱落检测</span>")
        self.imp_plot.setYRange(0, 150) 
        self.imp_bars = pg.BarGraphItem(x=range(1, 9), height=np.zeros(8), width=0.5, brush='#555')
        self.imp_plot.addItem(self.imp_bars)
        
        ticks = [list(zip(range(1, 9), [f"CH{i}" for i in range(1, 9)]))]
        for p in [self.snr_plot, self.imp_plot]: 
            p.showGrid(y=True, alpha=0.3)
            p.getAxis('bottom').setTicks(ticks)

        v_splitter.addWidget(self.dashboard)
        v_splitter.setSizes([600, 300]) 
        h_splitter.addWidget(v_splitter)
        
        right_panel = QFrame()
        right_panel.setObjectName("StatsFrame")
        right_layout = QVBoxLayout(right_panel)
        
        lbl_stats_title = QLabel("实时解码准确率")
        lbl_stats_title.setStyleSheet("font-size: 18px; font-weight: bold; color: #fff;")
        right_layout.addWidget(lbl_stats_title)
        
        self.lbl_accuracy = QLabel("0.0%")
        self.lbl_accuracy.setAlignment(Qt.AlignCenter)
        self.lbl_accuracy.setStyleSheet("font-size: 72px; font-weight: 900; color: #555;")
        right_layout.addWidget(self.lbl_accuracy)
        
        stats_data_layout = QHBoxLayout()
        self.lbl_total = QLabel("总试次: 0")
        self.lbl_total.setStyleSheet("font-size: 16px; color: #aaa;")
        self.lbl_hit = QLabel("命中数: 0")
        self.lbl_hit.setStyleSheet("font-size: 16px; color: #00ffaa;")
        stats_data_layout.addWidget(self.lbl_total)
        stats_data_layout.addWidget(self.lbl_hit)
        right_layout.addLayout(stats_data_layout)

        self.lbl_blink = QLabel("眨眼触发：待机")
        self.lbl_blink.setAlignment(Qt.AlignCenter)
        self.lbl_blink.setStyleSheet(
            "font-size: 16px; font-weight: bold; color: #8fd3ff; "
            "padding: 10px; background: #1f2b38; border-radius: 6px;"
        )
        right_layout.addWidget(self.lbl_blink)
        
        right_layout.addSpacing(20)
        lbl_log_title = QLabel("Zynq 运行日志")
        lbl_log_title.setStyleSheet("font-size: 14px; font-weight: bold; color: #aaa;")
        right_layout.addWidget(lbl_log_title)
        
        self.log_area = QTextEdit()
        self.log_area.setReadOnly(True)
        right_layout.addWidget(self.log_area)
        
        h_splitter.addWidget(right_panel)
        h_splitter.setSizes([1200, 350]) 
        main_layout.addWidget(h_splitter)

        self.timer_plot = QTimer()
        self.timer_plot.timeout.connect(self.update_plots)
        self.timer_plot.start(33) 
        
        self.timer_snr = QTimer()
        self.timer_snr.timeout.connect(self.calculate_and_update_dashboard)
        self.update_snr_timer() 

    def log(self, msg):
        current_time = time.strftime("%H:%M:%S", time.localtime())
        self.log_area.append(f"[{current_time}] {msg}")
        self.log_area.verticalScrollBar().setValue(self.log_area.verticalScrollBar().maximum())

    def update_accuracy_stats(self, is_correct):
        self.total_trials += 1
        if is_correct: self.correct_trials += 1
        acc = (self.correct_trials / self.total_trials) * 100
        self.lbl_total.setText(f"总试次: {self.total_trials}")
        self.lbl_hit.setText(f"命中数: {self.correct_trials}")
        self.lbl_accuracy.setText(f"{acc:.1f}%")
        
        if acc >= 80: color = "#00ffaa" 
        elif acc >= 60: color = "#ffdd00" 
        else: color = "#ff5555" 
        self.lbl_accuracy.setStyleSheet(f"font-size: 72px; font-weight: 900; color: {color};")

    def reset_accuracy_stats(self):
        self.total_trials = 0
        self.correct_trials = 0
        self.lbl_total.setText("总试次: 0")
        self.lbl_hit.setText("命中数: 0")
        self.lbl_accuracy.setText("0.0%")
        self.lbl_accuracy.setStyleSheet("font-size: 72px; font-weight: 900; color: #555;")

    def update_snr_timer(self):
        # 👑 同步修改：去除了 SNR: 和空格的干扰，提取纯数字
        interval_ms = int(self.combo_snr.currentText().replace("SNR:", "").replace(" ", "").replace("秒", "")) * 1000
        self.timer_snr.start(interval_ms)

    def calculate_and_update_dashboard(self):
        try:
            # 👑 同步修改：去除了 SNR: 和空格的干扰，提取纯数字
            interval_sec = int(self.combo_snr.currentText().replace("SNR:", "").replace(" ", "").replace("秒", ""))
            num_samples = interval_sec * self.fs
            
            with self.data_lock: 
                chunk = self.raw_data[:, -num_samples:].copy()
                plot_chunk = self.plot_data[:, -num_samples:].copy()
                
            n = chunk.shape[1]
            if n == 0: return
            
            chunk = chunk - np.mean(chunk, axis=1, keepdims=True)
            window = np.hanning(n)
            chunk_win = chunk * window
            plot_chunk_win = plot_chunk * window
            
            freqs = np.fft.rfftfreq(n, d=1/self.fs)
            
            fft_amp_raw = np.abs(np.fft.rfft(chunk_win, axis=1)) / n * 4 
            fft_amp_filt = np.abs(np.fft.rfft(plot_chunk_win, axis=1)) / n * 4
            
            wander_mask = (freqs > 0.1) & (freqs < 4.0)
            wander_amp = np.max(fft_amp_raw[:, wander_mask], axis=1)
            self.smooth_wander = 0.8 * self.smooth_wander + 0.2 * wander_amp
            wander_disp = np.clip(self.smooth_wander, 0, 150)
            wander_brushes = [pg.mkBrush('#00aa00') if v <= 50.0 else pg.mkBrush('#aaaa00') if v <= 100.0 else pg.mkBrush('#aa0000') for v in self.smooth_wander]

            target_mask = (freqs >= 7.0) & (freqs <= 12.5)
            neighbor_mask = (freqs >= 5.0) & (freqs <= 15.0)
            target_pwr = np.sum(fft_amp_filt[:, target_mask]**2, axis=1)
            total_pwr = np.sum(fft_amp_filt[:, neighbor_mask]**2, axis=1)
            neighbor_pwr = total_pwr - target_pwr
            
            narrow_snr = 10 * np.log10(np.maximum(target_pwr, 1e-9) / np.maximum(neighbor_pwr, 1e-9))
            self.smooth_snr = 0.8 * self.smooth_snr + 0.2 * narrow_snr
            snr_disp = np.clip(self.smooth_snr, 0, 15) 
            snr_brushes = [pg.mkBrush('#00aa00') if v >= 6.0 else pg.mkBrush('#aaaa00') if v >= 3.0 else pg.mkBrush('#aa0000') for v in self.smooth_snr]

            self.snr_bars.setOpts(height=snr_disp, brushes=snr_brushes)
            self.imp_bars.setOpts(height=wander_disp, brushes=wander_brushes)
            
        except Exception as e:
            pass

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Space:
            if time.time() - self.last_cmd_time < 2.5:
                self.log("[警告] 指令下发频率受限，请勿频繁点击。")
                return
            self.last_cmd_time = time.time()
            
            try:
                target_idx = self.combo_target.currentIndex()
                window_sec_str = self.combo_window.currentText().replace("截断窗口: ", "").replace("秒", "")
                
                cmd_str = f"ARM_SYSTEM|{target_idx}|{window_sec_str}"
                
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.sendto(cmd_str.encode('utf-8'), (self.zynq_ip, self.cmd_port))
                sock.close()
                
                self.update_status_label(f"指令已下发 (目标索引: {target_idx}, 窗口: {window_sec_str}s)，Zynq 开始配置。")
                self.log(f">> 启动下发 ({cmd_str})")
            except Exception as e:
                self.log(f"[错误] 指令发送失败: {e}")

    def start_networking(self):
        self.is_running = True
        threading.Thread(target=self.udp_data_listener, daemon=True).start()
        threading.Thread(target=self.udp_event_listener, daemon=True).start()

    def udp_data_listener(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1) 
        sock.bind(("0.0.0.0", 8888))
        while self.is_running:
            try:
                data, _ = sock.recvfrom(65535)
                n_floats = len(data) // 4
                if n_floats % 8 != 0: continue 
                emg_data = struct.unpack(f'<{n_floats}f', data)
                points = n_floats // 8
                
                batch_raw = np.zeros((8, points))
                batch_filtered = np.zeros((8, points))
                
                for p in range(points):
                    for ch in range(8):
                        val = emg_data[p * 8 + ch]
                        batch_raw[ch, p] = val
                        batch_filtered[ch, p] = self.eeg_filters[ch].process(val)
                        
                batch_filtered = np.nan_to_num(batch_filtered, nan=0.0, posinf=1000.0, neginf=-1000.0)
                batch_filtered = np.clip(batch_filtered, -1000.0, 1000.0)
                        
                with self.data_lock:
                    self.plot_data = np.roll(self.plot_data, -points, axis=1)
                    self.plot_data[:, -points:] = batch_filtered
                    self.raw_data = np.roll(self.raw_data, -points, axis=1)
                    self.raw_data[:, -points:] = batch_raw
            except Exception as e: 
                pass

    def udp_event_listener(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", 8889))

        while self.is_running:
            try:
                data, _ = sock.recvfrom(2048)
                msg = data.decode("utf-8")

                if msg.startswith("READY_FOR_SESSION:"):
                    phase = msg.split(":", 1)[1]
                    if phase == "CALIBRATION":
                        self.event_signal.update_text.emit(
                            "未发现历史权重：请选择参数后按空格开始标定。"
                        )
                    else:
                        self.event_signal.update_text.emit(
                            "系统已就绪：可重新选择目标频率，按空格开始新的测试会话。"
                        )
                    self.event_signal.update_blink.emit("眨眼触发：待机")

                elif msg.startswith("CALIBRATION_REQUIRED"):
                    self.event_signal.update_text.emit(
                        "未发现历史权重，请按空格启动标定流程。"
                    )

                elif msg == "CALIBRATION_STARTED":
                    self.event_signal.update_text.emit("开始三频标定，请按提示完成双眨眼触发。")

                elif msg == "CALIBRATION_FINISHED":
                    self.event_signal.update_text.emit(
                        "标定完成。现在可选择目标频率，再按空格开始测试。"
                    )

                elif msg.startswith("SESSION_STARTED:"):
                    parts = msg.split(":")
                    idx = int(parts[1])
                    freq = float(parts[2])
                    self.event_signal.reset_stats.emit()
                    self.event_signal.update_text.emit(
                        f"新测试会话开始：目标 {freq:.1f} Hz（索引 {idx}）。"
                    )
                    self.event_signal.update_blink.emit("眨眼触发：待机")

                elif msg.startswith("SESSION_FINISHED:"):
                    parts = msg.split(":")
                    freq = float(parts[2])
                    acc = float(parts[3])
                    hit = int(parts[4])
                    total = int(parts[5])
                    self.event_signal.update_text.emit(
                        f"本轮 {freq:.1f} Hz 测试完成：{acc:.1f}% ({hit}/{total})。"
                        "可重新选择频率后按空格继续。"
                    )
                    self.event_signal.update_blink.emit("眨眼触发：待机")
                    self.log(f"<< Session finished: {freq:.1f}Hz, {acc:.1f}% ({hit}/{total})")

                elif "TRIAL_REST" in msg:
                    self.event_signal.update_text.emit(
                        f"{msg.split(':', 1)[1]} 休息中... 随后请连续眨眼 2 次触发。"
                    )

                elif msg.startswith("BLINK_BASELINE:"):
                    sec = msg.split(":", 1)[1]
                    self.event_signal.update_blink.emit("眨眼触发：基线估计中")
                    self.event_signal.update_text.emit(
                        f"眨眼检测正在估计 {sec}s 静息基线，请暂时保持自然睁眼。"
                    )

                elif msg.startswith("BLINK_ARMED:"):
                    parts = msg.split(":")
                    try:
                        baseline = float(parts[1])
                        sigma = float(parts[2])
                        p2p_th = float(parts[3])
                        self.event_signal.update_blink.emit(
                            f"眨眼已武装 | σ={sigma:.1f}, P2P阈值={p2p_th:.1f}"
                        )
                        self.log(
                            f"<< Blink armed: baseline={baseline:.1f}, "
                            f"sigma={sigma:.1f}, p2p_th={p2p_th:.1f}"
                        )
                    except Exception:
                        self.log(f"<< Zynq: {msg}")

                elif msg in ("WAITING_BLINK_TRIGGER", "WAITING_TRIPLE_BLINK"):
                    self.event_signal.update_text.emit("等待连续双眨眼触发刺激...")
                    self.event_signal.update_blink.emit("眨眼触发：等待第1次")

                elif msg.startswith("BLINK_DETECTED:"):
                    # 新格式：BLINK_DETECTED:count:p2p:p2p_threshold:duration_ms:confidence
                    parts = msg.split(":")
                    try:
                        count = int(parts[1])
                        p2p = float(parts[2])
                        threshold = float(parts[3])
                        duration_ms = float(parts[4])
                        confidence = float(parts[5])
                        self.event_signal.update_blink.emit(
                            f"眨眼触发：已检测 {count}/2 | "
                            f"P2P {p2p:.1f}/{threshold:.1f} | C={confidence:.2f}"
                        )
                        self.log(
                            f"<< Blink {count}/2: p2p={p2p:.1f}, "
                            f"threshold={threshold:.1f}, duration={duration_ms:.0f}ms, "
                            f"confidence={confidence:.2f}"
                        )
                    except Exception:
                        self.log(f"<< Zynq: {msg}")

                elif msg == "BLINK_PAIR_RESET":
                    self.event_signal.update_blink.emit("眨眼触发：第1次已超时，重新等待")

                elif msg.startswith("DOUBLE_BLINK_OK:"):
                    gap = msg.split(":", 1)[1]
                    self.event_signal.update_blink.emit(
                        f"眨眼触发：双眨眼确认 ✓  间隔 {gap}s"
                    )

                elif msg == "BLINK_TIMEOUT":
                    self.event_signal.update_blink.emit("眨眼触发：本轮超时，继续等待")
                    self.event_signal.update_text.emit("未形成有效双眨眼，系统继续等待...")

                elif msg == "BLINK_TRIGGERED":
                    self.event_signal.update_blink.emit("眨眼触发：双眨眼确认 ✓")
                    self.event_signal.update_text.emit("刺激开始，注视频闪方块。")

                elif msg.startswith("ARMED_OK:"):
                    try:
                        _, idx_s, win_s = msg.split(":")
                        idx = int(idx_s)
                        freq = [7.5, 10.0, 12.0][idx]
                        self.event_signal.update_text.emit(
                            f"Zynq已接收请求：目标 {freq:.1f}Hz，分析窗口 {win_s}s。"
                        )
                        self.log(f"<< Zynq ACK: target={freq:.1f}Hz, window={win_s}s")
                    except Exception:
                        self.log(f"<< Zynq: {msg}")

                elif msg.startswith("SYSTEM_BUSY:"):
                    self.event_signal.update_text.emit(msg.split(":", 1)[1])
                    self.log(f"<< Zynq busy: {msg}")

                elif msg.startswith("WINDOW_FIXED:"):
                    self.log(f"<< {msg}")

                elif msg == "CALCULATING":
                    self.event_signal.update_text.emit("采集结束，正在保存数据并分析...")

                elif msg == "TEST_FINISHED":
                    self.event_signal.update_blink.emit("眨眼触发：待机")
                    self.event_signal.update_text.emit("单次测试完成，准备下一次触发。")

                elif msg.startswith("CORRECT"):
                    clean_msg = msg.split(":", 1)[1] if ":" in msg else msg
                    self.log(f"<< Zynq: {clean_msg}")
                    self.event_signal.update_stats.emit(True)

                elif msg.startswith("INCORRECT"):
                    clean_msg = msg.split(":", 1)[1] if ":" in msg else msg
                    self.log(f"<< Zynq: {clean_msg}")
                    self.event_signal.update_stats.emit(False)

                elif msg.startswith("SESSION_ERROR:") or msg.startswith("CMD_ERROR:"):
                    self.event_signal.update_text.emit(msg)
                    self.log(f"<< Zynq: {msg}")

                else:
                    self.log(f"<< Zynq: {msg}")

            except Exception as e:
                self.log(f"[UDP事件异常] {e}")

    def update_blink_label(self, text):
        self.lbl_blink.setText(text)
        if "确认" in text:
            color = "#00ffaa"
        elif "已检测" in text:
            color = "#ffdd00"
        elif "超时" in text:
            color = "#ff9966"
        else:
            color = "#8fd3ff"
        self.lbl_blink.setStyleSheet(
            f"font-size: 16px; font-weight: bold; color: {color}; "
            "padding: 10px; background: #1f2b38; border-radius: 6px;"
        )

    def update_status_label(self, text):
        self.lbl_status.setText(text)
        if "异常" in text or "错误" in text or "失败" in text or "越界" in text:
            self.lbl_status.setStyleSheet("font-size: 20px; font-weight: bold; color: #fff; padding: 12px; background: #ff5555; border-radius: 6px;")
        elif "刺激开始" in text:
            self.lbl_status.setStyleSheet("font-size: 20px; font-weight: bold; color: #1e1e1e; padding: 12px; background: #ffdd00; border-radius: 6px;")
        elif "分析" in text or "配置" in text:
            self.lbl_status.setStyleSheet("font-size: 20px; font-weight: bold; color: #fff; padding: 12px; background: #0088ff; border-radius: 6px;")
        else:
            self.lbl_status.setStyleSheet("font-size: 20px; font-weight: bold; color: #1e1e1e; padding: 12px; background: #00ffaa; border-radius: 6px;")

    def update_plots(self):
        with self.data_lock: snapshot = self.plot_data.copy()
        for i in range(8):
            y_data = snapshot[i] + (i + 1) * 150 
            self.curves[i].setData(y=y_data)

    def closeEvent(self, event):
        self.is_running = False
        event.accept()

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = PureVisualizer()
    window.show()
    sys.exit(app.exec_())