import os
import serial
import struct
import time
import socket
import queue
import threading
import numpy as np
from pynq import Overlay, allocate, MMIO
from scipy import signal
from scipy.linalg import qr, svd, pinv

# ============================================================
# 1. 基础参数
# ============================================================
Freq_list = [7.5, 10.0, 12.0]
Test_idx = 2                      # 保留该命名；每个测试会话开始时由 PC 动态更新
max_test_num = 10
calib_num = 2

fs_rate = 500
pc_ip_addr = "192.168.2.100"
port_data = 8888
port_event = 8889
port_cmd = 8890

rest_sec = 3.0
discard_sec = 1.0
window_sec = 2.0                  # 当前硬件分析窗口固定 2 s
stim_sec = 4.0
cca_len = int(window_sec * fs_rate)

weight_file = "tjl_brain_weights.npy"
save_folder = "ssvepdate"
os.makedirs(save_folder, exist_ok=True)

is_running = True
sys_status = "STREAM_ONLY"       # 仅用于数据路由，不再拿它当 PC 启动命令锁
cur_phase = "INIT"

# 识别数据与眨眼数据彻底分开
fbcca_queue = queue.Queue(maxsize=fs_rate * 10)
blink_queue = queue.Queue(maxsize=fs_rate * 3)

# PC 启动请求与实验状态独立
session_request = threading.Event()
config_lock = threading.Lock()
pending_test_idx = Test_idx
session_busy = False

event_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def send_sys_event(msg_str):
    event_sock.sendto(msg_str.encode("utf-8"), (pc_ip_addr, port_event))


def log_to_pc(msg_str):
    send_sys_event(msg_str)


def clear_queue(q_obj):
    with q_obj.mutex:
        q_obj.queue.clear()


# ============================================================
# 2. SSVEP 参考信号
# ============================================================
def get_ref_signal(f_val, fs, samples, harms=1):
    t_arr = np.arange(samples) / fs
    y_list = []
    for h in range(1, harms + 1):
        y_list.append(np.sin(2 * np.pi * f_val * h * t_arr))
        y_list.append(np.cos(2 * np.pi * f_val * h * t_arr))
    y_mat = np.asarray(y_list)
    return y_mat - np.mean(y_mat, axis=1, keepdims=True)




# ============================================================
# 3. CH1 双时间窗均值差双眨眼检测（V4）
# ------------------------------------------------------------
# 根据真实 CH1 数据设计：
# - 物理 CH1 固定作为眨眼/EOG触发通道，对应 Python 索引 0；
# - 原始 CH1 存在明显 50 Hz 周期干扰，因此不再使用单点 diff；
# - 使用 20 ms 平滑 + “前100 ms均值 - 后100 ms均值”作为特征；
# - 高->低眨眼时 score 为正；
# - 固定阈值 100：当前实测普通波动约 20~50，眨眼约 180~280；
# - 使用阈值滞回 + 300 ms 不应期，防止一次眨眼重复触发；
# - 两次独立眨眼必须在 0.30~1.50 s 内完成。
#
# 注意：
# 本版本不再要求每轮先保持睁眼重新采基线。
# ============================================================

Blink_ch = 0                      # 物理 CH1 -> Python 索引 0

Blink_smooth_ms = 20             # 约一个 50 Hz 周期
Blink_mean_win_ms = 100           # 前后均值窗长度
Blink_mean_gap_ms = 20            # 两个均值窗之间留空
Blink_score_th = 100.0            # 主触发阈值
Blink_release_th = 55.0           # 滞回释放阈值

Blink_refractory_ms = 300         # 单次事件不应期
Blink_arm_guard_ms = 250          # 进入等待状态后的短保护期

Min_gap = 0.30                    # 双眨眼最小间隔
Max_window = 1.50                 # 双眨眼最大间隔
Target_clicks = 2


