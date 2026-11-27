#!/usr/bin/env python3
"""Read a counting pattern (s16, left channel = frame number mod 65536) through an ALSA capture PCM,
stall mid-way, and count breaks in the sequence. Usage: integrity16.py PCM STALL_SECONDS"""
import ctypes as C, struct, sys, time
A = C.CDLL("libasound.so.2"); A.snd_strerror.restype = C.c_char_p
def ok(rc, what):
    if rc < 0: raise SystemExit(f"{what}: {A.snd_strerror(rc).decode()}")
    return rc
pcm = C.c_void_p(); ok(A.snd_pcm_open(C.byref(pcm), sys.argv[1].encode(), 1, 0), "open")
hw = C.c_void_p(); A.snd_pcm_hw_params_malloc(C.byref(hw)); ok(A.snd_pcm_hw_params_any(pcm, hw), "any")
ok(A.snd_pcm_hw_params_set_access(pcm, hw, 3), "access"); ok(A.snd_pcm_hw_params_set_format(pcm, hw, 2), "format")  # S16_LE
rate = C.c_uint(48000); ok(A.snd_pcm_hw_params_set_rate_near(pcm, hw, C.byref(rate), None), "rate")
ok(A.snd_pcm_hw_params_set_channels(pcm, hw, 2), "channels")
pt = C.c_uint(25_000); bt = C.c_uint(100_000)
A.snd_pcm_hw_params_set_period_time_near(pcm, hw, C.byref(pt), None); A.snd_pcm_hw_params_set_buffer_time_near(pcm, hw, C.byref(bt), None)
ok(A.snd_pcm_hw_params(pcm, hw), "hw_params"); ok(A.snd_pcm_prepare(pcm), "prepare"); ok(A.snd_pcm_start(pcm), "start")
buf = C.create_string_buffer(1200 * 4); frames = []; t_start = time.time()
def read(seconds):
    end = time.time() + seconds
    while time.time() < end:
        got = ok(A.snd_pcm_readi(pcm, buf, 1200), "readi")
        frames.extend(struct.unpack(f"<{got*2}h", buf.raw[:got * 4])[::2])
read(1.5); n1 = len(frames); time.sleep(float(sys.argv[2])); read(float(sys.argv[3]) if len(sys.argv) > 3 else 2.0)
elapsed = time.time() - t_start
breaks = sum(1 for a, b in zip(frames, frames[1:]) if (b - a) % 65536 != 1)
print(f"{len(frames)} frames in {elapsed:.1f}s = {len(frames)/elapsed:.0f}/s ({n1} before the stall); breaks in the count: {breaks}")
