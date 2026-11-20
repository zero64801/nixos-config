"""Tests for arli_proxy. Run with:  python -m unittest -v test_arli_proxy"""

import contextlib
import http.client
import json
import logging
import os
import socket
import socketserver
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import arli_proxy as ap

# Expected warnings, such as unparseable tool arguments, would otherwise print through logging's last resort handler.
ap.log.addHandler(logging.NullHandler())

KEY_ENV = "ARLI_PROXY_TEST_KEY"
CATALOG = [
    {"name": "test-model", "vlm": True, "reasoning": True, "baseModel": True, "contextSize": "262144", "parameters": "27B"},
    {"name": "big-model", "vlm": False, "reasoning": True, "baseModel": True, "contextSize": "524288", "parameters": "552B"},
    {"name": "blind-model", "vlm": False, "reasoning": False, "baseModel": False, "contextSize": "202752", "parameters": "8B"},
]


def build(req, vision=True, reasoning=True, **options):
    return ap.build_chat_request(req, ap.ModelConfig(upstream="m", **options), vision=vision, reasoning=reasoning)


def chunk(delta=None, finish=None, **extra):
    choice = {"index": 0, "delta": delta or {}, "finish_reason": finish, **extra}
    return {"id": "chatcmpl-1", "object": "chat.completion.chunk", "choices": [choice]}


def translate(chunks, think_tags=True, stops=()):
    tr = ap.StreamTranslator("arli/m", think_tags, stops)
    events = [tr.start()]
    for c in chunks:
        events += tr.feed(c)
    events += tr.finish()
    return events


def assert_well_formed(test, events):
    """Every block opens, receives deltas, and closes in order, as Claude Code expects."""
    names = [name for name, _ in events]
    test.assertEqual(names[0], "message_start")
    test.assertEqual(names[-2:], ["message_delta", "message_stop"])
    open_index, next_index = None, 0
    for name, data in events[1:-2]:
        if name == "content_block_start":
            test.assertIsNone(open_index)
            test.assertEqual(data["index"], next_index)
            open_index = data["index"]
        elif name == "content_block_delta":
            test.assertEqual(data["index"], open_index)
        elif name == "content_block_stop":
            test.assertEqual(data["index"], open_index)
            open_index, next_index = None, next_index + 1
    test.assertIsNone(open_index)


class SystemPromptTests(unittest.TestCase):
    REQ = {
        "system": [
            {"type": "text", "text": "x-anthropic-billing-header: cc_version=2.1"},
            {"type": "text", "text": "You are Claude Code.", "cache_control": {"type": "ephemeral"}},
        ],
        "messages": [{"role": "user", "content": "hi"}],
    }

    def test_attribution_block_is_dropped(self):
        self.assertEqual(build(self.REQ)["messages"][0], {"role": "system", "content": "You are Claude Code."})

    def test_model_text_wraps_the_prompt(self):
        body = build(self.REQ, system_prepend="Before.", system_append="After.")
        self.assertEqual(body["messages"][0]["content"], "Before.\n\nYou are Claude Code.\n\nAfter.")

    def test_replace(self):
        self.assertEqual(build(self.REQ, system_replace="Mine.")["messages"][0]["content"], "Mine.")


class MessageTests(unittest.TestCase):
    def test_tool_calls_and_results_follow_openai_order(self):
        req = {"messages": [
            {"role": "user", "content": "run it"},
            {"role": "assistant", "content": [
                {"type": "text", "text": "ok"},
                {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "ls"}},
                {"type": "tool_use", "id": "call.2", "name": "Read", "input": {"file_path": "a"}},
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_1", "content": "a\nb"},
                {"type": "tool_result", "tool_use_id": "call.2", "content": [{"type": "text", "text": "missing"}], "is_error": True},
                {"type": "text", "text": "<system-reminder>x</system-reminder>"},
            ]},
        ]}
        self.assertEqual(build(req)["messages"], [
            {"role": "user", "content": "run it"},
            {"role": "assistant", "content": "ok", "tool_calls": [
                {"id": "toolu_1", "type": "function", "function": {"name": "Bash", "arguments": '{"command": "ls"}'}},
                {"id": "call_2", "type": "function", "function": {"name": "Read", "arguments": '{"file_path": "a"}'}},
            ]},
            {"role": "tool", "tool_call_id": "toolu_1", "content": "a\nb"},
            {"role": "tool", "tool_call_id": "call_2", "content": "Error: missing"},
            {"role": "user", "content": "<system-reminder>x</system-reminder>"},
        ])

    def test_images_follow_the_vision_flag(self):
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}}
        req = {"messages": [{"role": "user", "content": [image, {"type": "text", "text": "what is this"}]}]}
        self.assertEqual(build(req)["messages"][0]["content"], [
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}},
            {"type": "text", "text": "what is this"},
        ])
        self.assertEqual(build(req, vision=False)["messages"][0]["content"],
                         "[image omitted: this model does not accept images]\n\nwhat is this")

    def test_tool_result_images_move_to_a_user_message(self):
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "BBBB"}}
        req = {"messages": [
            {"role": "user", "content": "look"},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [image]}]},
        ]}
        messages = build(req)["messages"]
        self.assertEqual(messages[2], {"role": "tool", "tool_call_id": "t1", "content": "(no output)"})
        self.assertEqual(messages[3]["content"][1]["image_url"]["url"], "data:image/jpeg;base64,BBBB")
        self.assertIn("image omitted", build(req, vision=False)["messages"][2]["content"])

    def test_mid_conversation_system_entries_become_user_text(self):
        req = {"messages": [
            {"role": "user", "content": "a"},
            {"role": "assistant", "content": "b"},
            {"role": "system", "content": [{"type": "text", "text": "reminder"}], "output_config": {"effort": "low"}},
            {"role": "user", "content": "c"},
        ]}
        body = build(req)
        self.assertEqual(body["messages"][2], {"role": "user", "content": "reminder\n\nc"})
        self.assertEqual(body["reasoning_effort"], "low")

    def test_pdf_documents_become_a_note(self):
        req = {"messages": [{"role": "user", "content": [
            {"type": "document", "title": "spec", "source": {"type": "base64", "media_type": "application/pdf", "data": "x"}},
        ]}]}
        self.assertIn('document "spec" omitted', build(req)["messages"][0]["content"])

    def test_reasoning_history(self):
        req = {"messages": [
            {"role": "user", "content": "q1"},
            {"role": "assistant", "content": [{"type": "thinking", "thinking": "old", "signature": "s"}, {"type": "text", "text": "a1"}]},
            {"role": "user", "content": "q2"},
            {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "new", "signature": "s"},
                {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}},
            ]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "done"}]},
        ]}

        def reasoning(history):
            return [m.get("reasoning_content") for m in build(req, reasoning_history=history)["messages"] if m["role"] == "assistant"]

        self.assertEqual(reasoning("current_turn"), [None, "new"])
        self.assertEqual(reasoning("all"), ["old", "new"])
        self.assertEqual(reasoning("none"), [None, None])