class MeanWindowBlinkDetector:
    """
    因果实时检测器。

    score =
        mean(较早100 ms窗口)
        -
        mean(最近100 ms窗口)

    两个窗口之间保留 Blink_mean_gap_ms 的间隔。

    对于实际CH1的“高 -> 低”眨眼：
        score > 0

    采用：
        20 ms滑动平均
        + 100 ms前后均值差
        + 阈值滞回
        + 不应期
    """

    def __init__(self, fs):
        from collections import deque

        self.fs = int(fs)

        self.smooth_n = max(
            1,
            int(round(
                Blink_smooth_ms
                * self.fs
                / 1000.0
            ))
        )

        self.win_n = max(
            2,
            int(round(
                Blink_mean_win_ms
                * self.fs
                / 1000.0
            ))
        )

        self.gap_n = max(
            0,
            int(round(
                Blink_mean_gap_ms
                * self.fs
                / 1000.0
            ))
        )

        self.total_n = (
            self.win_n
            + self.gap_n
            + self.win_n
        )

        self.refractory_n = max(
            1,
            int(round(
                Blink_refractory_ms
                * self.fs
                / 1000.0
            ))
        )

        self.guard_n = max(
            0,
            int(round(
                Blink_arm_guard_ms
                * self.fs
                / 1000.0
            ))
        )

        self.smooth_buf = deque(
            maxlen=self.smooth_n
        )

        self.feature_buf = deque(
            maxlen=self.total_n
        )

        self.sample_counter = 0
        self.last_event_sample = -10**9

        # 滞回状态：
        # True  = 可以触发下一次单眨眼
        # False = 必须等score跌回release_th以下才能重新武装
        self.armed = True

        self.last_score = 0.0

    def reset(self):
        self.smooth_buf.clear()
        self.feature_buf.clear()
        self.sample_counter = 0
        self.last_event_sample = -10**9
        self.armed = True
        self.last_score = 0.0

    def _smooth(self, x):
        self.smooth_buf.append(
            float(x)
        )

        return float(
            np.mean(
                self.smooth_buf
            )
        )

    def process_sample(self, raw_value):
        self.sample_counter += 1

        x = float(raw_value)

        if not np.isfinite(x):
            return None

        y = self._smooth(x)

        self.feature_buf.append(
            y
        )

        if self.sample_counter <= self.guard_n:
            return None

        if len(self.feature_buf) < self.total_n:
            return None

        buf = np.asarray(
            self.feature_buf,
            dtype=np.float64
        )

        before = buf[
            :self.win_n
        ]

        after_start = (
            self.win_n
            + self.gap_n
        )

        after = buf[
            after_start:
            after_start + self.win_n
        ]

        mean_before = float(
            np.mean(before)
        )

        mean_after = float(
            np.mean(after)
        )

        score = (
            mean_before
            - mean_after
        )

        self.last_score = score

        # ----------------------------------------------------
        # 滞回释放：
        # 一次事件后，必须等score回到较低水平才允许下一事件
        # ----------------------------------------------------
        if not self.armed:
            if abs(score) <= Blink_release_th:
                self.armed = True
            else:
                return None

        # 不应期内禁止重复触发
        if (
            self.sample_counter
            - self.last_event_sample
            < self.refractory_n
        ):
            return None

        # 只检测实际数据中主要的“高 -> 低”方向
        if score < Blink_score_th:
            return None

        event = {
            "sample": self.sample_counter,
            "score": float(score),
            "mean_before": mean_before,
            "mean_after": mean_after,
            "threshold": float(Blink_score_th),
            "confidence": float(
                score
                / max(Blink_score_th, 1e-9)
            ),
        }

        self.last_event_sample = (
            self.sample_counter
        )

        self.armed = False

        return event

    def process_batch(self, batch):
        events = []

        if (
            batch.ndim != 2
            or Blink_ch >= batch.shape[0]
        ):
            return events

        x = np.asarray(
            batch[Blink_ch, :],
            dtype=np.float64
        )

        x = np.nan_to_num(
            x,
            nan=0.0,
            posinf=0.0,
            neginf=0.0
        )

        for value in x:
            event = self.process_sample(
                value
            )

            if event is not None:
                events.append(
                    event
                )

        return events


