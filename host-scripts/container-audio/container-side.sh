#!/bin/sh
# container-audio, container end. Run by launch-container as root inside the container on every launch
# and attach:  container-side.sh <container name> <run-as user>
# Idempotent. Starts (as the user) a private PulseAudio whose only microphone, "hostmic", reads the
# host's pipe through a blocking relay, then points ALSA's default capture at it. Playback stays on the
# raw device. If anything is missing or no audio arrives, ALSA stays on the raw device as before, so
# voice works the old way. Design and measurements: CLAUDE.md beside this script.
set -u
NAME="$1"; USER_="${2:-agent}"
HOSTFIFO="/host-scripts/container-audio/pipes/$NAME.fifo"
RUN=/tmp/container-audio
SOCK="unix:$RUN/native"
CONF=/etc/asound.conf
RAW=/etc/asound.conf.raw

say() { echo ">> container-audio: $*"; }
raw_back() {   # leave (or put back) the raw-device config
  [ -f "$RAW" ] && ! cmp -s "$RAW" "$CONF" && cp "$RAW" "$CONF" && say "ALSA back on the raw device ($1)."
  [ -f "$RAW" ] || say "not enabled ($1); voice uses the raw device."
  exit 0
}

[ -p "$HOSTFIFO" ] || raw_back "no host pipe $HOSTFIFO: is the host's container-audio service installed?"
# The host opens the mic only while space is held, as spacebar-watch reports; without it voice would
# record silence forever, so stay on the raw device.
[ -s "$(getent passwd "$USER_" | cut -d: -f6)/.claude/voice-corrections/spacebar" ] \
  || raw_back "no space-bar state (spacebar-watch not installed on the host: fix-voice-corrections.sh)"
command -v pulseaudio >/dev/null 2>&1 && command -v parec >/dev/null 2>&1 \
  && [ -e /usr/lib/x86_64-linux-gnu/alsa-lib/libasound_module_pcm_pulse.so ] \
  || raw_back "packages pulseaudio pulseaudio-utils libasound2-plugins not installed"

mkdir -p "$RUN" /etc/pulse/client.conf.d && chown "$USER_" "$RUN" && chmod 700 "$RUN"
# No autospawn: a client must never start a second, default-configured daemon.
printf 'autospawn = no\n' > /etc/pulse/client.conf.d/container-audio.conf

as_user() { su -s /bin/sh "$USER_" -c "$1"; }

# alive <pidfile> <word>: the process is running AND is ours (after a container restart a pid file can
# name some other process).
alive() { [ -s "$RUN/$1" ] && grep -q "$2" "/proc/$(cat "$RUN/$1")/cmdline" 2>/dev/null; }

if ! as_user "pactl -s $SOCK info >/dev/null 2>&1"; then
  # A pipe left by an earlier run makes module-pipe-source refuse to load ("mkfifo: File exists").
  rm -f "$RUN/mic.fifo" "$RUN/native"
  as_user "PULSE_RUNTIME_PATH=$RUN HOME=$RUN pulseaudio -n --daemonize=yes --exit-idle-time=-1 \
    --log-target=file:$RUN/pulseaudio.log \
    -L 'module-native-protocol-unix socket=$RUN/native auth-anonymous=1' \
    -L 'module-pipe-source file=$RUN/mic.fifo source_name=hostmic format=s16le rate=48000 channels=2' \
    -L 'module-null-sink sink_name=unused'" \
    || raw_back "PulseAudio did not start (see $RUN/pulseaudio.log)"
  i=0; until as_user "pactl -s $SOCK info >/dev/null 2>&1"; do i=$((i+1)); [ $i -ge 30 ] && raw_back "PulseAudio did not come up"; sleep 0.2; done
  as_user "pactl -s $SOCK set-default-source hostmic >/dev/null"
fi
# The relay: a plain blocking copy, so the container never runs its own audio clock. It loops because
# it ends whenever the host side closes the pipe (feeder restart).
if ! alive relay.pid "$NAME.fifo"; then
  as_user "nohup sh -c 'while :; do cat \"$HOSTFIFO\" > \"$RUN/mic.fifo\"; sleep 1; done' >/dev/null 2>&1 & echo \$! > $RUN/relay.pid"
fi

# The drain: a listener that is always there. PulseAudio's pipe source stops reading while no one records,
# so the pipes filled with seconds of old audio and every recording began with it (2026-11-26: a 3 s
# recording returned in 0.03 s, twice in a row; back-to-back dictations would start with the end of the
# last one). With this, the source always reads and a recording starts live.
if ! alive drain.pid hostmic; then
  as_user "nohup sh -c 'while :; do parec -s $SOCK -d hostmic --raw --format=s16le --rate=8000 --channels=1 --latency-msec=200 > /dev/null 2>&1; sleep 1; done' >/dev/null 2>&1 & echo \$! > $RUN/drain.pid"
fi

# Audio arriving? The host sends silence when not dictating, so 0.5 s of stream must turn up within 3 s.
got=$(as_user "timeout 3 parec -s $SOCK -d hostmic --raw --format=s16le --rate=48000 --channels=2 2>/dev/null | head -c 96000 | wc -c")
[ "${got:-0}" -ge 96000 ] || raw_back "no audio from the host pipe (got ${got:-0} bytes; is the host service running?)"

[ -f "$RAW" ] || cp "$CONF" "$RAW" 2>/dev/null || : > "$RAW"
playback=$(sed -n 's/^ *playback\.pcm *"\(.*\)"/\1/p' "$RAW" | head -1)
cat > "$CONF.new" <<EOF
# Written by container-audio/container-side.sh (launch-container). Capture goes through the host's
# one-way pipe (hostmic) so a stalled recording thread can't overrun the device; playback stays on the
# raw device. The previous config is $RAW.
pcm.hostmic {
    type pulse
    server "$SOCK"
    device "hostmic"
}
pcm.!default {
    type asym
    playback.pcm "${playback:-plughw:0,2}"
    capture.pcm "hostmic"
}
ctl.!default {
    type hw
    card 0
}
EOF
if cmp -s "$CONF.new" "$CONF"; then rm -f "$CONF.new"; else mv "$CONF.new" "$CONF"; say "voice now records through the host pipe (no more POLLERR floods)."; fi
