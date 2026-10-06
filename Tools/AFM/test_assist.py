#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for AFM select_candidate and engine-probe integration."""

import contextlib
import json
import os
import subprocess
import sys
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = ROOT / ".build" / "afm"
ENGINE_PROBE = BUILD_DIR / "engine-probe"
DATA_TXT = BUILD_DIR / "data.txt"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import assist


class FakeResponse:
    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


def make_fake_opener(payload_bytes, request=None, timeout_list=None):
    def opener(req, timeout=None):
        if request is not None:
            request.append(req)
        if timeout_list is not None:
            timeout_list.append(timeout)
        return FakeResponse(payload_bytes)
    return opener


def make_fake_opener_raise(exc):
    def opener(req, timeout=None):
        raise exc
    return opener


def make_fake_opener_raise_timeout():
    def opener(req, timeout=None):
        raise TimeoutError("timed out")
    return opener


def make_fake_opener_raise_urlerror(reason):
    def opener(req, timeout=None):
        raise urllib.error.URLError(reason)
    return opener


def make_fake_opener_raise_httperror(code):
    def opener(req, timeout=None):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:1976/v1/chat/completions",
            code,
            "error",
            None,
            None,
        )
    return opener


class TestSelectCandidate(unittest.TestCase):
    def test_valid_id_preserves_original_dict(self):
        candidates = [
            {"id": 0, "text": "你好"},
            {"id": 1, "text": "妳好"},
        ]
        value = 1
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": value})}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate(
            "ctx", candidates, opener=opener
        )
        self.assertTrue(result["used_afm"])
        self.assertIs(result["selected"], candidates[1])
        self.assertIsNone(result["fallback_reason"])

    def test_rejects_bool_true(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": True})}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_rejects_float_1_5(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": 1.5})}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_rejects_string_1(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": "1"})}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_rejects_out_of_range_999(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": 999})}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_rejects_empty_object(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({})}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_malformed_outer_json(self):
        candidates = [{"id": 0, "text": "你好"}]
        opener = make_fake_opener(b"not json")
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_malformed_content_json(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": "not json"}}]}
        ).encode()
        opener = make_fake_opener(outer)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "invalid_response")

    def test_timeout_error_fallback(self):
        candidates = [{"id": 0, "text": "你好"}]
        opener = make_fake_opener_raise_timeout()
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "timeout")

    def test_http_error_500_fallback(self):
        candidates = [{"id": 0, "text": "你好"}]
        opener = make_fake_opener_raise_httperror(500)
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "http")

    def test_url_error_transport_fallback(self):
        candidates = [{"id": 0, "text": "你好"}]
        opener = make_fake_opener_raise_urlerror("connection refused")
        result = assist.select_candidate("ctx", candidates, opener=opener)
        self.assertFalse(result["used_afm"])
        self.assertEqual(result["fallback_reason"], "transport")

    def test_invalid_finite_timeout_value_error(self):
        candidates = [{"id": 0, "text": "你好"}]
        with self.assertRaises(ValueError):
            assist.select_candidate("ctx", candidates, timeout_ms=-1)

    def test_rejects_nan_timeout(self):
        candidates = [{"id": 0, "text": "你好"}]
        with self.assertRaises(ValueError):
            assist.select_candidate("ctx", candidates, timeout_ms=float("nan"))

    def test_rejects_inf_timeout(self):
        candidates = [{"id": 0, "text": "你好"}]
        with self.assertRaises(ValueError):
            assist.select_candidate("ctx", candidates, timeout_ms=float("inf"))

    def test_rejects_neg_inf_timeout(self):
        candidates = [{"id": 0, "text": "你好"}]
        with self.assertRaises(ValueError):
            assist.select_candidate("ctx", candidates, timeout_ms=float("-inf"))

    def test_request_structure(self):
        candidates = [
            {"id": 0, "text": "你好"},
            {"id": 1, "text": "妳好"},
        ]
        long_context = "A" * 300
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": 0})}}]}
        ).encode()
        captured_requests = []
        captured_timeouts = []
        opener = make_fake_opener(
            outer,
            request=captured_requests,
            timeout_list=captured_timeouts,
        )
        result = assist.select_candidate(
            long_context,
            candidates,
            model="test-model",
            timeout_ms=500,
            opener=opener,
        )
        self.assertTrue(result["used_afm"])

        req = captured_requests[0]
        self.assertEqual(req.method, "POST")
        self.assertIn("Content-type", req.headers)
        self.assertEqual(req.headers["Content-type"], "application/json")

        self.assertEqual(captured_timeouts[0], 0.5)

        body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(body["model"], "test-model")
        self.assertEqual(body["temperature"], 0)
        self.assertEqual(body["max_tokens"], 16)
        self.assertFalse(body["stream"])

        messages = body["messages"]
        self.assertEqual(len(messages), 2)
        self.assertEqual(messages[0]["role"], "system")
        self.assertEqual(messages[1]["role"], "user")

        user_content = json.loads(messages[1]["content"])
        self.assertEqual(len(user_content["context_suffix"]), 256)
        self.assertEqual(user_content["context_suffix"], "A" * 256)
        self.assertEqual(user_content["candidates"], candidates)

    def test_context_shorter_than_256(self):
        candidates = [{"id": 0, "text": "你好"}]
        outer = json.dumps(
            {"choices": [{"message": {"content": json.dumps({"id": 0})}}]}
        ).encode()
        captured_requests = []
        opener = make_fake_opener(outer, request=captured_requests)
        assist.select_candidate("short", candidates, opener=opener)
        body = json.loads(captured_requests[0].data.decode("utf-8"))
        user_content = json.loads(body["messages"][1]["content"])
        self.assertEqual(user_content["context_suffix"], "short")


class TestEngineProbeIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ENGINE_PROBE.is_file():
            raise unittest.SkipTest(f"engine-probe not found: {ENGINE_PROBE}")
        if not DATA_TXT.is_file():
            raise unittest.SkipTest(f"data.txt not found: {DATA_TXT}")

    def _run_probe(self, keys):
        result = subprocess.run(
            [str(ENGINE_PROBE), str(DATA_TXT), keys],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def test_su3_cl3_baseline(self):
        data = self._run_probe("su3 cl3")
        self.assertEqual(data["backend"], "McBopomofo")
        self.assertEqual(data["readings"], ["ㄋㄧˇ", "ㄏㄠˇ"])
        self.assertEqual(data["baseline"], "你好")
        texts = [c["text"] for c in data["candidates"]]
        self.assertIn("你好", texts)
        self.assertIn("妳好", texts)

    def test_medium_phrase(self):
        data = self._run_probe("vul3 a94 5j4 up gj bj4 z83")
        self.assertEqual(data["baseline"], "小麥注音輸入法")
        texts = [c["text"] for c in data["candidates"]]
        self.assertIn("小麥注音輸入法", texts)

    def test_g4_ru4_comma(self):
        data = self._run_probe("g4 ru,4")
        self.assertEqual(data["readings"], ["ㄕˋ", "ㄐㄧㄝˋ"])
        texts = [c["text"] for c in data["candidates"]]
        self.assertIn("世界", texts)
        self.assertIn("視界", texts)

    def test_unknown_key_nonzero(self):
        result = subprocess.run(
            [str(ENGINE_PROBE), str(DATA_TXT), "!"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_empty_keys_nonzero(self):
        result = subprocess.run(
            [str(ENGINE_PROBE), str(DATA_TXT), ""],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_missing_model_nonzero(self):
        result = subprocess.run(
            [str(ENGINE_PROBE), str(Path("/nonexistent/data.txt")), "su3"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_candidate0_is_baseline(self):
        data = self._run_probe("su3 cl3")
        self.assertEqual(data["candidates"][0]["text"], data["baseline"])

    def test_unique_ids_and_texts(self):
        data = self._run_probe("su3 cl3")
        ids = [c["id"] for c in data["candidates"]]
        texts = [c["text"] for c in data["candidates"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len(texts), len(set(texts)))
        self.assertLessEqual(len(data["candidates"]), 16)


class TestCLIIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ENGINE_PROBE.is_file():
            raise unittest.SkipTest(f"engine-probe not found: {ENGINE_PROBE}")
        if not DATA_TXT.is_file():
            raise unittest.SkipTest(f"data.txt not found: {DATA_TXT}")

    def test_default_offline_cli(self):
        assist_path = Path(__file__).resolve().parent / "assist.py"
        result = subprocess.run(
            [sys.executable, str(assist_path), "--keys", "su3 cl3", "--timeout-ms", "800"],
            check=True,
            capture_output=True,
            text=True,
        )
        data = json.loads(result.stdout)
        self.assertEqual(data["selected"]["text"], "你好")
        self.assertFalse(data["used_afm"])


if __name__ == "__main__":
    unittest.main()
