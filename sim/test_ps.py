"""Numerical/state regression of the shipped C sources; optional full ARM link."""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import _ctypes

import numpy as np
from scipy.fft import dct
from scipy.signal import resample

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/vitis/audio_ps_ws/hearing_mlp/src"


def reference_mfcc(samples):
    points = 700 * (10 ** (np.linspace(2595 * np.log10(1 + 300 / 700),
                                      2595 * np.log10(1 + 7600 / 700), 28) / 2595) - 1)
    hz = np.arange(257) * 16000 / 512
    filters = np.array([np.maximum(0, np.minimum((hz - points[index]) /
                         (points[index + 1] - points[index]), (points[index + 2] - hz) /
                         (points[index + 2] - points[index + 1]))) for index in range(26)])
    emphasized = np.r_[samples[0], samples[1:] - .97 * samples[:-1]]
    frames = np.lib.stride_tricks.sliding_window_view(emphasized, 400)[::160]
    power = abs(np.fft.rfft(frames * np.hanning(400), 512)) ** 2
    cepstrum = dct(np.log(np.maximum(power @ filters.T, 1e-12)), norm="ortho", axis=1)[:, 1:13]
    cepstrum -= cepstrum.mean(axis=0)
    padded = np.pad(cepstrum, ((2, 2), (0, 0)), mode="edge")
    delta = ((padded[3:-1] - padded[1:-3]) + 2 * (padded[4:] - padded[:-4])) / 10
    return np.concatenate([cepstrum, delta], axis=1).astype(np.float32)


