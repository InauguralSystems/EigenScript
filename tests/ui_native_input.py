#!/usr/bin/env python3
"""Drive only an owned private Xvfb window; retain real input and pixel evidence."""
import argparse
import ctypes
import ctypes.util
import json
import os
from pathlib import Path
import resource
import selectors
import signal
import subprocess
import time


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def close_window(display, window):
    # The standard X11 WM_DELETE_WINDOW protocol enters SDL through its native
    # event pump, unlike SDL_PushEvent (covered separately by ui_sdl_input.c).
    x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
    class Data(ctypes.Union):
        _fields_ = [("b", ctypes.c_char * 20), ("s", ctypes.c_short * 10),
                    ("l", ctypes.c_long * 5)]
    class Client(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong),
                    ("send_event", ctypes.c_int), ("display", ctypes.c_void_p),
                    ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                    ("format", ctypes.c_int), ("data", Data)]
    class Event(ctypes.Union):
        _fields_ = [("client", Client), ("pad", ctypes.c_long * 24)]
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_long, ctypes.POINTER(Event)]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    conn = x11.XOpenDisplay(display.encode())
    require(conn, "open owned X display")
    try:
        event = Event()
        event.client.type = 33  # ClientMessage
        event.client.display = conn
        event.client.window = window
        event.client.message_type = x11.XInternAtom(conn, b"WM_PROTOCOLS", 0)
        event.client.format = 32
        event.client.data.l[0] = x11.XInternAtom(conn, b"WM_DELETE_WINDOW", 0)
        event.client.data.l[1] = 0  # CurrentTime
        require(x11.XSendEvent(conn, window, 0, 0, ctypes.byref(event)),
                "send native close to owned window")
        x11.XFlush(conn)
    finally:
        x11.XCloseDisplay(conn)


