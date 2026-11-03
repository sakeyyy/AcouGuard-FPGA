"""Sensitivity-oriented utilities shared by training and inference."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from fsd50k_audio_features import (
    FeatureConfig,
    extract_samples,
    fit_window,
    read_wav,
    split_windows,
)


HUMAN_LABELS = {
    "background": "\u666e\u901a\u73af\u5883\u58f0",
    "bicycle_bell": "\u81ea\u884c\u8f66\u94c3",
    "road_vehicle": "\u63a5\u8fd1\u6216\u7ecf\u8fc7\u8f66\u8f86",
    "car_horn": "\u6c7d\u8f66\u9e23\u7b1b",
    "siren_alarm": "\u8b66\u7b1b\u6216\u8b66\u62a5",
    "human_shout": "\u547c\u558a\u6216\u5c16\u53eb",
    "construction_tool": "\u65bd\u5de5\u5de5\u5177",
    "dog_bark": "\u72ac\u5420",
    "impact_emergency": "\u7206\u70b8\u3001\u67aa\u58f0\u6216\u788e\u88c2\u51b2\u51fb",
}


@dataclass(frozen=True)
class DetectionResult:
    label: str
    confidence: float
    threshold: float
    triggered: bool


def human_label(label: str) -> str:
    return HUMAN_LABELS.get(label, label)


def sliding_windows(
    samples: np.ndarray,
    config: FeatureConfig,
    hop_seconds: float = 0.5,
    max_windows: int = 0,
) -> list[np.ndarray]:
    """Return overlapping windows so short events are not averaged away."""
    if samples.size <= config.clip_samples:
        return [fit_window(samples, config)]
    hop_samples = max(1, int(round(hop_seconds * config.sample_rate)))
    last_start = samples.size - config.clip_samples
    starts = list(range(0, last_start + 1, hop_samples))
    if starts[-1] != last_start:
        starts.append(last_start)
    if max_windows > 0 and len(starts) > max_windows:
        indices = np.linspace(0, len(starts) - 1, max_windows, dtype=np.int64)
        starts = [starts[int(index)] for index in np.unique(indices)]
    return [fit_window(samples, config, start) for start in starts]


def augment_window(
    window: np.ndarray,
    sample_rate: int,
    generator: np.random.Generator,
) -> np.ndarray:
    """Apply gain, time shift, additive noise and a short time mask."""
    augmented = np.asarray(window, dtype=np.float32).copy()

    gain_db = float(generator.uniform(-8.0, 6.0))
    augmented *= 10.0 ** (gain_db / 20.0)

    maximum_shift = int(round(0.20 * sample_rate))
    shift = int(generator.integers(-maximum_shift, maximum_shift + 1))
    if shift > 0:
        augmented[shift:] = augmented[:-shift]
        augmented[:shift] = 0.0
    elif shift < 0:
        amount = -shift
        augmented[:-amount] = augmented[amount:]
        augmented[-amount:] = 0.0

    signal_rms = float(np.sqrt(np.mean(augmented * augmented) + 1e-12))
    snr_db = float(generator.uniform(12.0, 32.0))
    noise_rms = signal_rms / (10.0 ** (snr_db / 20.0))
    augmented += generator.normal(0.0, noise_rms, augmented.size).astype(np.float32)

    if generator.random() < 0.35:
        mask_length = int(generator.uniform(0.02, 0.12) * sample_rate)
        if 0 < mask_length < augmented.size:
            mask_start = int(generator.integers(0, augmented.size - mask_length + 1))
            augmented[mask_start:mask_start + mask_length] = 0.0

    peak = float(np.max(np.abs(augmented))) if augmented.size else 0.0
    if peak > 0.98:
        augmented *= 0.98 / peak
    return augmented.astype(np.float32, copy=False)


def extract_augmented_file(
    path: Path,
    config: FeatureConfig,
    max_windows: int,
    augmentations: int,
    seed: int,
) -> np.ndarray:
    _, samples = read_wav(path, target_rate=config.sample_rate)
    windows = split_windows(samples, config, max_windows=max_windows)
    generator = np.random.default_rng(seed)
    features: list[np.ndarray] = []
    for window in windows:
        features.append(extract_samples(window, config))
        for _ in range(augmentations):
            features.append(extract_samples(
                augment_window(window, config.sample_rate, generator),
                config,
            ))
    return np.vstack(features)


def extract_sliding_file(
    path: Path,
    config: FeatureConfig,
    hop_seconds: float,
    max_windows: int,
) -> np.ndarray:
    _, samples = read_wav(path, target_rate=config.sample_rate)
    return np.vstack([
        extract_samples(window, config)
        for window in sliding_windows(samples, config, hop_seconds, max_windows)
    ])


def aggregate_window_scores(
    probabilities: np.ndarray,
    classes: list[str] | np.ndarray,
    top_windows: int = 3,
) -> np.ndarray:
    """Use top-window means for hazards and mean score for background."""
    probabilities = np.asarray(probabilities, dtype=np.float64)
    if probabilities.ndim != 2:
        raise ValueError("probabilities must have shape [windows, classes]")
    classes_array = np.asarray(classes)
    result = np.zeros(probabilities.shape[1], dtype=np.float64)
    count = max(1, min(int(top_windows), probabilities.shape[0]))
    for index, label in enumerate(classes_array):
        values = probabilities[:, index]
        if str(label) == "background":
            result[index] = float(np.mean(values))
        else:
            result[index] = float(np.mean(np.partition(values, -count)[-count:]))
    return result


def calibrate_thresholds(
    expected: np.ndarray,
    scores: np.ndarray,
    classes: list[str] | np.ndarray,
    beta: float = 1.5,
    minimum_threshold: float = 0.18,
    maximum_threshold: float = 0.70,
    minimum_precision: float = 0.30,
) -> dict[str, float]:
    """Calibrate one-vs-rest thresholds, favoring recall via F-beta."""
    classes_array = np.asarray(classes)
    thresholds: dict[str, float] = {"background": 1.0}
    candidates = np.linspace(minimum_threshold, maximum_threshold, 105)
    beta_squared = beta * beta
    for class_index, class_value in enumerate(classes_array):
        label = str(class_value)
        if label == "background":
            continue
        truth = expected == label
        best_rank = (-1.0, -1.0, -1.0)
        best_threshold = 0.45
        fallback_rank = (-1.0, -1.0)
        fallback_threshold = best_threshold
        for threshold in candidates:
            detected = scores[:, class_index] >= threshold
            true_positive = int(np.sum(truth & detected))
            false_positive = int(np.sum(~truth & detected))
            false_negative = int(np.sum(truth & ~detected))
            precision = true_positive / max(1, true_positive + false_positive)
            recall = true_positive / max(1, true_positive + false_negative)
            denominator = beta_squared * precision + recall
            f_beta = (
                (1.0 + beta_squared) * precision * recall / denominator
                if denominator > 0.0
                else 0.0
            )
            fallback = (f_beta, recall)
            if fallback > fallback_rank:
                fallback_rank = fallback
                fallback_threshold = float(threshold)
            if precision >= minimum_precision:
                rank = (f_beta, recall, precision)
                if rank > best_rank:
                    best_rank = rank
                    best_threshold = float(threshold)
        thresholds[label] = (
            best_threshold if best_rank[0] >= 0.0 else fallback_threshold
        )
    return thresholds


def select_event(
    scores: np.ndarray,
    classes: list[str] | np.ndarray,
    thresholds: dict[str, float] | None = None,
    default_threshold: float = 0.45,
) -> DetectionResult:
    """Select the hazard with the strongest score-to-threshold ratio."""
    classes_array = np.asarray(classes)
    thresholds = thresholds or {}
    candidates: list[tuple[float, float, str, float]] = []
    for index, class_value in enumerate(classes_array):
        label = str(class_value)
        if label == "background":
            continue
        threshold = float(thresholds.get(label, default_threshold))
        confidence = float(scores[index])
        if confidence >= threshold:
            candidates.append((confidence / max(threshold, 1e-6), confidence, label, threshold))
    if candidates:
        _, confidence, label, threshold = max(candidates)
        return DetectionResult(label, confidence, threshold, True)
    background_indices = np.flatnonzero(classes_array == "background")
    confidence = float(scores[int(background_indices[0])]) if background_indices.size else 0.0
    return DetectionResult("background", confidence, 1.0, False)


def threshold_array(
    classes: list[str] | np.ndarray,
    thresholds: dict[str, float],
    default_threshold: float,
) -> np.ndarray:
    return np.asarray([
        thresholds.get(str(label), default_threshold)
        for label in classes
    ], dtype=np.float32)