class SystemPromptFileTests(unittest.TestCase):
    REQ = SystemPromptTests.REQ

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def write(self, name, text):
        path = self.dir / name
        path.write_text(text, encoding="utf-8")
        return str(path)

    def prompt(self, **options):
        return build(self.REQ, **options)["messages"][0]["content"]

    def test_append_and_prepend_from_files(self):
        self.assertEqual(self.prompt(system_append_file=self.write("a.md", "From a file.")),
                         "You are Claude Code.\n\nFrom a file.")
        self.assertEqual(self.prompt(system_prepend_file=self.write("p.md", "Before.")),
                         "Before.\n\nYou are Claude Code.")

    def test_replace_from_file(self):
        self.assertEqual(self.prompt(system_replace_file=self.write("r.md", "Only this.")), "Only this.")

    def test_file_wins_over_inline(self):
        self.assertEqual(self.prompt(system_append="inline", system_append_file=self.write("a.md", "file")),
                         "You are Claude Code.\n\nfile")

    def test_missing_file_falls_back_to_inline(self):
        missing = str(self.dir / "gone.md")
        self.assertEqual(self.prompt(system_append="inline text", system_append_file=missing),
                         "You are Claude Code.\n\ninline text")
        # A missing replace file keeps Claude Code's own prompt rather than dropping it.
        self.assertEqual(self.prompt(system_replace_file=missing), "You are Claude Code.")

    def test_edits_are_picked_up(self):
        path = self.write("a.md", "first")
        mcfg = ap.ModelConfig(upstream="m", system_append_file=path)
        self.assertEqual(ap.system_text([{"type": "text", "text": "base"}], mcfg), "base\n\nfirst")
        time.sleep(0.02)
        Path(path).write_text("second version", encoding="utf-8")
        self.assertEqual(ap.system_text([{"type": "text", "text": "base"}], mcfg), "base\n\nsecond version")


class ApiKeyTests(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp()) / "arli-key.txt"
        patcher = mock.patch.object(ap, "read_api_key", return_value="from-env")
        patcher.start()
        self.addCleanup(patcher.stop)

    def key(self, text=None):
        if text is not None:
            self.path.write_text(text, encoding="utf-8")
        return ap.resolve_api_key(ap.ModelConfig(upstream="m", api_key_file=str(self.path)))

    def test_file_wins_over_env(self):
        self.assertEqual(self.key("# Paste your key below\n\n  'sk-file-123'  \n"), "sk-file-123")

    def test_empty_or_missing_file_falls_back_to_env(self):
        self.assertEqual(self.key(), "from-env")
        self.assertEqual(self.key("# Paste your key below\n\n"), "from-env")

    def test_no_file_configured_uses_env(self):
        self.assertEqual(ap.resolve_api_key(ap.ModelConfig(upstream="m")), "from-env")

    def test_edits_apply_to_the_next_request(self):
        self.assertEqual(self.key("sk-old"), "sk-old")
        time.sleep(0.02)
        self.assertEqual(self.key("sk-new-key"), "sk-new-key")