def wait_blink_cmd(time_out=60.0):
    """
    等待两个独立眨眼事件。

    不再做每轮静息基线采集。
    """
    clear_queue(
        blink_queue
    )

    detector = MeanWindowBlinkDetector(
        fs_rate
    )

    send_sys_event(
        f"BLINK_ARMED:"
        f"0.00:"
        f"0.00:"
        f"{Blink_score_th:.2f}"
    )

    send_sys_event(
        "WAITING_BLINK_TRIGGER"
    )

    log_to_pc(
        f"[眨眼] CH1双时间窗检测已启动："
        f"score_th={Blink_score_th:.1f}, "
        f"release_th={Blink_release_th:.1f}；"
        "请连续眨眼2次。"
    )

    first_event = None
    first_time = None
    t_start = time.time()

    while (
        is_running
        and (
            time.time()
            - t_start
            < time_out
        )
    ):
        try:
            b_data = blink_queue.get(
                timeout=0.1
            )

            events = detector.process_batch(
                b_data
            )

            for ev in events:
                now = time.time()

                # -----------------------------
                # 第一次眨眼
                # -----------------------------
                if first_event is None:
                    first_event = ev
                    first_time = now

                    send_sys_event(
                        "BLINK_DETECTED:1:"
                        f"{ev['score']:.1f}:"
                        f"{Blink_score_th:.1f}:"
                        f"{Blink_mean_win_ms:.0f}:"
                        f"{ev['confidence']:.2f}"
                    )

                    log_to_pc(
                        f"[眨眼] 第1次："
                        f"score={ev['score']:.1f}, "
                        f"before={ev['mean_before']:.1f}, "
                        f"after={ev['mean_after']:.1f}"
                    )

                    continue

                gap = (
                    now
                    - first_time
                )

                # 太近：认为仍属于第一次眨眼残余
                if gap < Min_gap:
                    continue

                # -----------------------------
                # 双眨眼成立
                # -----------------------------
                if gap <= Max_window:
                    send_sys_event(
                        "BLINK_DETECTED:2:"
                        f"{ev['score']:.1f}:"
                        f"{Blink_score_th:.1f}:"
                        f"{Blink_mean_win_ms:.0f}:"
                        f"{ev['confidence']:.2f}"
                    )

                    send_sys_event(
                        f"DOUBLE_BLINK_OK:"
                        f"{gap:.2f}"
                    )

                    log_to_pc(
                        f"[状态] 双眨眼确认："
                        f"gap={gap:.2f}s，"
                        f"score2={ev['score']:.1f}，"
                        "触发刺激。"
                    )

                    return True

                # 前一事件超时：
                # 当前事件重新作为新的第一次
                first_event = ev
                first_time = now

                send_sys_event(
                    "BLINK_DETECTED:1:"
                    f"{ev['score']:.1f}:"
                    f"{Blink_score_th:.1f}:"
                    f"{Blink_mean_win_ms:.0f}:"
                    f"{ev['confidence']:.2f}"
                )

                log_to_pc(
                    "[眨眼] 前一眨眼超出配对时间窗，"
                    "当前事件重新记为第1次。"
                )

        except queue.Empty:
            if (
                first_event is not None
                and first_time is not None
                and (
                    time.time()
                    - first_time
                    > Max_window
                )
            ):
                first_event = None
                first_time = None

                send_sys_event(
                    "BLINK_PAIR_RESET"
                )

            continue

    send_sys_event(
        "BLINK_TIMEOUT"
    )

    log_to_pc(
        "[眨眼] 等待超时，"
        "本轮继续等待新的双眨眼。"
    )

    return False


# ============================================================
# 4. FPGA Overlay / DMA / GPIO / MMIO
# ============================================================
print("初始化 FPGA 硬件...")

ref_waves_list = [
    get_ref_signal(f, fs_rate, cca_len, harms=2)
    for f in Freq_list
]

fpga_overlay = Overlay("bci_stim.bit")
dma_mod = fpga_overlay.axi_dma_0
gpio_mod = fpga_overlay.axi_gpio_0.channel1
gpio_mod.write(0, 0x7)

spatial_ip = None
for name in fpga_overlay.ip_dict.keys():
    if "spatial" in name.lower():
        spatial_ip = name
        break

