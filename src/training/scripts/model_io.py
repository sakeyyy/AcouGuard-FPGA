from __future__ import annotations
import argparse,json
from pathlib import Path
from dataclasses import asdict
import numpy as np
from fsd50k_audio_features import FeatureConfig
from fsd50k_sensitive_utils import threshold_array
def export_npz(
    pipeline: Pipeline,
    config: FeatureConfig,
    thresholds: dict[str, float],
    args: argparse.Namespace,
    path: Path,
) -> None:
    scaler: StandardScaler = pipeline.named_steps["scaler"]
    classifier: MLPClassifier = pipeline.named_steps["classifier"]
    arrays: dict[str, np.ndarray] = {
        "classes": np.asarray(classifier.classes_),
        "scaler_mean": scaler.mean_.astype(np.float32),
        "scaler_scale": scaler.scale_.astype(np.float32),
        "thresholds": threshold_array(classifier.classes_, thresholds, args.default_threshold),
        "default_threshold": np.asarray(args.default_threshold, dtype=np.float32),
        "top_windows": np.asarray(args.top_windows, dtype=np.int32),
        "evaluation_hop": np.asarray(args.evaluation_hop, dtype=np.float32),
        "feature_config_json": np.asarray(json.dumps(asdict(config))),
        "layer_count": np.asarray(len(classifier.coefs_), dtype=np.int32),
    }
    for index, (weights, biases) in enumerate(zip(classifier.coefs_, classifier.intercepts_)):
        arrays[f"layer_{index}_weights"] = weights.astype(np.float32)
        arrays[f"layer_{index}_biases"] = biases.astype(np.float32)
    np.savez_compressed(path, **arrays)
