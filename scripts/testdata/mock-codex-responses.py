#!/usr/bin/env python3
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class MockResponsesHandler(BaseHTTPRequestHandler):
    request_number = 0
    request_lock = threading.Lock()
    request_log = None

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        request = json.loads(body)

        with self.request_lock:
            self.__class__.request_number += 1
            response_number = self.__class__.request_number

        if self.request_log is not None:
            with self.request_log.open("a", encoding="utf-8") as log_file:
                json.dump(
                    {
                        "path": self.path,
                        "authorization": self.headers.get("Authorization", ""),
                        "body": request,
                    },
                    log_file,
                    separators=(",", ":"),
                )
                log_file.write("\n")

        model = request.get("model", "e2e-model")
        message_id = f"msg_e2e_{response_number}"
        response_id = f"resp_e2e_{response_number}"
        item = {
            "type": "message",
            "id": message_id,
            "status": "in_progress",
            "role": "assistant",
            "content": [],
        }
        completed_item = {
            **item,
            "status": "completed",
            "content": [{"type": "output_text", "text": "e2e response", "annotations": []}],
        }
        response = {
            "id": response_id,
            "object": "response",
            "created_at": 0,
            "status": "completed",
            "model": model,
            "output": [completed_item],
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        }
        events = [
            {"type": "response.created", "response": {**response, "status": "in_progress", "output": []}},
            {"type": "response.output_item.added", "output_index": 0, "item": item},
            {
                "type": "response.content_part.added",
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "part": {"type": "output_text", "text": ""},
            },
            {
                "type": "response.output_text.delta",
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "delta": "e2e response",
            },
            {
                "type": "response.output_text.done",
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "text": "e2e response",
            },
            {
                "type": "response.content_part.done",
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "part": {"type": "output_text", "text": "e2e response", "annotations": []},
            },
            {"type": "response.output_item.done", "output_index": 0, "item": completed_item},
            {"type": "response.completed", "response": response},
        ]
        stream = "".join(f"data: {json.dumps(event, separators=(',', ':'))}\n\n" for event in events)
        stream += "data: [DONE]\n\n"
        raw = stream.encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--request-log", type=Path, required=True)
    args = parser.parse_args()

    MockResponsesHandler.request_log = args.request_log
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockResponsesHandler)
    args.port_file.write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()


if __name__ == "__main__":
    main()
