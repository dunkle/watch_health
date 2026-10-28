"""Exercise the actual bounded URLSession transport on loopback, without credentials or external services.

This compiles the transport extracted from AIService.swift with FoundationNetworking on Linux,
or Foundation on macOS. It does not validate native Keychain, FoundationModels, or iOS behavior.
"""
from pathlib import Path
import http.server
import os
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[2]
source = (root / 'iOS/AIService.swift').read_text()
errors = source[source.index('enum AIServiceError:'):source.index('@MainActor\nenum AIReviewService')]
transport = source[source.index('private final class BoundedAIRequest:'):]
swift = os.environ.get('SWIFT_BIN', 'swift')
swiftc = str(Path(swift).with_name('swiftc')) if '/' in swift else 'swiftc'


class Handler(http.server.BaseHTTPRequestHandler):
    followed = False

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/followed')
            self.end_headers()
            return
        if self.path == '/followed':
            Handler.followed = True
        if self.path == '/huge':
            self.send_response(200)
            self.send_header('Content-Length', '256001')
            self.end_headers()
            return
        if self.path == '/stream':
            self.send_response(200)
            self.end_headers()
            try:
                self.wfile.write(b'x' * 260000)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path in ('/limit', '/auth'):
            self.send_response(429 if self.path == '/limit' else 401)
            self.end_headers()
            return
        if self.path == '/slow':
            time.sleep(0.2)
        try:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')
        except (BrokenPipeError, ConnectionResetError):
            pass


harness = r'''
@main struct Harness {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        for (path, expected) in [("/ok", "ok"), ("/huge", "oversized"), ("/stream", "oversized"),
                                 ("/redirect", "redirect"), ("/limit", "rateLimited"), ("/auth", "unauthorized")] {
            var request = URLRequest(url: URL(string: base + path)!)
            request.httpMethod = "POST"
            request.setValue("Bearer fixture-only-not-a-real-key", forHTTPHeaderField: "Authorization")
            do {
                let data = try await BoundedAIRequest().run(request)
                precondition(expected == "ok" && String(decoding: data, as: UTF8.self) == "ok", path)
            } catch {
                precondition(String(describing: error) == expected, "\(path): \(error)")
            }
        }
        // Both cancellation before startup and cancellation while awaiting a response must complete once.
        for delay: UInt64 in [0, 20_000_000] {
            let cancelled = Task { () -> Data in
                var request = URLRequest(url: URL(string: base + "/slow")!)
                request.httpMethod = "POST"
                return try await BoundedAIRequest().run(request)
            }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            cancelled.cancel()
            do { _ = try await cancelled.value; preconditionFailure("Cancelled request succeeded") }
            catch is CancellationError { }
        }
        print("8 actual AI transport loopback scenarios passed (not an Apple SDK validation)")
    }
}
'''

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='watchmind-ai-transport-') as temporary:
        target = Path(temporary)
        source_file = target / 'Transport.swift'
        source_file.write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
                               + errors + transport + harness)
        command = [swiftc, '-swift-version', '5', '-module-cache-path', str(target / 'module-cache'),
                   '-parse-as-library', str(source_file), '-o', str(target / 'transport-check')]
        subprocess.run(command, cwd=root, check=True, timeout=90)
        subprocess.run([str(target / 'transport-check'), f'http://127.0.0.1:{server.server_port}'],
                       cwd=root, check=True, timeout=30)
    assert not Handler.followed, 'Transport followed a redirect and could have forwarded credentials'
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