class ToolTests(unittest.TestCase):
    TOOLS = [
        {"name": "Bash", "description": "Run a command", "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}}},
        {"name": "mcp__x__a", "input_schema": {"type": "object"}, "defer_loading": True},
        {"name": "mcp__x__b", "input_schema": {"type": "object"}, "defer_loading": True},
        {"type": "web_search_20250305", "name": "web_search", "max_uses": 5},
    ]

    def names(self, body):
        return [t["function"]["name"] for t in body.get("tools", [])]

    def test_deferred_tools_load_after_tool_search(self):
        req = {"tools": self.TOOLS, "messages": [{"role": "user", "content": "hi"}]}
        body = build(req)
        self.assertEqual(self.names(body), ["Bash"])
        self.assertEqual(body["tool_choice"], "auto")
        self.assertEqual(body["tools"][0]["function"]["description"], "Run a command")

        req["messages"] += [
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "ToolSearch", "input": {"query": "a"}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "tool_reference", "tool_name": "mcp__x__a"}]}]},
        ]
        body = build(req)
        self.assertEqual(self.names(body), ["Bash", "mcp__x__a"])
        self.assertEqual(body["messages"][-1]["content"], "Tool mcp__x__a is now loaded and can be called.")

    def test_tool_choice(self):
        base = {"tools": self.TOOLS, "messages": [{"role": "user", "content": "hi"}]}
        self.assertEqual(build({**base, "tool_choice": {"type": "any"}})["tool_choice"], "required")
        self.assertEqual(build({**base, "tool_choice": {"type": "none"}})["tool_choice"], "none")
        forced = build({**base, "tool_choice": {"type": "tool", "name": "mcp__x__b", "disable_parallel_tool_use": True}})
        self.assertEqual(forced["tool_choice"], {"type": "function", "function": {"name": "mcp__x__b"}})
        self.assertIn("mcp__x__b", self.names(forced))
        self.assertIs(forced["parallel_tool_calls"], False)


class ParameterTests(unittest.TestCase):
    MESSAGES = [{"role": "user", "content": "hi"}]

    def test_reasoning(self):
        m = self.MESSAGES
        self.assertEqual(build({"messages": m, "output_config": {"effort": "high"}})["reasoning_effort"], "high")
        self.assertEqual(build({"messages": m, "thinking": {"type": "disabled"}})["reasoning_effort"], "none")
        enabled = build({"messages": m, "thinking": {"type": "enabled", "budget_tokens": 5000}})
        self.assertEqual(enabled["thinking_token_budget"], 5000)
        self.assertNotIn("reasoning_effort", build({"messages": m, "thinking": {"type": "adaptive"}}))
        omitted = build({"messages": m, "output_config": {"effort": "high"}}, reasoning_effort="omit")
        self.assertNotIn("reasoning_effort", omitted)
        self.assertEqual(build({"messages": m}, reasoning_effort="medium")["reasoning_effort"], "medium")
        self.assertNotIn("reasoning_effort", build({"messages": m, "output_config": {"effort": "high"}}, reasoning=False))

    def test_sampling_comes_from_params_only(self):
        body = build({"messages": self.MESSAGES, "temperature": 1, "top_k": 5}, params={"temperature": 0.6, "min_p": 0.05})
        self.assertEqual(body["temperature"], 0.6)
        self.assertEqual(body["min_p"], 0.05)
        self.assertNotIn("top_k", body)

    def test_limits_and_formats(self):
        req = {
            "messages": self.MESSAGES, "max_tokens": 32000, "stop_sequences": ["END"], "stream": True,
            "output_config": {"format": {"type": "json_schema", "schema": {"type": "object"}}},
        }
        body = build(req, max_output_tokens=8000)
        self.assertEqual(body["max_completion_tokens"], 8000)
        self.assertEqual(body["stop"], ["END"])
        self.assertEqual(body["stream_options"], {"include_usage": True})
        self.assertEqual(body["response_format"]["json_schema"]["schema"], {"type": "object"})


class ClaudeRequestTests(unittest.TestCase):
    def test_proxy_thinking_is_removed(self):
        req = {"messages": [
            {"role": "user", "content": "q"},
            {"role": "assistant", "content": [{"type": "thinking", "thinking": "t", "signature": "arliproxy:1"}, {"type": "text", "text": "a"}]},
            {"role": "assistant", "content": [{"type": "thinking", "thinking": "t", "signature": "arliproxy:2"}]},
            {"role": "assistant", "content": [{"type": "thinking", "thinking": "real", "signature": "EqQB"}]},
        ]}
        self.assertTrue(ap.strip_proxy_thinking(req))
        self.assertEqual(req["messages"][1]["content"], [{"type": "text", "text": "a"}])
        self.assertEqual(req["messages"][2]["content"], [{"type": "text", "text": "(no reply)"}])
        self.assertEqual(req["messages"][3]["content"][0]["signature"], "EqQB")
        self.assertFalse(ap.strip_proxy_thinking(req))