def stop_owned(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    else:
        process.wait()


def run(binary, output):
    from PIL import ImageChops, ImageGrab
    root = Path(__file__).resolve().parents[1]
    binary = binary.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # gfx on this machine reserves ordinary memory; enforce the project cap
    # before launching any display or app child. This leg uses release only.
    cap = 1500000 * 1024
    soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    resource.setrlimit(resource.RLIMIT_AS, (min(soft, cap) if soft >= 0 else cap, hard))
    deadline = time.monotonic() + 40
    env = os.environ.copy()
    env.update(SDL_VIDEODRIVER="x11", SDL_RENDER_DRIVER="software",
               SDL_AUDIODRIVER="dummy")
    server = app = None
    reader, writer = os.pipe()
    try:
        with (output / "xvfb.stderr").open("wb") as stderr:
            server = subprocess.Popen(["Xvfb", "-displayfd", str(writer),
                "-screen", "0", "800x600x24", "-nolisten", "tcp", "-ac"],
                pass_fds=(writer,), stdout=subprocess.DEVNULL, stderr=stderr)
        os.close(writer)
        writer = None
        with selectors.DefaultSelector() as selector:
            selector.register(reader, selectors.EVENT_READ)
            require(selector.select(timeout=5), "private X display startup deadline")
            number = os.read(reader, 32).decode().strip()
        require(number.isdecimal(), "private X display number")
        env["DISPLAY"] = ":" + number
        def command(*args, check=True):
            remaining = min(4, deadline - time.monotonic())
            require(remaining > 0, "native driver deadline")
            return subprocess.run(args, env=env, capture_output=True, text=True,
                                  check=check, timeout=remaining)
        def drive(*args):
            return command("xdotool", *map(str, args))
        log = output / "app.stdout"
        with log.open("wb") as stdout, (output / "app.stderr").open("wb") as stderr:
            app = subprocess.Popen([str(binary), "tests/ui_native_input.eigs"],
                                   cwd=root, env=env, stdout=stdout, stderr=stderr)
        def records():
            return [json.loads(line) for line in log.read_text().splitlines()
                    if line.startswith('{"')]
        def wait_for(predicate, label):
            limit = min(deadline, time.monotonic() + 5)
            while time.monotonic() < limit:
                if predicate():
                    return
                require(app.poll() is None, "app exited before " + label)
                require(server.poll() is None, "X server exited before " + label)
                time.sleep(.025)
            raise AssertionError("deadline waiting for " + label)
        wait_for(lambda: "UI_NATIVE_READY" in log.read_text(), "app readiness")
        found = command("xdotool", "search", "--onlyvisible", "--all", "--pid",
                        str(app.pid), "--name", "^ui-native-1263$")
        windows = found.stdout.split()
        require(len(windows) == 1, "exactly one owned app window")
        window = int(windows[0])
        drive("windowmove", window, 0, 0)
        drive("windowfocus", "--sync", window)
        def event(expected, after=0):
            return any(all(row["event"].get(k) == v for k, v in expected.items())
                       for row in records()[after:])
        mods = dict(shift=0, ctrl=0, alt=0)
        def motion(x, y):
            start = len(records())
            drive("mousemove", "--sync", "--window", window, x, y)
            wait_for(lambda: event(dict(type="mousemove", x=x, y=y, **mods), start),
                     "decoded pointer position")
        motion(40, 40)
        before = ImageGrab.grab(xdisplay=env["DISPLAY"])
        before.save(output / "before.png")
        start = len(records())
        drive("mousedown", 1)
        wait_for(lambda: event(dict(type="mousedown", button=1, x=40, y=40, **mods), start),
                 "native button down")
        for x in (70, 100, 130, 160, 190):
            motion(x, 40)
        drive("mouseup", 1)
        wait_for(lambda: event(dict(type="mouseup", button=1, x=190, y=40, **mods), start),
                 "native button up")
        wait_for(lambda: any(row["slider"] > 75 for row in records()[start:]),
                 "slider state changed through dispatch")
        after = ImageGrab.grab(xdisplay=env["DISPLAY"])
        after.save(output / "after-drag.png")
        changed = ImageChops.difference(before, after).crop((20, 30, 221, 55))
        require(changed.getbbox() is not None, "native drag changes slider pixels")
        changed_pixels = sum(pixel != (0, 0, 0) for pixel in changed.convert("RGB").getdata())
        require(changed_pixels > 100, "native drag paints a visible slider change")
        start = len(records())
        drive("keydown", "shift", "ctrl", "alt")
        drive("key", "a")
        for kind in ("keydown", "keyup"):
            wait_for(lambda kind=kind: event(dict(type=kind, key="a", scancode=4,
                     shift=1, ctrl=1, alt=1), start), kind + " native modifiers")
        mods = dict(shift=1, ctrl=1, alt=1)
        motion(180, 80)
        start = len(records())
        drive("click", 3)
        for kind in ("mousedown", "mouseup"):
            wait_for(lambda kind=kind: event(dict(type=kind, button=3, x=180, y=80,
                     **mods), start), kind + " pointer modifiers")
        for button, dx, dy in ((4, 0, 1), (6, -1, 0)):
            start = len(records())
            drive("click", button)
            wait_for(lambda: event(dict(type="wheel", x=dx, y=dy, mx=180, my=80,
                                      **mods), start), "wheel deltas/pointer/modifiers")
        drive("keyup", "alt", "ctrl", "shift")
        start = len(records())
        drive("windowsize", "--sync", window, 400, 280)
        wait_for(lambda: event(dict(type="resize", w=400, h=280), start), "native resize")
        ImageGrab.grab(xdisplay=env["DISPLAY"]).save(output / "after-resize.png")
        close_window(env["DISPLAY"], window)
        app.wait(timeout=min(5, max(.1, deadline - time.monotonic())))
        require(app.returncode == 0, "native app exit is zero")
        require(event(dict(type="quit")), "native close reaches gfx_poll")
        require("UI_NATIVE_CLOSED" in log.read_text(), "native close releases app")
        require(not (output / "app.stderr").read_text().strip(), "native app stderr empty")
        receipt = dict(display=env["DISPLAY"], app_pid=app.pid, window=window,
                       event_count=len(records()), changed_slider_pixels=changed_pixels,
                       app_exit=app.returncode)
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("ui native input: keydown/keyup/motion/buttons/wheel/resize/quit and slider pixels PASS")
    finally:
        if writer is not None:
            os.close(writer)
        os.close(reader)
        stop_owned(app)
        stop_owned(server)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.binary, args.output)
