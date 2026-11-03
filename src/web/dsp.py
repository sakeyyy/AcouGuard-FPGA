"""Stateful, causal filters. Original and processed data keep the same scale."""
import numpy as np
from scipy import signal


def make_sos(rate, highpass=80, lowpass=1000, notch=0):
    if not (0 <= highpass < lowpass < rate / 2):
        raise ValueError('Require 0 <= highpass < lowpass < half the sampling rate')
    stages = []
    if highpass:
        stages.append(signal.butter(2, highpass, 'highpass', fs=rate, output='sos'))
    if notch:
        if notch not in (50, 60) or notch >= rate / 2:
            raise ValueError('Notch must be 0, 50 or 60 Hz and below Nyquist')
        b, a = signal.iirnotch(notch, 25, fs=rate)
        stages.append(signal.tf2sos(b, a))
    stages.append(signal.butter(4, lowpass, fs=rate, output='sos'))
    return np.vstack(stages)


class Processor:
    def __init__(self):
        self.key = None
        self.last_sequence = None
        self.missing = 0

    def process(self, packet, settings):
        raw = packet['samples'].astype(np.float64) / 32768.0
        rate, ch = packet['rate'], packet['channels']
        seq = packet['sequence']
        key = (rate, ch, *settings)
        gap = self.last_sequence is not None and seq != ((self.last_sequence + 1) & 0xffffffff)
        if gap:
            delta = (seq - self.last_sequence - 1) & 0xffffffff
            self.missing += delta if delta < 100000 else 1
        reset = key != self.key or gap or bool(packet['flags'] & 2)
        if reset:
            self.sos = make_sos(rate, *settings)
            # Start at the initial DC level to avoid a large startup transient.
            self.zi = signal.sosfilt_zi(self.sos)[:, :, None] * raw[0][None, None, :]
            self.key = key
        self.last_sequence = seq
        filtered, self.zi = signal.sosfilt(self.sos, raw, axis=0, zi=self.zi)
        rms = np.sqrt(np.mean(filtered ** 2, axis=0))
        return {'type': 'audio', 'seq': seq, 'rate': rate, 'channels': ch,
                'raw': raw.round(7).T.tolist(), 'filtered': filtered.round(7).T.tolist(),
                'rms': rms.tolist(), 'dbfs': (20*np.log10(np.maximum(rms, 1e-9))).tolist(),
                'clipped': np.sum((packet['samples'] == -32768) | (packet['samples'] == 32767), axis=0).tolist(),
                'missing': self.missing, 'gap': gap or bool(packet['flags'] & 2),
                'buffered': bool(packet['flags'] & 4), 'board_filtered': bool(packet['flags'] & 1),
                'reset': reset, 'filters': list(settings)}
