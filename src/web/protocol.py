"""Framed signed PCM16. All integers are little endian; CRC32 covers payload."""
import struct
import zlib
import numpy as np

HEADER = struct.Struct('<4sBBHIIHHII')
MAGIC = b'ASW1'
# flags: bit0 board lowpass, bit1 capture discontinuity, bit2 buffered mode.


def encode(samples, rate_num, rate_den, sequence=0, flags=1):
    samples = np.asarray(samples, dtype='<i2')
    if samples.ndim == 1:
        samples = samples[:, None]
    frames, channels = samples.shape
    payload = samples.tobytes()
    return (HEADER.pack(MAGIC, 1, channels, flags, rate_num, rate_den,
                        frames, 0, sequence, len(payload)) + payload
            + struct.pack('<I', zlib.crc32(payload)))


class Parser:
    def __init__(self, text_callback=None):
        self.text_callback = text_callback
        self.buffer = bytearray()
        self.crc_errors = 0
        self.discarded = 0

    def feed(self, data):
        self.buffer.extend(data)
        packets = []
        while True:
            pos = self.buffer.find(MAGIC)
            if pos < 0:
                # Keep only a possible partial header, not arbitrary trailing
                # text. Terminal board errors must be shown without more PCM.
                keep = next((n for n in range(min(3, len(self.buffer)), 0, -1)
                             if self.buffer[-n:] == MAGIC[:n]), 0)
                count = len(self.buffer) - keep
                if count and self.text_callback:
                    self.text_callback(bytes(self.buffer[:count]))
                self.discarded += count
                del self.buffer[:count]
                break
            if pos:
                if self.text_callback:
                    self.text_callback(bytes(self.buffer[:pos]))
                self.discarded += pos
                del self.buffer[:pos]
            if len(self.buffer) < HEADER.size:
                break
            _, version, ch, flags, num, den, frames, reserved, seq, size = HEADER.unpack_from(self.buffer)
            rate = num / den if den else 0
            if (version != 1 or not 1 <= ch <= 4 or not 1000 <= rate <= 48000
                    or not 1 <= frames <= 4096 or size != frames * ch * 2
                    or reserved or flags & ~7):
                self.discarded += 1
                del self.buffer[0]
                continue
            end = HEADER.size + size
            if len(self.buffer) < end + 4:
                break
            payload = bytes(self.buffer[HEADER.size:end])
            if zlib.crc32(payload) != struct.unpack_from('<I', self.buffer, end)[0]:
                self.crc_errors += 1
                del self.buffer[0]
                continue
            del self.buffer[:end + 4]
            packets.append({'rate': rate, 'channels': ch, 'flags': flags,
                            'sequence': seq, 'samples': np.frombuffer(payload, '<i2').reshape(frames, ch)})
        return packets