if spatial_ip is None:
    raise RuntimeError("IP核未找到")

ip_cfg = fpga_overlay.ip_dict[spatial_ip]
spatial_mmio = MMIO(ip_cfg["phys_addr"], ip_cfg["addr_range"])

dma_in = allocate(shape=(cca_len * 7,), dtype=np.int32)
dma_out = allocate(shape=(cca_len * 3,), dtype=np.int32)

b_filt, a_filt = signal.butter(
    4,
    [5.0 / (fs_rate / 2), 40.0 / (fs_rate / 2)],
    "bandpass",
)


# ============================================================
# 5. 空间权重训练 / MMIO
# ============================================================
def calc_weights(calib_dict):
    log_to_pc("计算滤波权重...")
    w_mat = np.zeros((len(Freq_list), 7))

    for i, f_val in enumerate(Freq_list):
        x_dat = calib_dict[f_val]
        x_dat = x_dat - np.mean(x_dat, axis=1, keepdims=True)
        y_dat = get_ref_signal(f_val, fs_rate, x_dat.shape[1], harms=2)

        q_x, r_x = qr(x_dat.T, mode="economic")
        q_y, _ = qr(y_dat.T, mode="economic")
        u, _, _ = svd(np.dot(q_x.T, q_y))

        w_tmp = np.dot(pinv(r_x), u[:, 0])
        max_w = np.max(np.abs(w_tmp))
        if max_w > 0:
            w_tmp = w_tmp / max_w
        w_mat[i, :] = w_tmp

    return w_mat


def write_hw_weights(mmio_obj, w_mat):
    log_to_pc("写入 FPGA 空间权重寄存器...")
    offsets = [0x00, 0x1C, 0x38]

    for t_i in range(3):
        for c_i in range(7):
            f_val = w_mat[t_i, c_i]
            fix_val = int(round(f_val * (2 ** 24)))
            if fix_val < 0:
                fix_val = (1 << 32) + fix_val
            mmio_obj.write(offsets[t_i] + c_i * 4, fix_val)

    log_to_pc("21 个空间权重已写入 FPGA")


# ============================================================
# 6. PC 命令监听
# ------------------------------------------------------------
# 关键修改：
# - cmd_listener 不再直接修改 sys_status；
# - sys_status 只表示 EEG 数据当前该去 blink_queue 还是 fbcca_queue；
# - PC 启动请求用 session_request 独立通知主实验线程；
# - 主实验线程是永久循环，完成一个频率后不会退出，因此无需重启 PS。
# ============================================================
def listen_cmds():
    global is_running, pending_test_idx, session_busy

    cmd_s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cmd_s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    cmd_s.bind(("0.0.0.0", port_cmd))
    cmd_s.settimeout(1.0)

    print(f"UDP命令监听启动，端口: {port_cmd}")

    while is_running:
        try:
            recv_d, addr = cmd_s.recvfrom(1024)
            cmd = recv_d.decode("utf-8").strip()
            print(f"[PC CMD] {addr}: {cmd}")

            parts = cmd.split("|")
            if not parts or parts[0] != "ARM_SYSTEM":
                send_sys_event(f"CMD_ERROR:未知命令 {cmd}")
                continue

            new_idx = pending_test_idx
            if len(parts) >= 2 and parts[1] != "":
                new_idx = int(parts[1])
                if not 0 <= new_idx < len(Freq_list):
                    send_sys_event(f"CMD_ERROR:目标索引越界 {new_idx}")
                    continue

            if len(parts) >= 3 and parts[2] != "":
                req_window = float(parts[2])
                if abs(req_window - window_sec) > 1e-9:
                    send_sys_event(
                        f"WINDOW_FIXED:当前分析窗口固定 {window_sec:.1f}s，"
                        f"PC请求 {req_window:.1f}s 未应用"
                    )

            with config_lock:
                if session_busy:
                    send_sys_event("SYSTEM_BUSY:当前实验尚未结束，请完成后再启动新频率")
                    continue
                pending_test_idx = new_idx
                session_request.set()

            send_sys_event(f"ARMED_OK:{new_idx}:{window_sec:.1f}")
            print(f"已接收新会话请求：idx={new_idx}, freq={Freq_list[new_idx]}Hz")

        except socket.timeout:
            continue
        except Exception as exc:
            print(f"[CMD ERROR] {exc}")
            try:
                send_sys_event(f"CMD_ERROR:{exc}")
            except Exception:
                pass


