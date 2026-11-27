#!/usr/bin/env python3
"""Does a stalled reader break voice capture on this ALSA device? Mimics the capture setup and worker
loop of cpal 0.15.3 (src/host/alsa/mod.rs), the library Claude Code 2.1.332 records with: 100 ms
buffer, poll, and on POLLERR report and poll again with no recovery. Then it stops reading for
STALL_SECONDS and counts what poll() says afterwards.

    test-capture-stall.py PCM STALL_SECONDS      e.g.  plughw:0,3 0.3    or    pulse 2

Measured 2026-11-26: a raw device (plughw) after a 0.3 s stall is in XRUN and returns POLLERR on
every poll, 600,000+ times a second - in Claude Code each one prints "Audio capture error ...
POLLERR" over the screen, and that flood dropped the container tab. Through PulseAudio (PCM "pulse")
stalls of 0.3, 2 and 6 s gave no POLLERR and the backlog was read afterwards. Use a capture device
that is not the microphone in use (hw devices are exclusive); for "pulse", PULSE_SOURCE picks one."""
import ctypes as C, select, sys, time
A = C.CDLL("libasound.so.2")
pcm_name, stall = sys.argv[1], float(sys.argv[2])
def ok(rc, what):
    if rc < 0: raise SystemExit(f"{what}: {A.snd_strerror(rc)}")
    return rc
A.snd_strerror.restype = C.c_char_p
pcm = C.c_void_p()
ok(A.snd_pcm_open(C.byref(pcm), pcm_name.encode(), 1, 0), "open")          # 1 = CAPTURE
hw = C.c_void_p(); A.snd_pcm_hw_params_malloc(C.byref(hw))
ok(A.snd_pcm_hw_params_any(pcm, hw), "any")
ok(A.snd_pcm_hw_params_set_access(pcm, hw, 3), "access")                  # RW_INTERLEAVED
ok(A.snd_pcm_hw_params_set_format(pcm, hw, 10), "format")                 # S32_LE
rate = C.c_uint(48000); ok(A.snd_pcm_hw_params_set_rate_near(pcm, hw, C.byref(rate), None), "rate")
ok(A.snd_pcm_hw_params_set_channels(pcm, hw, 2), "channels")
pt = C.c_uint(25_000); bt = C.c_uint(100_000)                             # cpal's BufferSize::Default
ok(A.snd_pcm_hw_params_set_period_time_near(pcm, hw, C.byref(pt), None), "period")
ok(A.snd_pcm_hw_params_set_buffer_time_near(pcm, hw, C.byref(bt), None), "buffer")
ok(A.snd_pcm_hw_params(pcm, hw), "hw_params")
buf = C.c_ulong(); per = C.c_ulong()
A.snd_pcm_hw_params_get_buffer_size(hw, C.byref(buf)); A.snd_pcm_hw_params_get_period_size(hw, C.byref(per), None)
print(f"{pcm_name}: buffer {buf.value} frames = {buf.value/rate.value*1000:.0f} ms, period {per.value}")
ok(A.snd_pcm_prepare(pcm), "prepare"); ok(A.snd_pcm_start(pcm), "start")
n = A.snd_pcm_poll_descriptors_count(pcm)
class PFD(C.Structure): _fields_ = [("fd", C.c_int), ("events", C.c_short), ("revents", C.c_short)]
fds = (PFD * n)(); A.snd_pcm_poll_descriptors(pcm, fds, n)
libc = C.CDLL("libc.so.6")
data = C.create_string_buffer(buf.value * 8)
def loop(seconds):
    """cpal's loop: poll, translate revents, POLLERR -> report and poll again (no recovery)."""
    errs = reads = 0; end = time.time() + seconds
    while time.time() < end:
        libc.poll(fds, n, 100)
        rev = C.c_ushort(); A.snd_pcm_poll_descriptors_revents(pcm, fds, n, C.byref(rev))
        if rev.value & select.POLLERR: errs += 1; continue
        if rev.value & select.POLLIN:
            got = A.snd_pcm_readi(pcm, data, per.value)
            if got > 0: reads += 1
    return errs, reads
e, r = loop(1.0); print(f"1 s reading normally:        {e} POLLERR, {r} reads")
time.sleep(stall)
e, r = loop(1.0); print(f"1 s after a {stall*1000:.0f} ms stall:    {e} POLLERR, {r} reads   state={A.snd_pcm_state(pcm)} (3=RUNNING 4=XRUN)")
