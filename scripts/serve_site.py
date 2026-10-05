#!/usr/bin/env python3
"""Preview docs/ with byte-range support for paused MP4 scrubbing."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import os


ROOT = Path(__file__).resolve().parents[1] / "docs"


class SiteHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def send_head(self):
        self.byte_range = None
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            source = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        size = os.fstat(source.fileno()).st_size
        header = self.headers.get("Range")
        if header and header.startswith("bytes="):
            try:
                first, last = header[6:].split("-", 1)
                start = int(first) if first else 0
                end = int(last) if last else size - 1
                if start < 0 or end < start or start >= size:
                    raise ValueError
                end = min(end, size - 1)
            except ValueError:
                source.close()
                self.send_error(416, "Invalid byte range")
                return None
            self.byte_range = (start, end)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end - start + 1))
        else:
            self.send_response(200)
            self.send_header("Content-Length", str(size))
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        return source

    def copyfile(self, source, outputfile):
        try:
            if self.byte_range is None:
                return super().copyfile(source, outputfile)
            start, end = self.byte_range
            source.seek(start)
            remaining = end - start + 1
            while remaining:
                chunk = source.read(min(65536, remaining))
                if not chunk:
                    break
                outputfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            # A new seek cancels the browser's previous range request.
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    print(f"Serving {ROOT} at http://127.0.0.1:{args.port}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), SiteHandler).serve_forever()
