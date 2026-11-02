#!/bin/sh
# Create a virtual evdev keyboard and send Bluetooth-page-turner key codes to it.
#
# This is a *development smoke test* for the pager takeover (spec A/B), for a
# desktop or the KOReader emulator. It is not used on a device, where the real
# pager arrives over Bluetooth.
#
# Usage:
#   tools/pager_fake.sh            # create, send next/prev/scroll, destroy
#   tools/pager_fake.sh next       # send one key
#   tools/pager_fake.sh cycle      # create/send/destroy/recreate/send (self-heal)
#
# Needs write access to /dev/uinput (usually root). Keys used:
#   104 PageUp (prev), 109 PageDown (next), 70 ScrollLock
set -e

if [ ! -e /dev/uinput ]; then
    echo "no /dev/uinput on this machine; run this on a desktop, not on the device" >&2
    exit 1
fi

exec python3 - "$@" <<'PY'
import fcntl, os, struct, sys, time

EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565

KEYS = {"prev": 104, "next": 109, "scroll": 70}

def open_device():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in range(1, 128):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    # struct uinput_user_dev: name[80], input_id{4x uint16}, ff_effects_max,
    # absmax[64], absmin[64], absfuzz[64], absflat[64] (all int32).
    name = b"Kamare Fake Pager".ljust(80, b"\0")
    desc = name + struct.pack("<4HI", 0x0005, 0x0001, 0x0001, 0x0001, 0)
    desc += b"\0" * (4 * 64 * 4)
    os.write(fd, desc)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd

def send(fd, code):
    # struct input_event: timeval (two longs) + type u16 + code u16 + value s32
    fmt = "llHHi"
    now = time.time()
    ev = struct.pack(fmt, int(now), int((now % 1) * 1000000), EV_KEY, code, 1)
    ev += struct.pack(fmt, 0, 0, EV_SYN, SYN_REPORT, 0)
    os.write(fd, ev)
    time.sleep(0.05)
    ev = struct.pack(fmt, 0, 0, EV_KEY, code, 0)
    ev += struct.pack(fmt, 0, 0, EV_SYN, SYN_REPORT, 0)
    os.write(fd, ev)

def close_device(fd):
    try:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
    finally:
        os.close(fd)

steps = sys.argv[1:] or ["next", "prev", "scroll"]

if steps == ["cycle"]:
    fd = open_device()
    time.sleep(1.5)
    send(fd, KEYS["next"])
    time.sleep(1.0)
    close_device(fd)
    print("destroyed; waiting for the self-heal rescan...", flush=True)
    time.sleep(12)
    fd = open_device()
    time.sleep(1.5)
    send(fd, KEYS["next"])
    time.sleep(1.0)
    close_device(fd)
else:
    fd = open_device()
    # Give KOReader a moment to notice the new input device.
    time.sleep(1.5)
    for step in steps:
        code = KEYS.get(step)
        if code is None:
            sys.exit("unknown key %r (use next/prev/scroll/cycle)" % step)
        send(fd, code)
        time.sleep(0.6)
    close_device(fd)

print("done")
PY