class StreamTests(unittest.TestCase):
    def test_reasoning_text_and_tool_calls(self):
        events = translate([
            chunk({"role": "assistant", "content": ""}),
            chunk({"reasoning": "Let me "}),
            chunk({"reasoning_content": "check."}),
            chunk({"content": "Running"}),
            chunk({"tool_calls": [{"index": 0, "id": "chatcmpl-tool-1", "type": "function", "function": {"name": "Bash", "arguments": '{"comm'}}]}),
            chunk({"tool_calls": [{"index": 0, "function": {"arguments": 'and": "ls"}'}}]}),
            chunk({"tool_calls": [{"index": 1, "id": "x:y", "function": {"name": "Read", "arguments": '```json\n{"file_path": "a"}\n```'}}]}),
            chunk(finish="tool_calls"),
            {"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": {"cached_tokens": 40}}},
        ])
        assert_well_formed(self, events)
        message = ap.collect_message(events)
        thinking, text, bash, read = message["content"]
        self.assertEqual(thinking["thinking"], "Let me check.")
        self.assertTrue(thinking["signature"].startswith(ap.SIGNATURE_PREFIX))
        self.assertEqual(text, {"type": "text", "text": "Running"})
        self.assertEqual((bash["id"], bash["name"], bash["input"]), ("chatcmpl-tool-1", "Bash", {"command": "ls"}))
        self.assertEqual((read["id"], read["input"]), ("x_y", {"file_path": "a"}))
        self.assertEqual(message["stop_reason"], "tool_use")
        self.assertEqual(message["usage"], {"input_tokens": 60, "output_tokens": 20, "cache_read_input_tokens": 40, "cache_creation_input_tokens": 0})

    def test_inline_think_tags_split_across_chunks(self):
        events = translate([chunk({"content": c}) for c in ["<thi", "nk>reason", "ing</th", "ink>\n\nanswer"]] + [chunk(finish="stop")])
        assert_well_formed(self, events)
        content = ap.collect_message(events)["content"]
        self.assertEqual([(b["type"], b.get("thinking", b.get("text"))) for b in content], [("thinking", "reasoning"), ("text", "answer")])

    def test_plain_text_streams_immediately(self):
        tr = ap.StreamTranslator("arli/m")
        tr.start()
        self.assertEqual(tr.feed(chunk({"content": "Hello"}))[-1][1]["delta"], {"type": "text_delta", "text": "Hello"})
        events = translate([chunk({"content": c}) for c in ["<", "b>bold"]] + [chunk(finish="stop")])
        self.assertEqual(ap.collect_message(events)["content"], [{"type": "text", "text": "<b>bold"}])

    def test_stop_reasons(self):
        self.assertEqual(ap.collect_message(translate([chunk({"content": "x"}, "length")]))["stop_reason"], "max_tokens")
        stopped = ap.collect_message(translate([chunk({"content": "x"}, "stop", stop_reason="END")], stops=["END"]))
        self.assertEqual((stopped["stop_reason"], stopped["stop_sequence"]), ("stop_sequence", "END"))
        self.assertEqual(ap.collect_message(translate([chunk({"content": "x"}, "stop")]))["stop_reason"], "end_turn")

    def test_error_chunk(self):
        with self.assertRaises(ap.UpstreamStreamError):
            ap.StreamTranslator("m").feed({"error": {"message": "boom"}})

    def test_tool_arguments(self):
        self.assertEqual(ap.parse_tool_arguments('{"a": 1}'), {"a": 1})
        self.assertEqual(ap.parse_tool_arguments('"{\\"a\\": 1}"'), {"a": 1})
        self.assertEqual(ap.parse_tool_arguments('Sure: {"a": 1} done'), {"a": 1})
        self.assertEqual(ap.parse_tool_arguments(""), {})
        self.assertEqual(ap.parse_tool_arguments("[1, 2]"), {})

    def test_non_streaming_completion(self):
        message = ap.message_from_completion({
            "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
                "role": "assistant", "reasoning_content": "hmm", "content": "Reading.",
                "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "Read", "arguments": '{"file_path": "x"}'}}],
            }}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5},
        }, "arli/m")
        self.assertEqual([b["type"] for b in message["content"]], ["thinking", "text", "tool_use"])
        self.assertEqual(message["content"][2]["input"], {"file_path": "x"})
        self.assertEqual(message["stop_reason"], "tool_use")
        self.assertEqual(message["usage"]["input_tokens"], 10)


class ErrorTests(unittest.TestCase):
    def mapped(self, status, message, headers=None):
        return ap.map_upstream_error(status, json.dumps({"error": {"message": message}}).encode(), headers or {})

    def test_context_errors_become_prompt_too_long(self):
        status, kind, message, _ = self.mapped(400, "This model's maximum context length is 131072 tokens. "
                                                    "However, your request has 140000 input tokens.")
        self.assertEqual((status, kind), (400, "invalid_request_error"))
        self.assertTrue(message.startswith("prompt is too long: 140000 tokens > 131072 maximum"))
        _, _, message, _ = self.mapped(400, "This model's maximum context length is 131072 tokens. However, you "
                                            "requested 150000 tokens (140000 in the messages, 10000 in the completion).")
        self.assertTrue(message.startswith("prompt is too long: 140000 tokens > 131072 maximum"))

    def test_output_budget_shrinks_when_only_max_tokens_overflows(self):
        message = ("'max_tokens' or 'max_completion_tokens' is too large: 32000. This model's maximum context length "
                   "is 202752 tokens and your request has 180000 input tokens (32000 > 202752 - 180000).")
        self.assertEqual(ap.shrink_output_budget({"max_completion_tokens": 32000}, message)["max_completion_tokens"], 22688)
        self.assertIsNone(ap.shrink_output_budget({"max_completion_tokens": 32000}, "bad request"))

    def test_status_mapping(self):
        self.assertEqual(self.mapped(401, "bad key")[:2], (400, "invalid_request_error"))
        status, kind, _, headers = self.mapped(429, "slow down", {"retry-after": "30"})
        self.assertEqual((status, kind, headers), (429, "rate_limit_error", (("retry-after", "30"),)))
        self.assertEqual(self.mapped(503, "busy")[:2], (503, "overloaded_error"))
        self.assertEqual(self.mapped(404, "no such model")[:2], (404, "not_found_error"))


