import json
import threading
import unittest
import urllib.error
import urllib.request

import receiver


class ReceiverTests(unittest.TestCase):
    def start(self, **kwargs):
        self.state = receiver.State(key="secret", echo=False, **kwargs)
        self.server = receiver.make_server("127.0.0.1", 0, self.state)
        threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def call(self, path, body=None, key="secret", raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(self.base + path, data=data, method="POST" if data is not None else "GET")
        if key is not None:
            request.add_header("X-Dictation-Key", key)
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_sanitize(self):
        self.assertEqual(receiver.sanitize("Hello,\n  world.\t"), "Hello, world.")
        self.assertEqual(receiver.sanitize("café"), "café")
        self.assertEqual(receiver.sanitize("a\x00b\x07c"), "abc")
        self.assertEqual(receiver.sanitize(" \n\t "), "")

    def test_insert_and_duplicate(self):
        self.start()
        status, body = self.call("/text", {"id": "a1", "text": "Hello, world."})
        self.assertEqual((status, body["status"], body["duplicate"]), (200, "inserted", False))
        status, body = self.call("/text", {"id": "a1", "text": "Hello, world."})
        self.assertEqual((status, body["duplicate"]), (200, True))
        self.assertEqual(list(self.state.seen), ["a1"])

    def test_auth(self):
        self.start()
        self.assertEqual(self.call("/text", {"id": "a", "text": "x"}, key="wrong")[0], 401)
        self.assertEqual(self.call("/text", {"id": "a", "text": "x"}, key=None)[0], 401)
        self.assertEqual(self.call("/status", key="wrong")[0], 401)
        self.assertEqual(self.call("/status")[0], 200)

    def test_invalid_bodies(self):
        self.start()
        self.assertEqual(self.call("/text", {"id": "a", "text": "  \n "})[0], 422)
        self.assertEqual(self.call("/text", {"text": "x"})[0], 422)
        self.assertEqual(self.call("/text", raw=b"not json")[0], 422)
        self.assertEqual(self.call("/text", {"id": 5, "text": "x"})[0], 422)

    def test_size_cap(self):
        self.start()
        status, body = self.call("/text", {"id": "big", "text": "x" * 5000})
        self.assertEqual((status, body["error"]), (413, "too_large"))

    def test_refusal_states(self):
        self.start(locked=True)
        self.assertEqual(self.call("/text", {"id": "a", "text": "x"})[0], 423)
        self.assertEqual(self.state.seen, {})
        self.start(secure_input=True)
        self.assertEqual(self.call("/text", {"id": "b", "text": "x"})[0], 409)

    def test_rate_limit(self):
        self.start()
        statuses = [self.call("/text", {"id": f"r{i}", "text": "x"})[0] for i in range(receiver.RATE_LIMIT_PER_SECOND + 3)]
        self.assertIn(429, statuses)
        self.assertEqual(statuses[0], 200)

    def test_status_reports_contract(self):
        self.start()
        status, body = self.call("/status")
        self.assertEqual((status, body["contract"], body["locked"]), (200, receiver.CONTRACT, False))

    def test_only_the_last_hundred_ids_are_remembered(self):
        state = receiver.State(echo=False)
        for index in range(receiver.REMEMBERED_IDS + 5):
            state.accept(f"id{index}", "x")
        self.assertEqual(len(state.seen), receiver.REMEMBERED_IDS)
        self.assertNotIn("id0", state.seen)


if __name__ == "__main__":
    unittest.main()