def wait_for_session_request(label):
    """等待 PC 空格键请求，并返回目标索引。"""
    send_sys_event(f"READY_FOR_SESSION:{label}")
    while is_running:
        if session_request.wait(timeout=0.2):
            with config_lock:
                idx = pending_test_idx
                session_request.clear()
            return idx
    return None


# ============================================================
# 7. 采集一个刺激段
# ============================================================
def acquire_stimulus_block():
    global sys_status

    clear_queue(fbcca_queue)
    sys_status = "STIMULATING"
    gpio_mod.write(1, 0x7)

    req_pts = int(stim_sec * fs_rate)
    d_list = []
    cur_pts = 0

    while cur_pts < req_pts and is_running:
        try:
            b = fbcca_queue.get(timeout=1.0)
            d_list.append(b)
            cur_pts += b.shape[1]
        except queue.Empty:
            continue

    gpio_mod.write(0, 0x7)
    sys_status = "CALCULATING"
    send_sys_event("CALCULATING")

    if not d_list:
        return None
    return np.hstack(d_list)[:, :req_pts]


# ============================================================
# 8. 标定
# ============================================================
def run_calibration():
    global sys_status, cur_phase

    cur_phase = "CALIBRATION"
    calib_data = {f: [] for f in Freq_list}
    send_sys_event("CALIBRATION_STARTED")

    for f in Freq_list:
        for t_idx in range(calib_num):
            if not is_running:
                return False

            log_to_pc(f"TRIAL_REST:标定 {f}Hz - 第 {t_idx + 1}/{calib_num} 轮")
            time.sleep(rest_sec)

            sys_status = "WAITING_BLINK"
            while is_running and not wait_blink_cmd(time_out=60.0):
                log_to_pc("[提示] 未形成有效双眨眼，继续等待。")

            if not is_running:
                return False

            send_sys_event("BLINK_TRIGGERED")
            full_d = acquire_stimulus_block()
            if full_d is None:
                log_to_pc("ERROR:标定阶段未采集到 EEG 数据")
                sys_status = "STREAM_ONLY"
                continue

            ch7_d = np.copy(full_d[1:8, :])
            ch7_d = signal.filtfilt(b_filt, a_filt, ch7_d)
            s_idx = int(discard_sec * fs_rate)
            calib_data[f].append(np.copy(ch7_d[:, s_idx:]))

            sys_status = "STREAM_ONLY"
            send_sys_event("TEST_FINISHED")

        if not calib_data[f]:
            raise RuntimeError(f"{f} Hz 标定数据为空")
        calib_data[f] = np.hstack(calib_data[f])

    calc_w = calc_weights(calib_data)
    np.save(weight_file, calc_w)
    write_hw_weights(spatial_mmio, calc_w)
    sys_status = "STREAM_ONLY"
    send_sys_event("CALIBRATION_FINISHED")
    return True


