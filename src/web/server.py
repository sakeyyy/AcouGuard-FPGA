"""Local serial PCM viewer. No computer microphone or generated audio input."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import json
import math
import queue
import threading
import time
import serial
from serial.tools import list_ports
from dsp import Processor, make_sos
from protocol import Parser
from board_text import BoardTextReader


class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.clients = set()
        self.target = None
        self.generation = 0
        self.settings = (80, 1000, 0)
        self.status = {'type': 'status', 'connected': False, 'message': '未连接开发板'}
        self.rate = 4000.0
        self.recognition = None
        self.board_error = None

    def publish(self, message):
        encoded = json.dumps(message, ensure_ascii=False, separators=(',', ':'))
        with self.lock:
            if message['type'] == 'status':
                self.status = message
            elif message['type'] == 'recognition':
                self.recognition = message
            elif message['type'] == 'board_error':
                self.board_error = message
            for client in self.clients:
                try:
                    client.put_nowait(encoded)
                except queue.Full:
                    try:
                        client.get_nowait()
                    except queue.Empty:
                        pass
                    client.put_nowait(encoded)


def serial_worker(hub, stop):
    device, current_generation, parser, processor = None, -1, None, None
    last_packet, last_status = None, 0
    while not stop.is_set():
        with hub.lock:
            target, generation, settings = hub.target, hub.generation, hub.settings
        try:
            if generation != current_generation:
                if device:
                    device.close()
                device = None
                current_generation = generation
                if target:
                    device = serial.Serial(target[0], target[1], timeout=0.1)
                    reader = BoardTextReader(hub.publish)
                    parser, processor = Parser(reader.feed), Processor()
                    hub.publish({'type': 'recognition', 'label': None, 'name': '等待识别'})
                    hub.publish({'type': 'board_error', 'message': ''})
                    last_packet = None
                    hub.publish({'type': 'status', 'connected': True, 'message': '串口已打开，等待 PCM 数据', 'port': target[0]})
                else:
                    hub.publish({'type': 'status', 'connected': False, 'message': '未连接开发板'})
            if device is None:
                stop.wait(0.1)
                continue
            for packet in parser.feed(device.read(min(max(device.in_waiting, 1), 32768))):
                with hub.lock:
                    hub.rate = packet['rate']
                event = processor.process(packet, settings)
                event['crc_errors'] = parser.crc_errors
                hub.publish(event)
                last_packet = time.monotonic()
            now = time.monotonic()
            if now - last_status > 1:
                age = None if last_packet is None else now - last_packet
                hub.publish({'type': 'status', 'connected': True, 'age': age,
                             'message': '正在接收 PCM' if age is not None and age < 2 else '等待 PCM；普通识别文字不包含波形数据',
                             'crc_errors': parser.crc_errors, 'discarded_bytes': parser.discarded})
                last_status = now
        except (serial.SerialException, OSError, ValueError) as exc:
            if device:
                device.close()
            device = None
            hub.publish({'type': 'status', 'connected': False, 'message': str(exc)})
    if device:
        device.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--port', help='Optional initial serial port, e.g. COM3')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--http-port', type=int, default=8765)
    args = ap.parse_args()
    hub, stop = Hub(), threading.Event()
    if args.port:
        hub.target = (args.port, args.baud)
    root = Path(__file__).parent
    assets = {'/': ('index.html', 'text/html; charset=utf-8'),
              '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
              '/style.css': ('style.css', 'text/css; charset=utf-8')}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/api/ports':
                self.reply([{'device': p.device, 'description': p.description} for p in list_ports.comports()])
            elif self.path == '/events':
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                client = queue.Queue(maxsize=12)
                with hub.lock:
                    hub.clients.add(client)
                    snapshots = [hub.status, hub.recognition, hub.board_error]
                try:
                    for snapshot in snapshots:
                        if snapshot is not None:
                            status = json.dumps(snapshot, ensure_ascii=False)
                            self.wfile.write(f'data: {status}\n\n'.encode())
                    self.wfile.flush()
                    while not stop.is_set():
                        try:
                            block = f'data: {client.get(timeout=1)}\n\n'
                        except queue.Empty:
                            block = ': heartbeat\n\n'
                        self.wfile.write(block.encode())
                        self.wfile.flush()
                except OSError:
                    pass
                finally:
                    with hub.lock:
                        hub.clients.discard(client)
            elif self.path in assets:
                name, mime = assets[self.path]
                data = (root / name).read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_error(404)

        def do_POST(self):
            # Restrict browser writes to the local page that opened this server.
            origin = self.headers.get('Origin')
            allowed = {f'http://127.0.0.1:{self.server.server_port}', f'http://localhost:{self.server.server_port}'}
            if origin and origin not in allowed:
                self.reply({'error': 'Unexpected origin'}, 403)
                return
            try:
                length = int(self.headers.get('Content-Length', 0))
                if not 0 <= length <= 2048:
                    raise ValueError('Request too large')
                body = json.loads(self.rfile.read(length) or b'{}')
                if self.path == '/api/connect':
                    port, baud = str(body['port']), int(body['baud'])
                    if not port or baud not in (115200, 230400, 460800, 921600):
                        raise ValueError('请选择串口和有效波特率')
                    with hub.lock:
                        hub.target = (port, baud)
                        hub.generation += 1
                elif self.path == '/api/disconnect':
                    with hub.lock:
                        hub.target = None
                        hub.generation += 1
                elif self.path == '/api/filters':
                    settings = tuple(float(body[k]) for k in ('highpass', 'lowpass', 'notch'))
                    if not all(math.isfinite(v) for v in settings):
                        raise ValueError('Invalid filter value')
                    with hub.lock:
                        make_sos(hub.rate, *settings)
                        hub.settings = settings
                else:
                    self.reply({'error': 'Not found'}, 404)
                    return
                self.reply({'ok': True})
            except (KeyError, ValueError, TypeError) as exc:
                self.reply({'error': str(exc)}, 400)

        def reply(self, value, code=200):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    try:
        server = ThreadingHTTPServer(('127.0.0.1', args.http_port), Handler)
    except OSError as exc:
        ap.error(f'{exc}; choose another --http-port')
    server.daemon_threads = True
    threading.Thread(target=serial_worker, args=(hub, stop), daemon=True).start()
    print(f'Open http://127.0.0.1:{server.server_port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()


if __name__ == '__main__':
    main()
