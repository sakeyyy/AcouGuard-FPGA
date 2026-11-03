"""Portable log-mel features shared by FSD50K training and inference."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
import json
import wave

import numpy as np


@dataclass(frozen=True)
class FeatureConfig:
    sample_rate: int = 16000
    frame_length: int = 400
    hop_length: int = 160
    fft_size: int = 512
    mel_bins: int = 40
    low_hz: float = 50.0
    high_hz: float = 7600.0
    clip_seconds: float = 2.0
    pooling: str = "mean_std_max_delta"

    @property
    def clip_samples(self) -> int:
        return int(round(self.sample_rate * self.clip_seconds))

    @property
    def feature_size(self) -> int:
        if self.pooling == "mean":
            return self.mel_bins
        if self.pooling == "mean_std_max_delta":
            return self.mel_bins * 4
        raise ValueError(f"Unsupported pooling mode: {self.pooling}")


def config_to_json(config: FeatureConfig) -> str:
    return json.dumps(asdict(config), ensure_ascii=True)


def config_from_json(value: str) -> FeatureConfig:
    return FeatureConfig(**json.loads(value))


def save_config(config: FeatureConfig, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(config), indent=2), encoding="utf-8")


def _pcm_bytes_to_float(raw: bytes, sample_width: int) -> np.ndarray:
    if sample_width == 1:
        return (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    if sample_width == 2:
        return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if sample_width == 4:
        return np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    raise ValueError(f"Unsupported PCM sample width: {sample_width} bytes")


def normalize_samples(samples: np.ndarray) -> np.ndarray:
    samples = np.asarray(samples)
    if np.issubdtype(samples.dtype, np.integer):
        info = np.iinfo(samples.dtype)
        samples = samples.astype(np.float32) / float(max(abs(info.min), info.max))
    else:
        samples = samples.astype(np.float32)
    if samples.ndim == 2:
        samples = samples.mean(axis=1)
    if samples.size:
        samples -= float(np.mean(samples))
        peak = float(np.max(np.abs(samples)))
        if peak > 1.0:
            samples /= peak
    return samples.astype(np.float32, copy=False)


def resample_audio(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return samples.astype(np.float32, copy=False)
    try:
        from scipy.signal import resample_poly

        gcd = int(np.gcd(source_rate, target_rate))
        return resample_poly(
            samples,
            target_rate // gcd,
            source_rate // gcd,
        ).astype(np.float32)
    except ImportError:
        target_length = int(round(samples.size * target_rate / source_rate))
        if target_length < 1 or samples.size < 1:
            return np.zeros(max(0, target_length), dtype=np.float32)
        source_positions = np.arange(samples.size, dtype=np.float64)
        target_positions = np.linspace(0, samples.size - 1, target_length)
        return np.interp(target_positions, source_positions, samples).astype(np.float32)


def read_wav(path: Path, target_rate: int | None = None) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as wav_file:
        channels = wav_file.getnchannels()
        sample_width = wav_file.getsampwidth()
        source_rate = wav_file.getframerate()
        frame_count = wav_file.getnframes()
        raw = wav_file.readframes(frame_count)
    samples = _pcm_bytes_to_float(raw, sample_width)
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    samples = normalize_samples(samples)
    if target_rate is not None and target_rate != source_rate:
        samples = resample_audio(samples, source_rate, target_rate)
        return target_rate, samples
    return source_rate, samples


def fit_window(samples: np.ndarray, config: FeatureConfig, start: int = 0) -> np.ndarray:
    target = config.clip_samples
    start = max(0, min(int(start), max(0, samples.size - 1)))
    window = samples[start:start + target]
    if window.size < target:
        window = np.pad(window, (0, target - window.size))
    return window.astype(np.float32, copy=False)


def split_windows(
    samples: np.ndarray,
    config: FeatureConfig,
    max_windows: int = 1,
) -> list[np.ndarray]:
    if max_windows < 1:
        raise ValueError("max_windows must be at least 1")
    if samples.size <= config.clip_samples:
        return [fit_window(samples, config)]
    max_start = samples.size - config.clip_samples
    available = max(1, int(np.ceil(samples.size / config.clip_samples)))
    count = min(max_windows, available)
    starts = np.linspace(0, max_start, num=count, dtype=np.int64)
    return [fit_window(samples, config, int(start)) for start in np.unique(starts)]


def _hz_to_mel(frequency: np.ndarray | float) -> np.ndarray:
    return 2595.0 * np.log10(1.0 + np.asarray(frequency) / 700.0)


def _mel_to_hz(mel: np.ndarray) -> np.ndarray:
    return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)


def mel_filterbank(config: FeatureConfig) -> np.ndarray:
    mel_points = np.linspace(
        float(_hz_to_mel(config.low_hz)),
        float(_hz_to_mel(config.high_hz)),
        config.mel_bins + 2,
    )
    hz_points = _mel_to_hz(mel_points)
    bins = np.floor((config.fft_size + 1) * hz_points / config.sample_rate).astype(int)
    filters = np.zeros((config.mel_bins, config.fft_size // 2 + 1), dtype=np.float32)
    for index in range(config.mel_bins):
        left, center, right = bins[index:index + 3]
        center = max(center, left + 1)
        right = max(right, center + 1)
        left = min(left, filters.shape[1] - 1)
        center = min(center, filters.shape[1])
        right = min(right, filters.shape[1])
        if center > left:
            filters[index, left:center] = (
                np.arange(left, center) - left
            ) / (center - left)
        if right > center:
            filters[index, center:right] = (
                right - np.arange(center, right)
            ) / (right - center)
    return filters


def log_mel_spectrogram(samples: np.ndarray, config: FeatureConfig) -> np.ndarray:
    if samples.size < config.frame_length:
        samples = np.pad(samples, (0, config.frame_length - samples.size))
    frames = np.lib.stride_tricks.sliding_window_view(
        samples,
        config.frame_length,
    )[::config.hop_length]
    window = np.hanning(config.frame_length).astype(np.float32)
    spectrum = np.fft.rfft(frames * window, n=config.fft_size, axis=1)
    power = (np.abs(spectrum) ** 2).astype(np.float32)
    energies = power @ mel_filterbank(config).T
    return np.log(np.maximum(energies, 1e-10)).astype(np.float32)


def extract_samples(samples: np.ndarray, config: FeatureConfig) -> np.ndarray:
    log_mel = log_mel_spectrogram(normalize_samples(samples), config)
    if config.pooling == "mean":
        return log_mel.mean(axis=0).astype(np.float32)
    if config.pooling == "mean_std_max_delta":
        delta = np.diff(log_mel, axis=0)
        delta_abs_mean = (
            np.mean(np.abs(delta), axis=0)
            if delta.size
            else np.zeros(config.mel_bins, dtype=np.float32)
        )
        return np.concatenate([
            np.mean(log_mel, axis=0),
            np.std(log_mel, axis=0),
            np.max(log_mel, axis=0),
            delta_abs_mean,
        ]).astype(np.float32)
    raise ValueError(f"Unsupported pooling mode: {config.pooling}")


def extract_file_windows(
    path: Path,
    config: FeatureConfig,
    max_windows: int = 1,
) -> np.ndarray:
    _, samples = read_wav(path, target_rate=config.sample_rate)
    return np.vstack([
        extract_samples(window, config)
        for window in split_windows(samples, config, max_windows=max_windows)
    ])