# ============================================================
# 9. 单个频率测试会话
# ============================================================
def run_test_session(session_idx):
    global Test_idx, sys_status, cur_phase

    Test_idx = int(session_idx)
    cur_phase = "TESTING"
    ok_cnt = 0

    send_sys_event(f"SESSION_STARTED:{Test_idx}:{Freq_list[Test_idx]:.1f}")
    log_to_pc(
        f"[测试] 新会话开始：Test_idx={Test_idx}, 目标={Freq_list[Test_idx]}Hz"
    )

    bin_file = os.path.join(
        save_folder,
        f"All_Trials_{Freq_list[Test_idx]}Hz.bin",
    )
    if os.path.exists(bin_file):
        os.remove(bin_file)

    for t_idx in range(max_test_num):
        if not is_running:
            break

        log_to_pc(
            f"TRIAL_REST:测试 {Freq_list[Test_idx]}Hz - "
            f"第 {t_idx + 1}/{max_test_num} 轮"
        )
        time.sleep(rest_sec)

        # 每一轮直接进入CH1双时间窗均值差双眨眼检测，不再重复采基线
        sys_status = "WAITING_BLINK"
        while is_running and not wait_blink_cmd(time_out=60.0):
            log_to_pc("[提示] 未形成有效双眨眼，继续等待。")

        if not is_running:
            return

        send_sys_event("BLINK_TRIGGERED")
        full_d = acquire_stimulus_block()
        if full_d is None:
            log_to_pc("ERROR:测试阶段未采集到 EEG 数据")
            sys_status = "STREAM_ONLY"
            continue

        # 原始 EEG 保存
        with open(bin_file, "ab") as f_out:
            f_out.write(np.ascontiguousarray(full_d, dtype=np.float32).tobytes())

        # 取 7 通道固定 2 s 窗口
        s_idx = int(discard_sec * fs_rate)
        e_idx = s_idx + cca_len
        tgt_eeg = np.copy(full_d[1:8, s_idx:e_idx])

        # 去直流 + 归一化；IIR 在 PL 内完成
        tgt_eeg = tgt_eeg - np.mean(tgt_eeg, axis=1, keepdims=True)
        m_amp = np.max(np.abs(tgt_eeg))
        if m_amp > 0:
            tgt_eeg = tgt_eeg / m_amp

        fix_eeg = np.round(tgt_eeg * (2 ** 24)).astype(np.int32)
        dma_in[:] = fix_eeg.T.flatten()

        dma_mod.recvchannel.transfer(dma_out)
        dma_mod.sendchannel.transfer(dma_in)
        dma_mod.sendchannel.wait()
        dma_mod.recvchannel.wait()

        hw_res = dma_out.reshape(-1, 3).T

        scores = np.zeros(len(Freq_list))
        for i in range(len(Freq_list)):
            feat_v = hw_res[i, :].astype(float)
            if np.std(feat_v) < 1e-6:
                feat_v = feat_v + np.random.normal(0, 1e-5, len(feat_v))

            score_sq = 0.0
            for r_w in ref_waves_list[i]:
                r = np.corrcoef(feat_v, r_w)[0, 1]
                if np.isnan(r):
                    r = 0.0
                score_sq += r ** 2
            scores[i] = np.sqrt(score_sq)

        best_idx = int(np.argmax(scores))
        pred_f = Freq_list[best_idx]

        if best_idx == Test_idx:
            ok_cnt += 1
            send_sys_event(f"CORRECT:FPGA 解算正确 (识别为 {pred_f}Hz)")
            gpio_mod.write(2, 0x7)
        else:
            send_sys_event(f"INCORRECT:FPGA 解算错误 (误识为 {pred_f}Hz)")
            gpio_mod.write(4, 0x7)

        time.sleep(1.0)
        gpio_mod.write(0, 0x7)
        sys_status = "STREAM_ONLY"
        send_sys_event("TEST_FINISHED")

    accuracy = (ok_cnt / max_test_num) * 100.0 if max_test_num else 0.0
    send_sys_event(
        f"SESSION_FINISHED:{Test_idx}:{Freq_list[Test_idx]:.1f}:{accuracy:.1f}:{ok_cnt}:{max_test_num}"
    )
    log_to_pc(
        f"[测试] 会话完成：{Freq_list[Test_idx]}Hz，"
        f"准确率 {accuracy:.1f}% ({ok_cnt}/{max_test_num})"
    )
    sys_status = "STREAM_ONLY"


