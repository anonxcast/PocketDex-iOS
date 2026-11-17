#!/usr/bin/env python3
"""PC gate: Exit Completely must not block main before leaving PlayView.

Fails the build if quitSession / Exit button regress into sync pk_ios_* /
AVAudioEngine.stop on the Exit turn.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "ios/Sources/EmulatorEngine.swift"
PLAY = ROOT / "ios/Sources/PlayView.swift"
AUDIO = ROOT / "ios/Sources/EmulatorAudio.swift"
APP = ROOT / "ios/Sources/PocketDexApp.swift"

errors: list[str] = []


def func_body(src: str, name: str) -> str:
    m = re.search(rf"func {re.escape(name)}\([^\)]*\)[^{{]*\{{", src)
    if not m:
        errors.append(f"missing func {name}")
        return ""
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    errors.append(f"unbalanced body for {name}")
    return ""


def main() -> int:
    engine = ENGINE.read_text()
    play = PLAY.read_text()
    audio = AUDIO.read_text()
    app = APP.read_text()

    begin = func_body(engine, "beginQuit")
    finish = func_body(engine, "finishQuit")
    if not begin:
        errors.append("missing beginQuit() — Exit must halt without @Published churn")
    if not finish:
        errors.append("missing finishQuit() — teardown after PlayView leaves")
    if begin:
        if "pk_ios_" in begin:
            errors.append("beginQuit must not call pk_ios_*")
        if re.search(r"audio\.stop\s*\(", begin):
            errors.append("beginQuit must not call audio.stop()")
        if "tearDownSessionUI" in begin:
            errors.append("beginQuit must not tearDownSessionUI (publishes during nav pop)")
        if "isRunning" in begin or "loadedRomKey" in begin:
            errors.append("beginQuit must not assign @Published isRunning/loadedRomKey")
        if "audio.mute()" not in begin:
            errors.append("beginQuit should mute() audio")
    if finish and "tearDownSessionUI" not in finish:
        errors.append("finishQuit should call tearDownSessionUI")

    # Exit button: beginQuit → onLeave → finishQuit (async)
    if "Exit Completely" not in play:
        errors.append("PlayView missing Exit Completely button")
    if "beginQuit()" not in play or "finishQuit()" not in play:
        errors.append("Exit Completely must use beginQuit/finishQuit")
    # onLeave may be via leaveWithFade() (fade → unanimated pop).
    if not re.search(
        r"Exit Completely[\s\S]{0,800}(onLeave\(\)|leaveWithFade)",
        play,
    ):
        errors.append("Exit Completely must call onLeave() / leaveWithFade to pop NavigationPath")
    if "leaveWithFade" in play and "onLeave()" not in func_body(play, "leaveWithFade"):
        errors.append("leaveWithFade must call onLeave()")
    if "disablesAnimations" not in play and "disablesAnimations" not in app:
        errors.append("Exit nav pop must disable animations (AG hang during parallax)")
    if "path.removeLast()" not in app:
        errors.append("PocketDexApp must pass onLeave that pops path")

    # Audio.stop must defer tearDownEngine.
    stop_body = func_body(audio, "stop")
    if "tearDownEngine()" in stop_body and "DispatchQueue.main.async" not in stop_body:
        errors.append("EmulatorAudio.stop() must not tearDownEngine inline")
    # Strip comments before scanning for setActive(false).
    audio_code = re.sub(r"//.*?$", "", audio, flags=re.M)
    audio_code = re.sub(r"/\*.*?\*/", "", audio_code, flags=re.S)
    if re.search(r"setActive\s*\(\s*false", audio_code):
        errors.append("EmulatorAudio must not call setActive(false) (known hang)")

    mute_body = func_body(audio, "mute")
    if not mute_body:
        errors.append("EmulatorAudio.mute() missing")
    elif "tearDownEngine" in mute_body or "engine.stop" in mute_body:
        errors.append("mute() must not stop AVAudioEngine")

    if errors:
        print("verify_quit_invariants: FAIL")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("verify_quit_invariants: OK")
    print("  - quitSession sync path has no pk_ios_*/audio.stop/tearDownSessionUI")
    print("  - Exit Completely uses onLeave → path.removeLast()")
    print("  - EmulatorAudio.stop() defers tearDown; mute() is silent-only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