# Integration tests against fake upstream servers


class QuietServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # the proxy drops upstream connections on purpose in several tests


class FakeUpstream:
    """A local HTTP server whose responses each test scripts."""

    def __init__(self, respond):
        self.requests = []
        self.respond = respond
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                outer.handle(self)

            do_POST = do_HEAD = do_GET

        self.server = QuietServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def handle(self, h):
        length = int(h.headers.get("Content-Length") or 0)
        body = h.rfile.read(length) if length else b""
        record = SimpleNamespace(method=h.command, path=h.path, headers=h.headers, body=body, json=ap.load_object(body))
        self.requests.append(record)
        with contextlib.suppress(OSError):
            self.respond(h, record)

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def reply_json(h, status, data, headers=()):
    body = json.dumps(data).encode()
    h.send_response(status)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(body)))
    for name, value in headers:
        h.send_header(name, value)
    h.end_headers()
    h.wfile.write(body)


def reply_sse(h, chunks, delay=0.0, done=True):
    h.send_response(200)
    h.send_header("Content-Type", "text/event-stream")
    h.send_header("Transfer-Encoding", "chunked")
    h.end_headers()
    payloads = [c if isinstance(c, bytes) else f"data: {json.dumps(c)}\n\n".encode() for c in chunks]
    if done:
        payloads.append(b"data: [DONE]\n\n")
    for payload in payloads:
        time.sleep(delay)
        h.wfile.write(b"%x\r\n%s\r\n" % (len(payload), payload))
    h.wfile.write(b"0\r\n\r\n")


def parse_events(raw: bytes):
    events = []
    for block in raw.decode().split("\n\n"):
        lines = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
        if "event" in lines:
            events.append((lines["event"], json.loads(lines["data"])))
    return events


SIMPLE_REPLY = [chunk({"content": "Hello"}), chunk(finish="stop"), {"choices": [], "usage": {"prompt_tokens": 12, "completion_tokens": 1}}]


def arli_router(chat, tokenize=None):
    def respond(h, record):
        if record.path == "/model/all":
            reply_json(h, 200, CATALOG)
        elif record.path == "/v1/tokenize":
            reply_json(h, 200, tokenize or {"count": 0})
        else:
            chat(h, record)
    return respond


def anthropic_echo(h, record):
    reply_sse(h, [b"event: message_start\ndata: {\"type\":\"message_start\"}\n\n"], done=False)


def toml_value(value):
    return json.dumps(value) if not isinstance(value, bool) else str(value).lower()