# ============================================================
# 10. 永久主调度循环
# ============================================================
def main_loop():
    global session_busy, sys_status, cur_phase

    # 权重只需初始化一次
    if os.path.exists(weight_file):
        log_to_pc("加载历史权重")
        saved_w = np.load(weight_file)
        write_hw_weights(spatial_mmio, saved_w)
    else:
        log_to_pc("CALIBRATION_REQUIRED:未发现历史权重，请在 PC 按空格开始标定")
        idx = wait_for_session_request("CALIBRATION")
        if idx is None:
            return

        with config_lock:
            session_busy = True
        try:
            if not run_calibration():
                return
        finally:
            with config_lock:
                session_busy = False

    # 关键：测试完成后不 return，而是永远等待下一次 PC 请求
    while is_running:
        cur_phase = "READY"
        sys_status = "STREAM_ONLY"
        idx = wait_for_session_request("TEST")
        if idx is None:
            break

        with config_lock:
            session_busy = True

        try:
            run_test_session(idx)
        except Exception as exc:
            print(f"[SESSION ERROR] {exc}")
            send_sys_event(f"SESSION_ERROR:{exc}")
            sys_status = "STREAM_ONLY"
        finally:
            with config_lock:
                session_busy = False


# ============================================================
# 11. 串口 EEG 路由
# ============================================================
def read_serial_data(port_str):
    global is_running

    u_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    try:
        s_port = serial.Serial()
        s_port.port = port_str
        s_port.baudrate = 1000000
        s_port.timeout = 0.1
        s_port.dtr = False
        s_port.rts = False
        s_port.open()
        s_port.reset_input_buffer()

        c_cmd = bytearray([0xAA, 0x04, 0x80, 0x09, 0x01, 0x8C, 0xBB])
        s_cmd = bytearray([0xAA, 0x04, 0x80, 0x11, 0x01, 0x94, 0xBB])

        buf = bytearray()
        t_last = 0
        flag_col = False

        print(f"串口 EEG 路由启动: {port_str} @ 1000000 baud")

        while is_running:
            if not flag_col and time.time() - t_last > 1.0:
                s_port.write(c_cmd)
                time.sleep(0.05)
                s_port.write(s_cmd)
                t_last = time.time()

            if s_port.in_waiting > 0:
                buf.extend(s_port.read(s_port.in_waiting))

            while len(buf) > 5:
                if buf[0] != 0xA5:
                    del buf[0:1]
                    continue

                f_len = buf[1] + 3
                if len(buf) < f_len:
                    break

                c_byte = buf[1] ^ buf[2]
                if buf[f_len - 1] != 0x5A or c_byte != buf[3]:
                    del buf[0:1]
                    continue

                frm = buf[0:f_len]

                if frm[2] == 0x11:
                    if not flag_col:
                        flag_col = True
                        print("EEG链路已连接，开始同步数据")

                    p_len = frm[1] - 2
                    p_bytes = frm[4:4 + p_len]

                    # 原始 EEG 始终发 PC，用于显示
                    u_sock.sendto(p_bytes, (pc_ip_addr, port_data))

                    f_cnt = p_len // 4
                    if f_cnt > 0 and f_cnt % 8 == 0:
                        eeg_data = struct.unpack(f"<{f_cnt}f", p_bytes)
                        pts = f_cnt // 8

                        if pts > 0:
                            b_mat = np.asarray(
                                eeg_data,
                                dtype=np.float32,
                            ).reshape(pts, 8).T

                            if sys_status == "WAITING_BLINK":
                                try:
                                    blink_queue.put_nowait(b_mat)
                                except queue.Full:
                                    # 触发队列宁可丢旧数据也不要造成无限延迟
                                    try:
                                        blink_queue.get_nowait()
                                        blink_queue.put_nowait(b_mat)
                                    except Exception:
                                        pass

                            elif sys_status == "STIMULATING":
                                try:
                                    fbcca_queue.put_nowait(b_mat)
                                except queue.Full:
                                    pass

                del buf[0:f_len]

    except KeyboardInterrupt:
        print("安全关闭串口通道...")
        is_running = False

    except Exception as exc:
        print(f"[SERIAL ERROR] {exc}")
        is_running = False

    finally:
        
        try:
            if "s_port" in locals() and s_port.is_open:
                s_port.write(
                    bytearray([0xAA, 0x04, 0x80, 0x11, 0x00, 0x95, 0xBB])
                )
                s_port.close()
        except Exception:
            pass


if __name__ == "__main__":
    threading.Thread(target=listen_cmds, daemon=True).start()
    threading.Thread(target=main_loop, daemon=True).start()
    read_serial_data("/dev/ttyACM0")
