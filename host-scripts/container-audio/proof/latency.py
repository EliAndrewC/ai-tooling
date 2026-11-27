#!/usr/bin/env python3
"""Record from an ALSA PCM fed by feeder32.py and print, every 0.5 s, how far behind real time the
audio is (ms) and any break in the frame count. Usage: latency.py PCM SECONDS T0FILE"""
import ctypes as C, struct, sys, time
A = C.CDLL("libasound.so.2"); A.snd_strerror.restype = C.c_char_p
def ok(rc, what):
    if rc < 0: raise SystemExit(f"{what}: {A.snd_strerror(rc).decode()}")
    return rc
pcm = C.c_void_p(); ok(A.snd_pcm_open(C.byref(pcm), sys.argv[1].encode(), 1, 0), "open")
hw = C.c_void_p(); A.snd_pcm_hw_params_malloc(C.byref(hw)); ok(A.snd_pcm_hw_params_any(pcm, hw), "any")
ok(A.snd_pcm_hw_params_set_access(pcm, hw, 3), "access"); ok(A.snd_pcm_hw_params_set_format(pcm, hw, 2), "format")
rate = C.c_uint(48000); ok(A.snd_pcm_hw_params_set_rate_near(pcm, hw, C.byref(rate), None), "rate")
ok(A.snd_pcm_hw_params_set_channels(pcm, hw, 2), "channels")
pt = C.c_uint(25_000); bt = C.c_uint(100_000)
A.snd_pcm_hw_params_set_period_time_near(pcm, hw, C.byref(pt), None); A.snd_pcm_hw_params_set_buffer_time_near(pcm, hw, C.byref(bt), None)
ok(A.snd_pcm_hw_params(pcm, hw), "hw_params"); ok(A.snd_pcm_prepare(pcm), "prepare"); ok(A.snd_pcm_start(pcm), "start")
t0 = float(open(sys.argv[3]).read()); buf = C.create_string_buffer(1200 * 4)
end = time.time() + float(sys.argv[2]); last = None; breaks = 0; nxt = time.time(); out = []
while time.time() < end:
    got = ok(A.snd_pcm_readi(pcm, buf, 1200), "readi"); now = time.time()
    v = struct.unpack(f"<{got*2}H", buf.raw[:got * 4])
    for k in range(0, len(v), 2):
        i = v[k] | (v[k+1] << 16)
        if last is not None and i != last + 1: breaks += 1
        last = i
    if now >= nxt:
        out.append(f"{(now - t0) * 1000 - last / 48:6.0f}"); nxt = now + 0.5
print("behind real time, ms every 0.5 s:", " ".join(out), f"| breaks: {breaks}")