class ProxyTests(unittest.TestCase):
    def setUp(self):
        os.environ[KEY_ENV] = "arli-test-key"
        self.addCleanup(os.environ.pop, KEY_ENV, None)
        self.tmp = Path(tempfile.mkdtemp())

    def start(self, chat, anthropic=anthropic_echo, extra_toml="", tokenize=None, **settings):
        self.arli = FakeUpstream(arli_router(chat, tokenize))
        self.anthropic = FakeUpstream(anthropic)
        self.addCleanup(self.arli.close)
        self.addCleanup(self.anthropic.close)
        values = {"listen_port": 0, "anthropic_url": self.anthropic.url, "arli_url": self.arli.url,
                  "ping_interval": 5, "commit_after": 5, **settings}
        self.config = self.tmp / "config.toml"
        self.config.write_text("\n".join(f"{k} = {toml_value(v)}" for k, v in values.items())
                               + f'\n[defaults]\napi_key_env = "{KEY_ENV}"\n' + extra_toml, encoding="utf-8")
        self.proxy = ap.Server(ap.ConfigStore(self.config, check_interval=0))
        threading.Thread(target=self.proxy.serve_forever, daemon=True).start()
        self.addCleanup(self.proxy.server_close)
        self.addCleanup(self.proxy.shutdown)

    def post(self, payload, path="/v1/messages?beta=true", headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.proxy.server_address[1], timeout=20)
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        conn.request("POST", path, body, {"Content-Type": "application/json", **(headers or {})})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp, data

    def arli_request(self, **fields):
        return {"model": "arli/test-model", "max_tokens": 1000, "stream": True,
                "messages": [{"role": "user", "content": "hi"}], **fields}

    def test_claude_requests_pass_through_unchanged(self):
        self.start(lambda h, r: None)
        body = json.dumps({"model": "claude-opus-5-5", "messages": [{"role": "user", "content": "hi"}]}).encode()
        resp, data = self.post(body, headers={"Authorization": "Bearer sk-ant-oat-1", "anthropic-beta": "oauth-2025-04-20"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(data, b"event: message_start\ndata: {\"type\":\"message_start\"}\n\n")
        seen = self.anthropic.requests[0]
        self.assertEqual((seen.path, seen.body), ("/v1/messages?beta=true", body))
        self.assertEqual(seen.headers["Authorization"], "Bearer sk-ant-oat-1")
        self.assertEqual(seen.headers["anthropic-beta"], "oauth-2025-04-20")
        self.assertEqual(self.arli.requests, [])

    def test_claude_requests_lose_proxy_thinking(self):
        self.start(lambda h, r: None)
        self.post({"model": "claude-opus-5-5", "messages": [
            {"role": "user", "content": "q"},
            {"role": "assistant", "content": [{"type": "thinking", "thinking": "t", "signature": "arliproxy:1"}, {"type": "text", "text": "a"}]},
            {"role": "user", "content": "q2"},
        ]})
        self.assertEqual(self.anthropic.requests[0].json["messages"][1]["content"], [{"type": "text", "text": "a"}])

    def test_arli_stream_end_to_end(self):
        self.start(lambda h, r: reply_sse(h, SIMPLE_REPLY))
        resp, data = self.post(self.arli_request(), headers={"Authorization": "Bearer sk-ant-oat-1", "anthropic-beta": "x"})
        self.assertEqual(resp.status, 200)
        self.assertTrue(resp.getheader("Content-Type").startswith("text/event-stream"))
        events = parse_events(data)
        assert_well_formed(self, events)
        message = ap.collect_message(events)
        self.assertEqual(message["content"], [{"type": "text", "text": "Hello"}])
        self.assertEqual(message["model"], "arli/test-model")
        self.assertEqual(message["usage"]["input_tokens"], 12)
        chat = self.arli.requests[-1]
        self.assertEqual(chat.path, "/v1/chat/completions")
        self.assertEqual(chat.headers["Authorization"], "Bearer arli-test-key")
        self.assertIsNone(chat.headers.get("anthropic-beta"))
        self.assertEqual(chat.json["model"], "test-model")
        self.assertEqual(self.anthropic.requests, [])

    def test_non_streaming_request(self):
        def chat(h, record):
            reply_json(h, 200, {"choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "Hi"}}],
                                "usage": {"prompt_tokens": 3, "completion_tokens": 1}})
        self.start(chat)
        resp, data = self.post(self.arli_request(stream=False))
        message = json.loads(data)
        self.assertEqual((resp.status, message["content"], message["stop_reason"]), (200, [{"type": "text", "text": "Hi"}], "end_turn"))

    def test_context_error_becomes_prompt_too_long(self):
        self.start(lambda h, r: reply_json(h, 400, {"error": {"message": "This model's maximum context length is 1000 tokens. "
                                                                         "However, your request has 1500 input tokens."}}))
        resp, data = self.post(self.arli_request())
        self.assertEqual(resp.status, 400)
        self.assertEqual(resp.getheader("x-should-retry"), "false")
        self.assertTrue(json.loads(data)["error"]["message"].startswith("prompt is too long: 1500 tokens > 1000 maximum"))

    def test_output_budget_retry(self):
        def chat(h, record):
            if record.json["max_completion_tokens"] == 32000:
                reply_json(h, 400, {"error": {"message": "This model's maximum context length is 202752 tokens and your "
                                                         "request has 180000 input tokens (32000 > 202752 - 180000)."}})
            else:
                reply_sse(h, SIMPLE_REPLY)
        self.start(chat)
        resp, data = self.post(self.arli_request(max_tokens=32000))
        self.assertEqual(resp.status, 200)
        self.assertEqual([r.json["max_completion_tokens"] for r in self.arli.requests if r.json], [32000, 22688])

    def test_parallel_limit(self):
        active, peak, lock = [0], [0], threading.Lock()

        def chat(h, record):
            with lock:
                active[0] += 1
                peak[0] = max(peak[0], active[0])
            time.sleep(0.3)
            with lock:
                active[0] -= 1
            reply_sse(h, SIMPLE_REPLY)

        self.start(chat, max_parallel=1)
        statuses = []
        threads = [threading.Thread(target=lambda: statuses.append(self.post(self.arli_request())[0].status)) for _ in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(statuses, [200, 200, 200])
        self.assertEqual(peak[0], 1)

    def test_slow_upstream_gets_pings_first(self):
        def chat(h, record):
            time.sleep(0.8)
            reply_sse(h, SIMPLE_REPLY)
        self.start(chat, commit_after=0.2, ping_interval=0.1)
        _, data = self.post(self.arli_request())
        names = [name for name, _ in parse_events(data)]
        self.assertEqual(names[0], "message_start")
        self.assertEqual(names[1], "ping")
        self.assertIn("content_block_delta", names)

    def test_late_upstream_error_arrives_as_event(self):
        def chat(h, record):
            time.sleep(0.5)
            reply_json(h, 503, {"error": {"message": "busy"}})
        self.start(chat, commit_after=0.1, ping_interval=0.1)
        resp, data = self.post(self.arli_request())
        self.assertEqual(resp.status, 200)
        name, error = parse_events(data)[-1]
        self.assertEqual((name, error["error"]["type"]), ("error", "overloaded_error"))

    def test_truncated_stream_reports_an_error(self):
        self.start(lambda h, r: reply_sse(h, [chunk({"content": "Hel"})], done=False))
        _, data = self.post(self.arli_request())
        name, error = parse_events(data)[-1]
        self.assertEqual(name, "error")
        self.assertIn("before the reply was complete", error["error"]["message"])

    def test_client_disconnect_frees_the_slot(self):
        def chat(h, record):
            if record.json["messages"][-1]["content"] == "slow":
                reply_sse(h, [chunk({"content": "."})] * 100, delay=0.05)
            else:
                reply_sse(h, SIMPLE_REPLY)

        self.start(chat, max_parallel=1)
        sock = socket.create_connection(("127.0.0.1", self.proxy.server_address[1]))
        body = json.dumps(self.arli_request(messages=[{"role": "user", "content": "slow"}])).encode()
        sock.sendall(b"POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                     b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        received, deadline = b"", time.monotonic() + 5
        while b"content_block_delta" not in received and time.monotonic() < deadline:
            received += sock.recv(65536)
        self.assertIn(b"content_block_delta", received)
        sock.close()
        started = time.monotonic()
        resp, _ = self.post(self.arli_request())
        self.assertEqual(resp.status, 200)
        self.assertLess(time.monotonic() - started, 3)

    def test_web_search_goes_to_claude(self):
        self.start(lambda h, r: None, server_tool_model="claude-haiku-5-5")
        self.post(self.arli_request(tools=[{"type": "web_search_20250305", "name": "web_search"}]),
                  headers={"Authorization": "Bearer sk-ant-oat-1"})
        seen = self.anthropic.requests[0]
        self.assertEqual(seen.json["model"], "claude-haiku-5-5")
        self.assertEqual(seen.headers["Authorization"], "Bearer sk-ant-oat-1")
        self.assertFalse([r for r in self.arli.requests if r.path == "/v1/chat/completions"])

    def test_without_login_claude_requests_go_to_no_login_model(self):
        self.start(lambda h, r: reply_sse(h, SIMPLE_REPLY), no_login_model="test-model")
        resp, data = self.post({"model": "claude-haiku-5-5", "max_tokens": 100, "stream": True,
                                "messages": [{"role": "user", "content": "title this"}]},
                               headers={"Authorization": f"Bearer {ap.NO_LOGIN_TOKEN}"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(ap.collect_message(parse_events(data))["model"], "claude-haiku-5-5")
        chat = self.arli.requests[-1]
        self.assertEqual((chat.path, chat.json["model"]), ("/v1/chat/completions", "test-model"))
        self.assertEqual(chat.headers["Authorization"], "Bearer arli-test-key")
        self.assertEqual(self.anthropic.requests, [])

    def test_without_login_and_no_login_model_nothing_reaches_anthropic(self):
        self.start(lambda h, r: None)
        resp, data = self.post({"model": "claude-opus-5-5", "messages": [{"role": "user", "content": "hi"}]},
                               headers={"x-api-key": ap.NO_LOGIN_TOKEN})
        self.assertEqual(resp.status, 400)
        self.assertIn("not logged in", json.loads(data)["error"]["message"])
        self.assertEqual(self.anthropic.requests, [])

    def test_without_login_web_search_stays_on_arliai(self):
        self.start(lambda h, r: reply_sse(h, SIMPLE_REPLY), server_tool_model="claude-haiku-5-5")
        resp, _ = self.post(self.arli_request(tools=[{"type": "web_search_20250305", "name": "web_search"}]),
                            headers={"Authorization": f"Bearer {ap.NO_LOGIN_TOKEN}"})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.anthropic.requests, [])
        self.assertNotIn("tools", self.arli.requests[-1].json)

    def test_count_tokens_uses_tokenize(self):
        self.start(lambda h, r: None, tokenize={"count": 1234, "max_model_len": 262144})
        resp, data = self.post({"model": "arli/test-model", "messages": [{"role": "user", "content": "hi"}]},
                               path="/v1/messages/count_tokens?beta=true")
        self.assertEqual((resp.status, json.loads(data)), (200, {"input_tokens": 1234}))
        self.assertEqual(self.arli.requests[-1].json["messages"], [{"role": "user", "content": "hi"}])

    def test_missing_key(self):
        os.environ.pop(KEY_ENV)
        self.start(lambda h, r: None)
        with mock.patch.object(ap, "read_api_key", return_value=None):
            resp, data = self.post(self.arli_request())
        self.assertEqual(resp.status, 400)
        self.assertIn(f"the {KEY_ENV} variable", json.loads(data)["error"]["message"])

    def test_key_file_reaches_arliai(self):
        (self.tmp / "key.txt").write_text("# comment\nsk-from-file\n", encoding="utf-8")
        self.start(lambda h, r: reply_sse(h, SIMPLE_REPLY), extra_toml='api_key_file = "key.txt"\n')
        self.post(self.arli_request())
        self.assertEqual(self.arli.requests[-1].headers["Authorization"], "Bearer sk-from-file")

    def test_vision_flag_comes_from_the_catalog(self):
        self.start(lambda h, r: reply_sse(h, SIMPLE_REPLY))
        image = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}}
        self.post(self.arli_request(model="arli/big-model", messages=[{"role": "user", "content": [image]}]))
        self.assertIn("image omitted", self.arli.requests[-1].json["messages"][0]["content"])

    def test_config_changes_apply_to_the_next_request(self):
        self.start(lambda h, r: reply_sse(h, SIMPLE_REPLY))
        self.post(self.arli_request())
        self.assertNotIn("temperature", self.arli.requests[-1].json)
        time.sleep(0.05)
        self.config.write_text(self.config.read_text() + '\n[models."test-model".params]\ntemperature = 0.4\n')
        self.post(self.arli_request())
        self.assertEqual(self.arli.requests[-1].json["temperature"], 0.4)

    def test_health(self):
        self.start(lambda h, r: None)
        conn = http.client.HTTPConnection("127.0.0.1", self.proxy.server_address[1], timeout=5)
        conn.request("GET", ap.HEALTH_PATH)
        self.assertEqual(json.loads(conn.getresponse().read())["ok"], True)
        conn.close()


class FakeTunnel:
    """An HTTP proxy that only answers CONNECT, the way an HTTPS_PROXY does."""

    def __init__(self):
        self.targets = []
        outer = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                target = self.rfile.readline().split()[1].decode()
                while self.rfile.readline() not in (b"\r\n", b""):
                    pass
                outer.targets.append(target)
                host, port = target.rsplit(":", 1)
                with socket.create_connection((host, int(port))) as upstream:
                    self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
                    threading.Thread(target=self.pipe, args=(upstream, self.connection), daemon=True).start()
                    self.pipe(self.connection, upstream)

            @staticmethod
            def pipe(src, dst):
                with contextlib.suppress(OSError):
                    while data := src.recv(65536):
                        dst.sendall(data)
                    dst.shutdown(socket.SHUT_WR)

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class UpstreamProxyTests(unittest.TestCase):
    def setUp(self):
        self.upstream = FakeUpstream(lambda h, r: reply_json(h, 200, CATALOG))
        self.tunnel = FakeTunnel()
        self.addCleanup(self.upstream.close)
        self.addCleanup(self.tunnel.close)
        self.target = self.upstream.url.removeprefix("http://")

    def environ(self, **values):
        names = ("http_proxy", "https_proxy", "no_proxy", "all_proxy")
        cleared = {n: "" for name in names for n in (name, name.upper())}
        return mock.patch.dict(os.environ, {**cleared, **values})

    def test_requests_go_through_the_proxy_variable(self):
        with self.environ(http_proxy=self.tunnel.url):
            self.assertEqual(ap.fetch_catalog(self.upstream.url, timeout=5), CATALOG)
        self.assertEqual(self.tunnel.targets, [self.target])

    def test_no_proxy_connects_directly(self):
        with self.environ(http_proxy=self.tunnel.url, no_proxy="127.0.0.1"):
            self.assertEqual(ap.fetch_catalog(self.upstream.url, timeout=5), CATALOG)
        self.assertEqual(self.tunnel.targets, [])


class ConfigTests(unittest.TestCase):
    def test_typos_are_rejected(self):
        path = Path(tempfile.mkdtemp()) / "config.toml"
        path.write_text('[models."x"]\ntemprature = 1\n')
        with self.assertRaisesRegex(ValueError, "temprature"):
            ap.load_config(path)
        path.write_text("max_paralel = 2\n")
        with self.assertRaisesRegex(ValueError, "max_paralel"):
            ap.load_config(path)

    def test_proxy_options_inside_params_are_rejected(self):
        path = Path(tempfile.mkdtemp()) / "config.toml"
        path.write_text('[models."x".params]\ntemperature = 0.7\nsystem_append_file = "a.md"\n')
        with self.assertRaisesRegex(ValueError, r'system_append_file.*Move them up into \[models\."x"\]'):
            ap.load_config(path)

    def test_system_prompt_file_path_resolves_against_config_dir(self):
        d = Path(tempfile.mkdtemp())
        (d / "prompt.md").write_text("hello", encoding="utf-8")
        cfg_path = d / "config.toml"
        cfg_path.write_text('[models.x]\nsystem_append_file = "prompt.md"\n', encoding="utf-8")
        model = ap.load_config(cfg_path).model("x")
        self.assertTrue(Path(model.system_append_file).is_absolute())
        self.assertEqual(Path(model.system_append_file).read_text(encoding="utf-8"), "hello")

    def test_model_options_merge_over_defaults(self):
        path = Path(tempfile.mkdtemp()) / "config.toml"
        path.write_text('[defaults]\nthink_tags = false\n[defaults.params]\ntop_p = 0.9\ntemperature = 1.0\n'
                        '[models.glm]\nupstream = "GLM-4.7"\n[models.glm.params]\ntemperature = 0.5\n')
        model = ap.load_config(path).model("glm")
        self.assertEqual((model.upstream, model.think_tags, model.params), ("GLM-4.7", False, {"top_p": 0.9, "temperature": 0.5}))


if __name__ == "__main__":
    unittest.main()