def reference_dtw(left, right):
    rows, cols = len(left), len(right)
    costs = np.full((rows + 1, cols + 1), 1e20)
    steps = np.zeros((rows + 1, cols + 1), int)
    costs[0, 0] = 0
    for row in range(1, rows + 1):
        for col in range(1, cols + 1):
            if abs(col - row * cols // rows) > cols // 3 + 8:
                continue
            previous = min([(row - 1, col - 1), (row - 1, col), (row, col - 1)],
                           key=lambda location: costs[location])
            costs[row, col] = costs[previous] + np.mean((left[row - 1] - right[col - 1]) ** 2)
            steps[row, col] = steps[previous] + 1
    return np.sqrt(costs[-1, -1] / steps[-1, -1])


def synthetic(formants):
    sections = []
    for frequency in formants:
        clock = np.arange(3200) / 16000
        section = sum(np.sin(2 * np.pi * frequency * harmonic * clock) / harmonic
                      for harmonic in (1, 2, 3)) * .04 * np.sin(np.pi * np.arange(3200) / 3200) ** .4
        sections.extend([section, np.zeros(640)])
    return np.concatenate(sections).astype(np.float32)


def execute(command, env, log):
    result = subprocess.run(list(map(str, command)), env=env, text=True, capture_output=True,
                            errors="replace", timeout=180)
    log.append("COMMAND " + repr(list(map(str, command))) + "\n" + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(log[-1])
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", type=Path, required=True)
    parser.add_argument("--arm", type=Path)
    args = parser.parse_args()
    output = ROOT / "sim/results"
    work = ROOT / "build/output"
    work.mkdir(parents=True, exist_ok=True)
    report = {"evidence": "host_c_numeric_and_synthetic_state_tests",
              "hardware_tested": False, "human_name_accuracy_tested": False, "passed": False,
              "utc": datetime.now(timezone.utc).isoformat(),
              "name_source_sha256": hashlib.sha256((SOURCE / "name_call.c").read_bytes()).hexdigest()}
    log = []
    env = os.environ.copy()
    env["PATH"] = str(args.cc.parent) + os.pathsep + env.get("PATH", "")
    try:
        with tempfile.TemporaryDirectory(prefix="ps_test_", dir=work) as temporary:
            temporary = Path(temporary)
            env.update(TEMP=str(temporary), TMP=str(temporary))
            library = temporary / "name_test.dll"
            execute([args.cc, "-shared", "-std=c99", "-O2", "-Wall", "-Wextra",
                     "-I" + str(SOURCE), SOURCE / "name_call.c", SOURCE / "kiss_fft.c",
                     ROOT / "sim/host/name_bridge.c", "-lm", "-static-libgcc", "-o", library], env, log)
            module = ctypes.CDLL(str(library))
            try:
                pointer = ctypes.POINTER(ctypes.c_float)
                module.test_log.restype = ctypes.c_char_p
                module.test_feed.argtypes = [pointer, ctypes.c_uint, ctypes.c_uint]
                module.nc_command.argtypes = [ctypes.c_char_p]
                module.nc_control_bits.restype = ctypes.c_uint32
                module.nc_mfcc.argtypes = [pointer, ctypes.c_uint, pointer]
                module.nc_dtw.argtypes = [pointer, ctypes.c_int, pointer, ctypes.c_int]
                module.nc_dtw.restype = ctypes.c_float
                def ptr(array):
                    return array.ctypes.data_as(pointer)
                def feed(array, channel=0):
                    array = np.ascontiguousarray(array, dtype=np.float32)
                    module.test_feed(ptr(array), len(array), channel)
                def command(text):
                    module.nc_command(text.encode("ascii"))
                def messages():
                    return module.test_log().decode("ascii")
                def phase():
                    return (module.nc_control_bits() >> 18) & 15
                def features(array):
                    result = np.empty((240, 24), np.float32)
                    count = module.nc_mfcc(ptr(array), len(array), ptr(result))
                    assert count > 0
                    return result[:count].copy()
                silence = np.zeros(16000, np.float32)
                module.test_reset()
                samples = (np.random.default_rng(42).normal(size=12000) * .01).astype(np.float32)
                actual = features(samples)
                expected = reference_mfcc(samples)
                error = float(np.max(abs(actual - expected)))
                assert error < .002, error
                report["mfcc_max_abs_error"] = error
                other = features(resample(samples, 10000).astype(np.float32))
                distance = module.nc_dtw(ptr(actual), len(actual), ptr(other), len(other))
                dtw_error = abs(float(distance) - reference_dtw(actual, other))
                assert dtw_error < 1e-4, dtw_error
                assert module.nc_dtw(ptr(actual), len(actual), ptr(actual), len(actual)) == 0
                report["dtw_abs_error"] = dtw_error
                module.test_reset()
                module.nc_key(0)
                assert module.nc_mode() == 0
                module.nc_dispatch_key()
                assert module.nc_mode() == 1
                module.nc_key(0)
                module.nc_dispatch_key()
                assert module.nc_mode() == 0
                module.nc_key(1)
                module.nc_dispatch_key()
                assert phase() == 1
                feed(np.zeros(32000, np.float32))
                assert phase() == 2
                feed(silence)
                target = synthetic([430, 720, 510])
                negative = synthetic([1200, 1550, 980])
                for index in range(6):
                    feed(target if index < 3 else negative)
                    feed(silence)
                    if index < 5:
                        feed(silence)
                        assert phase() == (2 if index < 2 else 4), (index, messages())
                assert module.nc_control_bits() & (1 << 17), messages()
                assert phase() == 7, messages()
                report["guided_enrollment_log"] = messages()
                module.test_clear_log()
                feed(target * .8)
                feed(silence)
                assert "NameAlert:" in messages(), messages()
                report["synthetic_target_log"] = messages()
                feed(silence)
                feed(silence)
                module.test_clear_log()
                feed(negative)
                feed(silence)
                assert "NameAlert:" not in messages(), messages()
                report["synthetic_negative_log"] = messages()
                command("MODE:123")
                assert module.nc_control_bits() == 0
                command("MODE:4")
                assert module.nc_control_bits() & (1 << 17)
                command("NAME:CLEAR")
                assert not module.nc_control_bits() & (1 << 17)
                command("NAME:POS")
                feed(np.zeros(160320, np.float32))
                assert "attempt_timeout_10s" in messages(), messages()
                assert not module.nc_control_bits() & (1 << 16)
                module.test_reset()
                command("NAME:POS")
                feed(np.tile(target, 5))
                assert "too_long_2p4s" in messages(), messages()
                assert not module.nc_control_bits() & (1 << 16)
                command("NAME:START")
                command("NAME:STOP")
                assert not module.nc_control_bits() & (1 << 16)
                command("NAME:POS")
                feed(np.array([np.nan], np.float32))
                assert "invalid_sample" in messages()
                report["state_tests"] = ["deferred_key", "long_key_wizard", "quiet_calibration",
                    "guided_three_positive_three_negative", "synthetic_target_match",
                    "synthetic_negative_rejection", "mode_switch_preserves_templates", "clear_templates",
                    "silent_attempt_timeout", "overlong_abort", "explicit_stop", "invalid_sample"]
                report["timeout_depends_on_audio_feed"] = True
            finally:
                _ctypes.FreeLibrary(module._handle)
            report["arm_compile_link_passed"] = False
            if args.arm:
                bsp = ROOT / "src/vitis/audio_ps_ws/audio_platform/export/audio_platform/sw/standalone_ps7_cortexa9_0"
                for name in ("include", "lib"):
                    shutil.copytree(bsp / name, temporary / name)
                shutil.copyfile(bsp / "Xilinx.spec", temporary / "Xilinx.spec")
                arm_env = dict(env)
                arm_env["PATH"] = os.pathsep.join([str(args.arm.parent),
                    str(args.arm.parent.parent / "x86_64-oesdk-mingw32/usr/bin"), env["PATH"]])
                objects = []
                for source in sorted(SOURCE.glob("*.c")):
                    obj = temporary / (source.stem + ".o")
                    execute([args.arm, "-std=c99", "-O2", "-DSDT", "-mcpu=cortex-a9", "-mfpu=vfpv3",
                             "-mfloat-abi=hard", "-Wall", "-Wextra", "-I" + str(SOURCE),
                             "-I" + str(temporary / "include"), "-c", source, "-o", obj], arm_env, log)
                    objects.append(obj)
                elf = temporary / "rebuilt.elf"
                execute([args.arm, "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard",
                    "-specs=" + str(temporary / "Xilinx.spec"), "-T", SOURCE / "lscript.ld",
                    "-L" + str(temporary / "lib"), *objects, "-Wl,--start-group",
                    "-lxilstandalone", "-lxiltimer", "-lxil", "-lgcc", "-lc", "-lm",
                    "-Wl,--end-group", "-o", elf], arm_env, log)
                report["arm_size_output"] = execute([args.arm.with_name("arm-none-eabi-size.exe"), elf], arm_env, log)
                report["arm_compile_link_passed"] = True
                report["arm_sources_compiled"] = len(objects)
                report["rebuilt_elf_sha256"] = hashlib.sha256(elf.read_bytes()).hexdigest()
            report["passed"] = True
    finally:
        output.mkdir(exist_ok=True)
        (output / "ps_regression.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        (output / "ps_build.log").write_text("\n".join(log), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
