"""Local gateway that lets Claude Code use ArliAI models beside a claude.ai login.

Requests for Claude models are relayed to Anthropic unchanged, so the
subscription login keeps working. Requests for "arli/<model>" are translated
from the Anthropic Messages API to ArliAI's OpenAI style chat completions API
and back.
"""

from __future__ import annotations

import argparse
import contextlib
import http.client
import json
import logging
import os
import queue
import re
import socket
import ssl
import sys
import threading
import time
import tomllib
import uuid
from dataclasses import dataclass, field, fields
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit
from urllib.request import getproxies, proxy_bypass

USER_AGENT = "claude-arli-proxy/1"

HEALTH_PATH = "/__arli_proxy/health"
MESSAGE_PATHS = {"/v1/messages": "messages", "/v1/messages/count_tokens": "count_tokens"}
# Thinking blocks this proxy creates carry this signature prefix. Anthropic
# rejects foreign signatures, so these blocks are dropped from Claude requests.
SIGNATURE_PREFIX = "arliproxy:"
# Claude Code's attribution block. api.anthropic.com strips it, other models would read it.
BILLING_HEADER_PREFIX = "x-anthropic-billing-header:"
HOP_BY_HOP = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
    "trailer", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
})
STALE_CONNECTION_ERRORS = (
    http.client.RemoteDisconnected, ConnectionResetError, ConnectionAbortedError, BrokenPipeError,
)
# Anthropic server tools that only Claude can run. Requests that carry them are
# answered by `server_tool_model` instead of the ArliAI model.
SERVER_TOOL_PREFIXES = ("web_search", "web_fetch")
STOP_REASONS = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use", "function_call": "tool_use"}
NO_RETRY = (("x-should-retry", "false"),)
# Claude Code will not start without a credential, so a launcher sets this as
# ANTHROPIC_AUTH_TOKEN when there is no claude.ai login. Requests carrying it
# never reach Anthropic.
NO_LOGIN_TOKEN = "arli-proxy-no-login"
TOOL_ID_INVALID = re.compile(r"[^A-Za-z0-9_-]")
MIN_OUTPUT_TOKENS = 1024

# Each system_* string has a _file twin that names an .md file read in its place.
SYSTEM_FILE_KEYS = ("system_prepend_file", "system_append_file", "system_replace_file")
# Options holding a path, which a relative value resolves against the config file's folder.
PATH_KEYS = (*SYSTEM_FILE_KEYS, "api_key_file")
MODEL_OPTIONS = frozenset({
    "upstream", "vision", "reasoning_effort", "reasoning_history", "max_output_tokens",
    "system_prepend", "system_append", "system_replace", "think_tags", "api_key_env", "params",
    *PATH_KEYS,
})
REASONING_HISTORY = ("current_turn", "all", "none")

log = logging.getLogger("arli_proxy")
SSL_CONTEXT = ssl.create_default_context()


class ClientGone(Exception):
    """Claude Code closed its connection to the proxy."""


class UpstreamStreamError(Exception):
    """ArliAI failed in the middle of a stream."""


# Configuration


@dataclass(frozen=True)
class ModelConfig:
    upstream: str
    vision: bool | None = None
    reasoning_effort: str = "auto"
    reasoning_history: str = "current_turn"
    max_output_tokens: int | None = None
    system_prepend: str = ""
    system_prepend_file: str = ""
    system_append: str = ""
    system_append_file: str = ""
    system_replace: str | None = None
    system_replace_file: str = ""
    think_tags: bool = True
    api_key_env: str = "ARLIAI_API_KEY"
    api_key_file: str = ""
    params: dict = field(default_factory=dict)


@dataclass(frozen=True)
class Config:
    listen_host: str = "127.0.0.1"
    listen_port: int = 8790
    anthropic_url: str = "https://api.anthropic.com"
    arli_url: str = "https://api.arliai.com"
    model_prefix: str = "arli/"
    max_parallel: int = 6
    server_tool_model: str = "claude-haiku-5-5"
    no_login_model: str = ""
    ping_interval: float = 10.0
    commit_after: float = 15.0
    upstream_timeout: float = 600.0
    log_level: str = "INFO"
    defaults: dict = field(default_factory=dict)
    models: dict = field(default_factory=dict)

    def model(self, name: str) -> ModelConfig:
        table = self.models.get(name, {})
        merged = {**self.defaults, **table}
        merged["params"] = {**self.defaults.get("params", {}), **table.get("params", {})}
        merged.setdefault("upstream", name)
        return ModelConfig(**merged)


def load_config(path: Path) -> Config:
    with path.open("rb") as f:
        raw = tomllib.load(f)
    unknown = raw.keys() - {f.name for f in fields(Config)}
    if unknown:
        raise ValueError(f"unknown setting(s): {', '.join(sorted(unknown))}")
    cfg = Config(**raw)
    base = path.resolve().parent
    tables = [("defaults", cfg.defaults), *((f'models."{n}"', t) for n, t in cfg.models.items())]
    for label, table in tables:
        if not isinstance(table, dict):
            raise ValueError(f"[{label}] must be a table")
        bad = table.keys() - MODEL_OPTIONS
        if bad:
            raise ValueError(f"unknown option(s) in [{label}]: {', '.join(sorted(bad))}")
        if table.get("reasoning_history", "current_turn") not in REASONING_HISTORY:
            raise ValueError(f"[{label}] reasoning_history must be one of {', '.join(REASONING_HISTORY)}")
        if not isinstance(table.get("params", {}), dict):
            raise ValueError(f"[{label}] params must be a table")
        # params goes to ArliAI verbatim, so a proxy option placed there would be sent as a request field and do nothing.
        misplaced = table.get("params", {}).keys() & MODEL_OPTIONS
        if misplaced:
            raise ValueError(f"[{label}.params] holds proxy option(s) {', '.join(sorted(misplaced))}. "
                             f"Move them up into [{label}]")
        for key in PATH_KEYS:
            value = table.get(key)
            if isinstance(value, str) and value and not Path(value).is_absolute():
                table[key] = str((base / value).resolve())
    return cfg


class ConfigStore:
    """Serves the current config and reloads it when the file changes."""

    def __init__(self, path: Path, check_interval: float = 1.0):
        self.path = path
        self._check_interval = check_interval
        self._lock = threading.Lock()
        self._cfg = load_config(path)
        self._mtime = path.stat().st_mtime_ns
        self._checked = time.monotonic()

    def get(self) -> Config:
        if time.monotonic() - self._checked < self._check_interval:
            return self._cfg
        with self._lock:
            self._checked = time.monotonic()
            try:
                mtime = self.path.stat().st_mtime_ns
            except OSError:
                return self._cfg
            if mtime != self._mtime:
                self._mtime = mtime
                try:
                    self._cfg = load_config(self.path)
                    log.info("reloaded %s", self.path.name)
                except (OSError, ValueError, TypeError, tomllib.TOMLDecodeError) as exc:
                    log.error("kept the previous settings because %s is invalid: %s", self.path.name, exc)
        return self._cfg


def read_api_key(env_name: str) -> str | None:
    return os.environ.get(env_name, "").strip() or None


# Upstream connections


def connect(base_url: str, timeout: float) -> tuple[http.client.HTTPConnection, str]:
    """Connect directly, or through a CONNECT tunnel when HTTPS_PROXY or HTTP_PROXY covers the host."""
    parts = urlsplit(base_url)
    https = parts.scheme == "https"
    proxy = None if proxy_bypass(parts.hostname) else getproxies().get(parts.scheme)
    host, port = parts.hostname, parts.port
    if proxy:
        via = urlsplit(proxy if "://" in proxy else f"http://{proxy}")
        host, port = via.hostname, via.port or 80
    if https:
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=SSL_CONTEXT)
    else:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
    if proxy:
        conn.set_tunnel(parts.hostname, parts.port or (443 if https else 80))
    return conn, parts.path.rstrip("/")


def abort(conn: http.client.HTTPConnection | None) -> None:
    """Close a connection that another thread may be blocked reading from."""
    if conn is None:
        return
    if conn.sock is not None:
        with contextlib.suppress(OSError):
            conn.sock.shutdown(socket.SHUT_RDWR)
    conn.close()


def request_json(base_url: str, method: str, path: str, payload, key: str | None, timeout: float):
    conn, prefix = connect(base_url, timeout)
    try:
        headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        data = None
        if payload is not None:
            data = json.dumps(payload, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        conn.request(method, prefix + path, data, headers)
        resp = conn.getresponse()
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw else None)
    finally:
        conn.close()


def fetch_catalog(arli_url: str, timeout: float) -> list[dict]:
    status, data = request_json(arli_url, "GET", "/model/all", None, None, timeout)
    if status != 200 or not isinstance(data, list):
        raise ValueError(f"/model/all answered HTTP {status}")
    return [m for m in data if isinstance(m, dict) and isinstance(m.get("name"), str)]


class ConnectionPool:
    """Keeps idle connections to Anthropic so Claude requests skip a TLS handshake."""

    def __init__(self, size: int = 8):
        self._size = size
        self._idle: dict[str, list] = {}
        self._lock = threading.Lock()

    def get(self, base_url: str, timeout: float):
        with self._lock:
            idle = self._idle.get(base_url)
            if idle:
                conn, prefix = idle.pop()
                return conn, prefix, True
        conn, prefix = connect(base_url, timeout)
        return conn, prefix, False

    def put(self, base_url: str, conn, prefix: str) -> None:
        with self._lock:
            idle = self._idle.setdefault(base_url, [])
            if len(idle) < self._size:
                idle.append((conn, prefix))
                return
        conn.close()

    def close(self) -> None:
        with self._lock:
            idle, self._idle = self._idle, {}
        for conns in idle.values():
            for conn, _ in conns:
                conn.close()


class Limiter:
    """Caps in-flight ArliAI generations, because ArliAI rejects requests over the plan's limit."""

    def __init__(self, limit):
        self._limit = limit
        self._active = 0
        self._cond = threading.Condition()

    def acquire(self, cancel: threading.Event) -> bool:
        with self._cond:
            while self._active >= max(1, self._limit()):
                if cancel.is_set():
                    return False
                self._cond.wait(0.5)
            self._active += 1
            return True

    def release(self) -> None:
        with self._cond:
            self._active -= 1
            self._cond.notify()


class ModelCatalog:
    """ArliAI's public model list, read for each model's vision and reasoning flags."""

    TTL = 3600.0
    RETRY_AFTER = 60.0

    def __init__(self):
        self._lock = threading.Lock()
        self._models: dict[str, dict] = {}
        self._fetched = float("-inf")
        self._attempted = float("-inf")

    def get(self, arli_url: str, name: str) -> dict | None:
        with self._lock:
            now = time.monotonic()
            if now - self._fetched > self.TTL and now - self._attempted > self.RETRY_AFTER:
                self._attempted = now
                try:
                    self._models = {m["name"]: m for m in fetch_catalog(arli_url, timeout=5)}
                    self._fetched = now
                except (OSError, ValueError, http.client.HTTPException) as exc:
                    log.warning("could not read ArliAI's model list: %s", exc)
            return self._models.get(name)


# Anthropic request to OpenAI request


def blocks(content) -> list[dict]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def flatten_text(content) -> str:
    return "\n\n".join(b["text"] for b in blocks(content) if isinstance(b.get("text"), str) and b["text"])


def text_part(text: str) -> dict:
    return {"type": "text", "text": text}


def tool_id(raw) -> str:
    if isinstance(raw, str):
        clean = TOOL_ID_INVALID.sub("_", raw)
        if clean:
            return clean
    return f"toolu_{uuid.uuid4().hex[:24]}"


def dump_json(data) -> bytes:
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode()


def load_object(raw: bytes | None) -> dict | None:
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def is_proxy_thinking(block) -> bool:
    return (
        isinstance(block, dict)
        and block.get("type") == "thinking"
        and str(block.get("signature", "")).startswith(SIGNATURE_PREFIX)
    )


def strip_proxy_thinking(req: dict) -> bool:
    """Remove thinking blocks that ArliAI produced, so Anthropic does not reject their signature."""
    changed = False
    for msg in req.get("messages") or ():
        content = msg.get("content") if isinstance(msg, dict) else None
        if msg.get("role") != "assistant" or not isinstance(content, list):
            continue
        kept = [b for b in content if not is_proxy_thinking(b)]
        if len(kept) != len(content):
            msg["content"] = kept or [{"type": "text", "text": "(no reply)"}]
            changed = True
    return changed


def uses_server_tools(req: dict) -> bool:
    return any(
        isinstance(t, dict) and str(t.get("type", "")).startswith(SERVER_TOOL_PREFIXES)
        for t in req.get("tools") or ()
    )


def referenced_tools(messages) -> set[str]:
    """Deferred tools that Claude Code's tool search has loaded, through tool_reference blocks."""
    names = set()
    for msg in messages:
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        for block in blocks(msg.get("content")):
            inner = block.get("content") if block.get("type") == "tool_result" else [block]
            for ref in blocks(inner):
                if ref.get("type") == "tool_reference" and ref.get("tool_name"):
                    names.add(ref["tool_name"])
    return names


def last_prompt_index(messages) -> int:
    """Index of the newest user message that starts a turn instead of returning tool results."""
    for i in range(len(messages) - 1, -1, -1):
        msg = messages[i]
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        if not any(b.get("type") == "tool_result" for b in blocks(msg.get("content"))):
            return i
    return -1


def document_text(block: dict) -> str:
    source = block.get("source") or {}
    if source.get("type") == "text" and source.get("data"):
        return source["data"]
    if source.get("type") == "content":
        text = flatten_text(source.get("content"))
        if text:
            return text
    title = block.get("title")
    named = f' "{title}"' if title else ""
    return f"[document{named} omitted: ArliAI models cannot read PDF files]"


def web_results_text(block: dict) -> str:
    results = [r for r in blocks(block.get("content")) if r.get("url")]
    if not results:
        return ""
    return "Web search results:\n" + "\n".join(f"- {r.get('title') or r['url']}: {r['url']}" for r in results)


class MessageConverter:
    def __init__(self, vision: bool, reasoning_history: str):
        self.vision = vision
        self.reasoning_history = reasoning_history
        self.effort = None

    def convert(self, messages) -> list[dict]:
        turn_start = last_prompt_index(messages)
        out = []
        for i, msg in enumerate(messages):
            if not isinstance(msg, dict):
                continue
            role = msg.get("role")
            if role == "assistant":
                keep = self.reasoning_history == "all" or (self.reasoning_history == "current_turn" and i > turn_start)
                out.append(self.assistant(msg.get("content"), keep))
            elif role == "system":
                # Claude Code sends reminders as mid-conversation system entries. Most chat
                # templates only accept a system message at the top, so they become user text.
                effort = (msg.get("output_config") or {}).get("effort")
                if effort:
                    self.effort = effort
                text = flatten_text(msg.get("content"))
                if text:
                    out.append({"role": "user", "content": [text_part(text)]})
            else:
                out.extend(self.user(msg.get("content")))
        return finalize(out)

    def image(self, block: dict) -> dict:
        if not self.vision:
            return text_part("[image omitted: this model does not accept images]")
        source = block.get("source") or {}
        if source.get("type") == "base64":
            url = f"data:{source.get('media_type', 'image/png')};base64,{source.get('data', '')}"
        elif source.get("type") == "url" and source.get("url"):
            url = source["url"]
        else:
            return text_part("[image omitted: unsupported image source]")
        return {"type": "image_url", "image_url": {"url": url}}

    def user(self, content) -> list[dict]:
        tool_messages, parts = [], []
        for block in blocks(content):
            kind = block.get("type")
            if kind == "text":
                if block.get("text"):
                    parts.append(text_part(block["text"]))
            elif kind == "image":
                parts.append(self.image(block))
            elif kind == "tool_result":
                call_id = tool_id(block.get("tool_use_id"))
                text, images = self.tool_result(block)
                tool_messages.append({"role": "tool", "tool_call_id": call_id, "content": text})
                if images:
                    parts.append(text_part(f"Images returned by tool call {call_id}:"))
                    parts.extend(images)
            elif kind == "document":
                parts.append(text_part(document_text(block)))
            elif kind == "tool_reference":
                parts.append(text_part(f"Tool {block.get('tool_name')} is now loaded and can be called."))
            elif isinstance(block.get("text"), str) and block["text"]:
                parts.append(text_part(block["text"]))
        messages = tool_messages
        if parts:
            messages.append({"role": "user", "content": parts})
        return messages

    def tool_result(self, block: dict) -> tuple[str, list[dict]]:
        texts, images = [], []
        for inner in blocks(block.get("content")):
            kind = inner.get("type")
            if kind == "text":
                texts.append(inner.get("text", ""))
            elif kind == "image":
                if self.vision:
                    images.append(self.image(inner))
                else:
                    texts.append("[image omitted: this model does not accept images]")
            elif kind == "tool_reference":
                texts.append(f"Tool {inner.get('tool_name')} is now loaded and can be called.")
            elif kind == "document":
                texts.append(document_text(inner))
            elif isinstance(inner.get("text"), str):
                texts.append(inner["text"])
        text = "\n".join(t for t in texts if t) or "(no output)"
        if block.get("is_error"):
            text = f"Error: {text}"
        return text, images

    def assistant(self, content, keep_reasoning: bool) -> dict:
        texts, reasoning, calls = [], [], []
        for block in blocks(content):
            kind = block.get("type")
            if kind == "text":
                texts.append(block.get("text", ""))
            elif kind == "thinking":
                if keep_reasoning and block.get("thinking"):
                    reasoning.append(block["thinking"])
            elif kind == "tool_use":
                calls.append({
                    "id": tool_id(block.get("id")),
                    "type": "function",
                    "function": {
                        "name": block.get("name", ""),
                        "arguments": json.dumps(block.get("input") or {}, ensure_ascii=False),
                    },
                })
            elif kind == "server_tool_use":
                query = (block.get("input") or {}).get("query")
                if query:
                    texts.append(f"[searched the web for: {query}]")
            elif kind == "web_search_tool_result":
                texts.append(web_results_text(block))
            elif kind != "redacted_thinking" and isinstance(block.get("text"), str):
                texts.append(block["text"])
        msg = {"role": "assistant", "content": "\n\n".join(t for t in texts if t)}
        if calls:
            msg["tool_calls"] = calls
        if reasoning:
            joined = "\n\n".join(reasoning)
            # Chat templates read the older reasoning_content name, newer vLLM reads reasoning.
            msg["reasoning_content"] = joined
            msg["reasoning"] = joined
        return msg


def finalize(messages: list[dict]) -> list[dict]:
    out: list[dict] = []
    for msg in messages:
        if msg["role"] == "assistant" and not (msg["content"] or msg.get("tool_calls") or msg.get("reasoning")):
            continue
        if msg["role"] == "user" and out and out[-1]["role"] == "user":
            out[-1]["content"].extend(msg["content"])
            continue
        out.append(msg)
    for msg in out:
        if msg["role"] == "user" and all(p["type"] == "text" for p in msg["content"]):
            msg["content"] = "\n\n".join(p["text"] for p in msg["content"])
    return out


class TextFileCache:
    """Reads a prompt or key file, re-reading only when its mtime or size changes."""

    def __init__(self):
        self._lock = threading.Lock()
        self._entries: dict[str, tuple[int, int, str]] = {}

    def read(self, path: str, missing_ok: bool = False) -> str | None:
        try:
            stat = os.stat(path)
        except FileNotFoundError:
            if not missing_ok:
                log.warning("cannot read %s: the file does not exist", path)
            return None
        except OSError as exc:
            log.warning("cannot read %s: %s", path, exc)
            return None
        with self._lock:
            hit = self._entries.get(path)
            if hit and hit[0] == stat.st_mtime_ns and hit[1] == stat.st_size:
                return hit[2]
        try:
            text = Path(path).read_text(encoding="utf-8-sig")
        except OSError as exc:
            log.warning("cannot read %s: %s", path, exc)
            return None
        with self._lock:
            self._entries[path] = (stat.st_mtime_ns, stat.st_size, text)
        return text


TEXT_FILES = TextFileCache()


def key_from_file(path: str) -> str | None:
    """The first line of a key file that is not blank or a # comment."""
    text = TEXT_FILES.read(path, missing_ok=True)
    for line in (text or "").splitlines():
        line = line.strip().strip("\"'").strip()
        if line and not line.startswith("#"):
            return line
    return None


def resolve_api_key(mcfg: ModelConfig) -> str | None:
    return (key_from_file(mcfg.api_key_file) if mcfg.api_key_file else None) or read_api_key(mcfg.api_key_env)


def system_part(inline: str, file_path: str) -> str:
    """The file's contents when a _file option is set and readable, else the inline string."""
    if file_path:
        text = TEXT_FILES.read(file_path)
        if text is not None:
            return text
    return inline


def system_text(system, mcfg: ModelConfig) -> str:
    base = "\n\n".join(
        b["text"] for b in blocks(system)
        if isinstance(b.get("text"), str) and b["text"] and not b["text"].startswith(BILLING_HEADER_PREFIX)
    )
    if mcfg.system_replace_file:
        replaced = TEXT_FILES.read(mcfg.system_replace_file)
        if replaced is not None:
            base = replaced
        elif mcfg.system_replace is not None:
            base = mcfg.system_replace
    elif mcfg.system_replace is not None:
        base = mcfg.system_replace
    prepend = system_part(mcfg.system_prepend, mcfg.system_prepend_file)
    append = system_part(mcfg.system_append, mcfg.system_append_file)
    return "\n\n".join(p for p in (prepend, base, append) if p)


def openai_tools(tools, referenced: set[str], forced: str | None) -> list[dict]:
    out = []
    for tool in tools:
        if not isinstance(tool, dict) or tool.get("type") not in (None, "custom"):
            continue
        name = tool.get("name")
        if not name:
            continue
        if tool.get("defer_loading") and name not in referenced and name != forced:
            continue
        function = {"name": name, "parameters": tool.get("input_schema") or {"type": "object", "properties": {}}}
        if tool.get("description"):
            function["description"] = tool["description"]
        out.append({"type": "function", "function": function})
    return out


def openai_tool_choice(choice) -> tuple[object, bool | None]:
    choice = choice if isinstance(choice, dict) else {}
    parallel = False if choice.get("disable_parallel_tool_use") else None
    kind = choice.get("type", "auto")
    if kind == "any":
        return "required", parallel
    if kind == "none":
        return "none", parallel
    if kind == "tool" and choice.get("name"):
        return {"type": "function", "function": {"name": choice["name"]}}, parallel
    # ArliAI defaults tool_choice to "none", so "auto" must be explicit.
    return "auto", parallel


def apply_reasoning(body: dict, thinking, effort, setting: str) -> None:
    if setting == "omit":
        return
    if setting != "auto":
        body["reasoning_effort"] = setting
        return
    thinking = thinking if isinstance(thinking, dict) else {}
    if thinking.get("type") == "disabled":
        body["reasoning_effort"] = "none"
        return
    if effort:
        body["reasoning_effort"] = effort
    if thinking.get("type") == "enabled" and thinking.get("budget_tokens"):
        body["thinking_token_budget"] = int(thinking["budget_tokens"])


def build_chat_request(req: dict, mcfg: ModelConfig, *, vision: bool, reasoning: bool) -> dict:
    messages_in = [m for m in req.get("messages") or () if isinstance(m, dict)]
    converter = MessageConverter(vision, mcfg.reasoning_history)
    messages = converter.convert(messages_in)
    system = system_text(req.get("system"), mcfg)
    if system:
        messages.insert(0, {"role": "system", "content": system})
    body: dict = {"model": mcfg.upstream, "messages": messages, "stream": bool(req.get("stream"))}
    if body["stream"]:
        body["stream_options"] = {"include_usage": True}

    max_tokens = req.get("max_tokens")
    if mcfg.max_output_tokens:
        max_tokens = min(max_tokens or mcfg.max_output_tokens, mcfg.max_output_tokens)
    if max_tokens:
        body["max_completion_tokens"] = max_tokens
    if req.get("stop_sequences"):
        body["stop"] = req["stop_sequences"]

    choice = req.get("tool_choice")
    forced = choice.get("name") if isinstance(choice, dict) and choice.get("type") == "tool" else None
    tools = openai_tools(req.get("tools") or (), referenced_tools(messages_in), forced)
    if tools:
        body["tools"] = tools
        body["tool_choice"], parallel = openai_tool_choice(choice)
        if parallel is not None:
            body["parallel_tool_calls"] = parallel

    output_config = req.get("output_config") if isinstance(req.get("output_config"), dict) else {}
    if reasoning:
        apply_reasoning(body, req.get("thinking"), converter.effort or output_config.get("effort"), mcfg.reasoning_effort)
    fmt = output_config.get("format")
    if isinstance(fmt, dict) and fmt.get("type") == "json_schema" and fmt.get("schema"):
        body["response_format"] = {"type": "json_schema", "json_schema": {"name": "response", "schema": fmt["schema"]}}

    # Claude Code's temperature exists to satisfy Anthropic's thinking rules, so it
    # is not forwarded. Sampling comes from params, ArliAI key overrides, or model defaults.
    body.update(mcfg.params)
    return body


# OpenAI response to Anthropic response


def parse_tool_arguments(raw: str) -> dict:
    """Return the JSON object a model meant, tolerating common formatting slips."""
    text = (raw or "").strip()
    if not text:
        return {}
    candidates = [text]
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, re.S)
    if fenced:
        candidates.append(fenced.group(1))
    start, end = text.find("{"), text.rfind("}")
    if 0 <= start < end:
        candidates.append(text[start:end + 1])
    for candidate in candidates:
        try:
            value = json.loads(candidate)
            if isinstance(value, str):
                value = json.loads(value)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    log.warning("a model sent tool arguments that are not a JSON object (%d characters)", len(text))
    return {}


def anthropic_usage(usage: dict) -> dict:
    prompt = usage.get("prompt_tokens") or 0
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
    return {
        "input_tokens": max(prompt - cached, 0),
        "output_tokens": usage.get("completion_tokens") or 0,
        "cache_read_input_tokens": cached,
        "cache_creation_input_tokens": 0,
    }


class ThinkSplitter:
    """Splits <think>...</think> reasoning out of content for models whose reasoning arrives inline."""

    OPEN, CLOSE = "<think>", "</think>"

    def __init__(self):
        self._state = "start"
        self._buf = ""

    def feed(self, text: str) -> list[tuple[str, str]]:
        self._buf += text
        out = []
        if self._state == "start":
            head = self._buf.lstrip()
            if head.startswith(self.OPEN):
                self._state = "think"
                self._buf = head[len(self.OPEN):]
            elif self.OPEN.startswith(head):
                return out
            else:
                self._state = "text"
        if self._state == "think":
            end = self._buf.find(self.CLOSE)
            if end == -1:
                keep = len(self.CLOSE) - 1
                if len(self._buf) > keep:
                    out.append(("thinking", self._buf[:-keep]))
                    self._buf = self._buf[-keep:]
                return out
            if end:
                out.append(("thinking", self._buf[:end]))
            self._buf = self._buf[end + len(self.CLOSE):]
            self._state = "after"
        if self._state == "after":
            self._buf = self._buf.lstrip()
            if not self._buf:
                return out
            self._state = "text"
        if self._buf:
            out.append(("text", self._buf))
            self._buf = ""
        return out

    def flush(self) -> list[tuple[str, str]]:
        buf, self._buf = self._buf, ""
        if not buf.strip():
            return []
        return [("thinking" if self._state == "think" else "text", buf)]


class StreamTranslator:
    """Converts OpenAI chat completion chunks to Anthropic Messages stream events."""

    def __init__(self, model: str, think_tags: bool = True, stop_sequences=()):
        self.model = model
        self.message_id = f"msg_{uuid.uuid4().hex}"
        self.finished = False
        self.usage: dict = {}
        self._stops = set(stop_sequences)
        self._splitter = ThinkSplitter() if think_tags else None
        self._reasoning_field = False
        self._index = -1
        self._open: str | None = None
        self._tools: dict[int, dict] = {}
        self._finish = None
        self._stop_value = None
        self._out: list[tuple[str, dict]] = []

    def start(self) -> tuple[str, dict]:
        return "message_start", {
            "type": "message_start",
            "message": {
                "id": self.message_id, "type": "message", "role": "assistant", "model": self.model,
                "content": [], "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 0, "output_tokens": 0},
            },
        }

    def feed(self, chunk: dict) -> list[tuple[str, dict]]:
        error = chunk.get("error")
        if error:
            raise UpstreamStreamError(error.get("message") if isinstance(error, dict) else str(error))
        if chunk.get("usage"):
            self.usage = chunk["usage"]
        for choice in chunk.get("choices") or ():
            if choice.get("index", 0) != 0:
                continue
            delta = choice.get("delta") or {}
            reasoning = delta.get("reasoning") or delta.get("reasoning_content")
            if reasoning:
                self._reasoning_field = True
                self._emit("thinking", reasoning)
            content = delta.get("content")
            if content:
                if self._splitter and not self._reasoning_field:
                    for kind, text in self._splitter.feed(content):
                        self._emit(kind, text)
                else:
                    self._emit("text", content)
            for call in delta.get("tool_calls") or ():
                self._tool_delta(call)
            if choice.get("finish_reason"):
                self.finished = True
                self._finish = choice["finish_reason"]
                self._stop_value = choice.get("stop_reason")
        return self._take()

    def finish(self) -> list[tuple[str, dict]]:
        if self._splitter:
            for kind, text in self._splitter.flush():
                self._emit(kind, text)
        self._close_block()
        # Tool arguments are held until the end so they can be checked and repaired.
        used_tools = False
        for _, tool in sorted(self._tools.items()):
            if not tool["name"]:
                log.warning("dropped a tool call without a name")
                continue
            used_tools = True
            self._index += 1
            arguments = parse_tool_arguments("".join(tool["args"]))
            self._out += [
                ("content_block_start", {
                    "type": "content_block_start", "index": self._index,
                    "content_block": {"type": "tool_use", "id": tool_id(tool["id"]), "name": tool["name"], "input": {}},
                }),
                ("content_block_delta", {
                    "type": "content_block_delta", "index": self._index,
                    "delta": {"type": "input_json_delta", "partial_json": json.dumps(arguments, ensure_ascii=False)},
                }),
                ("content_block_stop", {"type": "content_block_stop", "index": self._index}),
            ]
        stop_sequence = None
        if used_tools:
            stop_reason = "tool_use"
        elif self._finish == "stop" and isinstance(self._stop_value, str) and self._stop_value in self._stops:
            stop_reason, stop_sequence = "stop_sequence", self._stop_value
        else:
            stop_reason = STOP_REASONS.get(self._finish, "end_turn")
        self._out += [
            ("message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": stop_sequence},
                "usage": anthropic_usage(self.usage),
            }),
            ("message_stop", {"type": "message_stop"}),
        ]
        return self._take()

    def _take(self) -> list[tuple[str, dict]]:
        out, self._out = self._out, []
        return out

    def _emit(self, kind: str, text: str) -> None:
        if self._open != kind:
            self._close_block()
            self._index += 1
            self._open = kind
            block = {"type": "text", "text": ""} if kind == "text" else {"type": "thinking", "thinking": "", "signature": ""}
            self._out.append(("content_block_start", {"type": "content_block_start", "index": self._index, "content_block": block}))
        delta = {"type": "text_delta", "text": text} if kind == "text" else {"type": "thinking_delta", "thinking": text}
        self._out.append(("content_block_delta", {"type": "content_block_delta", "index": self._index, "delta": delta}))

    def _close_block(self) -> None:
        if self._open is None:
            return
        if self._open == "thinking":
            self._out.append(("content_block_delta", {
                "type": "content_block_delta", "index": self._index,
                "delta": {"type": "signature_delta", "signature": SIGNATURE_PREFIX + uuid.uuid4().hex},
            }))
        self._out.append(("content_block_stop", {"type": "content_block_stop", "index": self._index}))
        self._open = None

    def _tool_delta(self, call: dict) -> None:
        index = call.get("index", len(self._tools))
        tool = self._tools.setdefault(index, {"id": None, "name": "", "args": []})
        if call.get("id") and not tool["id"]:
            tool["id"] = call["id"]
        function = call.get("function") or {}
        if function.get("name") and not tool["name"]:
            tool["name"] = function["name"]
        if function.get("arguments"):
            tool["args"].append(function["arguments"])


def collect_message(events) -> dict:
    """Build the final Anthropic message from its stream events, the way the Anthropic SDK does."""
    message: dict = {}
    content: list[dict] = []
    partial_json: dict[int, str] = {}
    for name, data in events:
        if name == "message_start":
            message = dict(data["message"])
        elif name == "content_block_start":
            content.append(dict(data["content_block"]))
        elif name == "content_block_delta":
            block, delta = content[data["index"]], data["delta"]
            if delta["type"] == "text_delta":
                block["text"] += delta["text"]
            elif delta["type"] == "thinking_delta":
                block["thinking"] += delta["thinking"]
            elif delta["type"] == "signature_delta":
                block["signature"] = delta["signature"]
            elif delta["type"] == "input_json_delta":
                partial_json[data["index"]] = partial_json.get(data["index"], "") + delta["partial_json"]
        elif name == "content_block_stop":
            if data["index"] in partial_json:
                content[data["index"]]["input"] = json.loads(partial_json.pop(data["index"]))
        elif name == "message_delta":
            message.update(data["delta"])
            message["usage"] = {**message.get("usage", {}), **data.get("usage", {})}
    message["content"] = content
    return message


def message_from_completion(data: dict, model: str, think_tags: bool = True, stop_sequences=()) -> dict:
    translator = StreamTranslator(model, think_tags, stop_sequences)
    events = [translator.start()]
    choice = next((c for c in data.get("choices") or () if c.get("index", 0) == 0), None)
    if choice:
        message = choice.get("message") or {}
        delta = {**message, "tool_calls": [{**c, "index": i} for i, c in enumerate(message.get("tool_calls") or ())]}
        events += translator.feed({"choices": [{
            "delta": delta, "finish_reason": choice.get("finish_reason"), "stop_reason": choice.get("stop_reason"),
        }]})
    if data.get("usage"):
        events += translator.feed({"usage": data["usage"]})
    events += translator.finish()
    return collect_message(events)


def sse_data(resp):
    """Yield the data field of each server sent event in an upstream response."""
    while True:
        line = resp.readline()
        if not line:
            return
        line = line.rstrip(b"\r\n")
        if line.startswith(b"data:"):
            value = line[5:]
            yield (value[1:] if value.startswith(b" ") else value).decode("utf-8")


# Upstream errors

CONTEXT_PATTERNS = (
    re.compile(r"maximum context length is (?P<limit>\d+) tokens and your request has (?P<prompt>\d+) input tokens"),
    re.compile(r"maximum context length is (?P<limit>\d+) tokens\. However, you requested \d+ tokens \((?P<prompt>\d+) in the messages"),
    re.compile(r"maximum context length is (?P<limit>\d+) tokens\. However, your request has (?P<prompt>\d+) input tokens"),
)
CONTEXT_HINT = re.compile(r"context (?:length|window|size|limit)|too many (?:input )?tokens|prompt is too long", re.I)


def error_message(raw: bytes | None) -> str:
    try:
        data = json.loads(raw or b"")
    except (ValueError, UnicodeDecodeError):
        return (raw or b"").decode("utf-8", "replace").strip()[:2000]
    if isinstance(data, dict):
        error = data.get("error", data)
        message = error.get("message") or error.get("detail") if isinstance(error, dict) else error
        if isinstance(message, str):
            return message
    return json.dumps(data)[:2000]


def parse_context(message: str) -> tuple[int | None, int | None] | None:
    for pattern in CONTEXT_PATTERNS:
        found = pattern.search(message)
        if found:
            return int(found["limit"]), int(found["prompt"])
    if CONTEXT_HINT.search(message):
        return None, None
    return None


def shrink_output_budget(body: dict, message: str) -> dict | None:
    """Fit max_completion_tokens into the room the prompt leaves, when that is the only problem."""
    found = parse_context(message)
    asked = body.get("max_completion_tokens")
    if not found or found[0] is None or not asked:
        return None
    limit, prompt = found
    room = limit - prompt - 64
    if room < MIN_OUTPUT_TOKENS or room >= asked:
        return None
    return {**body, "max_completion_tokens": room}


def map_upstream_error(status: int, raw: bytes | None, headers) -> tuple[int, str, str, tuple]:
    """Turn an ArliAI error into the Anthropic error Claude Code knows how to handle."""
    message = error_message(raw)
    if status in (400, 413, 422):
        found = parse_context(message)
        if found:
            limit, prompt = found
            if limit is None:
                detail = message
            elif prompt < limit:
                detail = f"{prompt} tokens > {limit - MIN_OUTPUT_TOKENS} maximum"
            else:
                detail = f"{prompt} tokens > {limit} maximum"
            return 400, "invalid_request_error", f"prompt is too long: {detail} (capability_rejected: prompt_too_long)", NO_RETRY
        return 400, "invalid_request_error", f"ArliAI rejected the request: {message}", NO_RETRY
    if status in (401, 403):
        # Passing a 401 through would make Claude Code think its own login expired.
        return 400, "invalid_request_error", f"ArliAI rejected the API key (HTTP {status}): {message}", NO_RETRY
    if status == 404:
        return 404, "not_found_error", f"ArliAI does not serve this model: {message}", NO_RETRY
    if status == 429:
        retry = headers.get("retry-after") if headers is not None else None
        retry = retry if retry and retry.strip().isdigit() else "5"
        return 429, "rate_limit_error", f"ArliAI is limiting requests: {message}", (("retry-after", retry.strip()),)
    if status >= 500:
        kind = "overloaded_error" if status == 503 else "api_error"
        return (status if status in (500, 502, 503, 504) else 502), kind, f"ArliAI failed (HTTP {status}): {message}", ()
    return 400, "invalid_request_error", f"ArliAI answered HTTP {status}: {message}", NO_RETRY


@dataclass
class Reply:
    status: int
    headers: http.client.HTTPMessage
    resp: http.client.HTTPResponse | None
    body: bytes = b""


def post_chat(cfg: Config, body: dict, key: str, holder) -> Reply:
    retried = False
    while True:
        conn, prefix = connect(cfg.arli_url, cfg.upstream_timeout)
        holder.conn = conn
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream" if body.get("stream") else "application/json",
            "User-Agent": USER_AGENT,
        }
        conn.request("POST", prefix + "/v1/chat/completions", json.dumps(body, ensure_ascii=False).encode(), headers)
        resp = conn.getresponse()
        if resp.status == 200:
            return Reply(200, resp.headers, resp)
        raw = resp.read()
        conn.close()
        smaller = None if retried or resp.status != 400 else shrink_output_budget(body, error_message(raw))
        if smaller is None:
            return Reply(resp.status, resp.headers, None, raw)
        log.info("lowered max_completion_tokens from %s to %s to fit the context",
                 body["max_completion_tokens"], smaller["max_completion_tokens"])
        body, retried = smaller, True


# HTTP server


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "claude-arli-proxy"
    server: "Server"

    def do_GET(self):
        self.dispatch()

    do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_GET

    def log_message(self, format, *args):
        # The default prints every request line, which the summary in dispatch already covers.
        log.debug("%s %s", self.address_string(), format % args)

    def send_response_only(self, code, message=None):
        self.status = code
        super().send_response_only(code, message)

    def flush_headers(self):
        try:
            super().flush_headers()
        except OSError as exc:
            raise ClientGone from exc

    def dispatch(self) -> None:
        started = time.monotonic()
        self.status = None
        self.note = ""
        path = urlsplit(self.path).path
        try:
            body = self.read_body()
            if path == HEALTH_PATH:
                self.send_json(200, {"ok": True, "pid": os.getpid()})
                return
            self.route(self.server.store.get(), path, body)
        except ClientGone:
            self.close_connection = True
            self.note += " (client left)"
        except Exception:  # one broken request must never take the proxy down
            log.exception("request failed: %s %s", self.command, path)
            self.close_connection = True
            if self.status is None:
                with contextlib.suppress(OSError, ClientGone):
                    self.send_error_json(500, "api_error", "claude-arli-proxy failed internally, see its log")
        finally:
            if path != HEALTH_PATH:
                log.info("%s %s %s-> %s in %.1fs", self.command, path, f"{self.note} " if self.note else "",
                         self.status, time.monotonic() - started)

    def read_body(self) -> bytes | None:
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            parts = []
            while (size := int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)) > 0:
                parts.append(self.rfile.read(size))
                self.rfile.readline()
            while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                pass
            return b"".join(parts)
        length = self.headers.get("Content-Length")
        return self.rfile.read(int(length)) if length else None

    def route(self, cfg: Config, path: str, body: bytes | None) -> None:
        kind = MESSAGE_PATHS.get(path) if self.command == "POST" else None
        req = load_object(body) if kind else None
        model = req.get("model") if req else None
        logged_in = not self.without_login()
        if isinstance(model, str) and model.startswith(cfg.model_prefix):
            self.note = model
            self.handle_arli(cfg, kind, req, model[len(cfg.model_prefix):], logged_in)
            return
        if not logged_in:
            if req is not None and cfg.no_login_model:
                # Background tasks such as session titles ask for a Claude model, and they would fail without a login.
                self.note = f"{model} as {cfg.model_prefix}{cfg.no_login_model} (no login)"
                self.handle_arli(cfg, kind, req, cfg.no_login_model, logged_in)
            else:
                self.send_error_json(400, "invalid_request_error", (
                    f"Claude Code is not logged in to claude.ai, so only {cfg.model_prefix} models work. "
                    "Pick one with /model, or set no_login_model in the proxy's config.toml."
                ), NO_RETRY)
            return
        if req is not None:
            self.note = str(model)
            if SIGNATURE_PREFIX.encode() in body and strip_proxy_thinking(req):
                body = dump_json(req)
        self.forward(cfg, body)

    def without_login(self) -> bool:
        return (self.headers.get("Authorization") == f"Bearer {NO_LOGIN_TOKEN}"
                or self.headers.get("x-api-key") == NO_LOGIN_TOKEN)

    # Anthropic side

    def forward(self, cfg: Config, body: bytes | None) -> None:
        base = cfg.anthropic_url
        host = urlsplit(base).netloc
        headers = [(k, v) for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP]
        for attempt in (1, 2):
            conn, prefix, reused = self.server.pool.get(base, cfg.upstream_timeout)
            try:
                conn.putrequest(self.command, prefix + self.path, skip_host=True, skip_accept_encoding=True)
                conn.putheader("Host", host)
                for name, value in headers:
                    conn.putheader(name, value)
                if body is not None:
                    conn.putheader("Content-Length", str(len(body)))
                conn.endheaders(body)
                resp = conn.getresponse()
                break
            except STALE_CONNECTION_ERRORS as exc:
                conn.close()
                if reused and attempt == 1:
                    continue
                self.send_error_json(502, "api_error", f"claude-arli-proxy could not reach {host}: {exc}")
                return
            except (OSError, http.client.HTTPException) as exc:
                conn.close()
                self.send_error_json(502, "api_error", f"claude-arli-proxy could not reach {host}: {exc}")
                return
        self.relay(resp, conn, base, prefix)

    def relay(self, resp, conn, base: str, prefix: str) -> None:
        self.send_response_only(resp.status, resp.reason)
        for name, value in resp.getheaders():
            if name.lower() not in HOP_BY_HOP:
                self.send_header(name, value)
        length = resp.getheader("Content-Length")
        bodyless = self.command == "HEAD" or resp.status in (204, 304) or resp.status < 200
        chunked = not bodyless and (length is None or resp.chunked)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        elif length is not None:
            self.send_header("Content-Length", length)
        try:
            self.end_headers()
            if bodyless:
                # Reading the empty body marks the response done so the connection can be reused.
                resp.read()
            else:
                while chunk := resp.read1(65536):
                    self.write_raw(b"%x\r\n%s\r\n" % (len(chunk), chunk) if chunked else chunk)
                if chunked:
                    self.write_raw(b"0\r\n\r\n")
        except ClientGone:
            abort(conn)
            raise
        except (OSError, http.client.HTTPException) as exc:
            # The response is already under way, so all that is left is to cut it off.
            log.warning("Anthropic response broke off: %s", exc)
            abort(conn)
            self.close_connection = True
            return
        if resp.will_close:
            conn.close()
        else:
            self.server.pool.put(base, conn, prefix)

    # ArliAI side

    def handle_arli(self, cfg: Config, kind: str, req: dict, name: str, logged_in: bool) -> None:
        mcfg = cfg.model(name)
        if kind == "messages" and logged_in and cfg.server_tool_model and uses_server_tools(req):
            rerouted = {**req, "model": cfg.server_tool_model}
            strip_proxy_thinking(rerouted)
            self.note += f" via {cfg.server_tool_model} for web tools"
            self.forward(cfg, dump_json(rerouted))
            return
        key = resolve_api_key(mcfg)
        if not key:
            where = f"{mcfg.api_key_file} or " if mcfg.api_key_file else ""
            self.send_error_json(400, "invalid_request_error", (
                f"claude-arli-proxy has no ArliAI API key. Put it in {where}the {mcfg.api_key_env} variable, "
                "then send your message again."
            ), NO_RETRY)
            return
        info = self.server.catalog.get(cfg.arli_url, mcfg.upstream) or {}
        vision = mcfg.vision if mcfg.vision is not None else bool(info.get("vlm", True))
        body = build_chat_request(req, mcfg, vision=vision, reasoning=bool(info.get("reasoning", True)))
        if kind == "count_tokens":
            self.count_tokens_arli(cfg, body, key)
        elif body["stream"]:
            self.stream_arli(cfg, mcfg, body, key, req["model"], req.get("stop_sequences") or ())
        else:
            self.complete_arli(cfg, mcfg, body, key, req["model"], req.get("stop_sequences") or ())

    def count_tokens_arli(self, cfg: Config, body: dict, key: str) -> None:
        payload = {"model": body["model"], "messages": body["messages"]}
        if body.get("tools"):
            payload["tools"] = body["tools"]
        count = None
        try:
            status, data = request_json(cfg.arli_url, "POST", "/v1/tokenize", payload, key, timeout=60)
            if status == 200 and isinstance(data, dict):
                count = data.get("count")
                if count is None and isinstance(data.get("tokens"), list):
                    count = len(data["tokens"])
            else:
                log.info("ArliAI tokenize answered HTTP %s", status)
        except (OSError, http.client.HTTPException, ValueError) as exc:
            log.info("ArliAI tokenize failed: %s", exc)
        if not isinstance(count, int):
            # Roughly four characters per token, the same kind of estimate Claude Code falls back to.
            count = len(json.dumps(payload, ensure_ascii=False)) // 4
        self.send_json(200, {"input_tokens": count})

    def complete_arli(self, cfg: Config, mcfg: ModelConfig, body: dict, key: str, model: str, stops) -> None:
        holder = SimpleNamespace(conn=None)
        self.server.limiter.acquire(threading.Event())
        try:
            reply = post_chat(cfg, body, key, holder)
            if reply.status != 200:
                self.send_error_json(*map_upstream_error(reply.status, reply.body, reply.headers))
                return
            data = json.loads(reply.resp.read())
        except (OSError, http.client.HTTPException, ValueError) as exc:
            self.send_error_json(502, "api_error", f"claude-arli-proxy lost the connection to ArliAI: {exc}")
            return
        finally:
            if holder.conn is not None:
                holder.conn.close()
            self.server.limiter.release()
        message = message_from_completion(data, model, mcfg.think_tags, stops)
        self.note += f" in={message['usage']['input_tokens']} out={message['usage']['output_tokens']}"
        self.send_json(200, message)

    def stream_arli(self, cfg: Config, mcfg: ModelConfig, body: dict, key: str, model: str, stops) -> None:
        events: queue.Queue = queue.Queue()
        cancel = threading.Event()
        holder = SimpleNamespace(conn=None)
        threading.Thread(
            target=self.server.stream_worker, args=(body, key, events, cancel, holder),
            name="arli-upstream", daemon=True,
        ).start()
        translator = StreamTranslator(model, mcfg.think_tags, stops)
        committed = False
        started = time.monotonic()
        try:
            while True:
                if committed:
                    wait = cfg.ping_interval
                else:
                    wait = max(0.01, min(cfg.ping_interval, started + cfg.commit_after - time.monotonic()))
                try:
                    kind, value = events.get(timeout=wait)
                except queue.Empty:
                    # Claude Code drops a silent stream, so the reply starts early and pings
                    # while ArliAI is still queued or reading a long prompt.
                    if not committed and time.monotonic() - started >= cfg.commit_after:
                        self.begin_events(translator)
                        committed = True
                    elif committed:
                        self.send_event("ping", {"type": "ping"})
                    continue
                if kind == "reply":
                    if value.status != 200:
                        self.fail(committed, *map_upstream_error(value.status, value.body, value.headers))
                        return
                    if not committed:
                        self.begin_events(translator)
                        committed = True
                elif kind == "chunk":
                    for event in translator.feed(value):
                        self.send_event(*event)
                    if time.monotonic() - self.last_write >= cfg.ping_interval:
                        self.send_event("ping", {"type": "ping"})
                elif kind == "end":
                    if not (value or translator.finished):
                        raise UpstreamStreamError("ArliAI closed the stream before the reply was complete")
                    for event in translator.finish():
                        self.send_event(*event)
                    self.write_raw(b"0\r\n\r\n")
                    usage = anthropic_usage(translator.usage)
                    self.note += f" in={usage['input_tokens'] + usage['cache_read_input_tokens']} out={usage['output_tokens']}"
                    return
                elif kind == "failed":
                    self.fail(committed, 502, "api_error", f"claude-arli-proxy lost the connection to ArliAI: {value}", ())
                    return
        except UpstreamStreamError as exc:
            self.fail(committed, 500, "api_error", f"ArliAI stream failed: {exc}", ())
        finally:
            cancel.set()
            abort(holder.conn)

    # Response helpers

    def begin_events(self, translator: StreamTranslator) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.send_event(*translator.start())

    def send_event(self, name: str, data: dict) -> None:
        payload = f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False, separators=(',', ':'))}\n\n".encode()
        self.write_raw(b"%x\r\n%s\r\n" % (len(payload), payload))
        self.last_write = time.monotonic()

    def fail(self, committed: bool, status: int, kind: str, message: str, headers) -> None:
        if committed:
            self.send_event("error", {"type": "error", "error": {"type": kind, "message": message}})
            self.write_raw(b"0\r\n\r\n")
        else:
            self.send_error_json(status, kind, message, headers)

    def write_raw(self, data: bytes) -> None:
        try:
            self.wfile.write(data)
        except OSError as exc:
            raise ClientGone from exc

    def send_json(self, status: int, data, headers=()) -> None:
        body = dump_json(data)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.write_raw(body)

    def send_error_json(self, status: int, kind: str, message: str, headers=()) -> None:
        self.send_json(status, {"type": "error", "error": {"type": kind, "message": message}}, headers)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, store: ConfigStore):
        cfg = store.get()
        self.store = store
        self.catalog = ModelCatalog()
        self.limiter = Limiter(lambda: self.store.get().max_parallel)
        self.pool = ConnectionPool()
        super().__init__((cfg.listen_host, cfg.listen_port), Handler)

    def server_close(self):
        super().server_close()
        self.pool.close()

    def handle_error(self, request, client_address):
        # socketserver prints to stderr, and clients drop idle keep-alive connections all the time.
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, TimeoutError)):
            log.debug("connection from %s dropped: %s", client_address[0], exc)
        else:
            log.exception("connection from %s failed", client_address[0])

    def stream_worker(self, body: dict, key: str, out: queue.Queue, cancel: threading.Event, holder) -> None:
        if not self.limiter.acquire(cancel):
            return
        try:
            reply = post_chat(self.store.get(), body, key, holder)
            out.put(("reply", reply))
            if reply.status != 200:
                return
            clean = False
            for data in sse_data(reply.resp):
                if cancel.is_set():
                    return
                if data == "[DONE]":
                    clean = True
                    break
                try:
                    chunk = json.loads(data)
                except ValueError:
                    log.warning("ignored a malformed event from ArliAI")
                    continue
                if isinstance(chunk, dict):
                    out.put(("chunk", chunk))
            out.put(("end", clean))
        except Exception as exc:  # every failure has to reach the waiting handler, or it would wait forever
            if not cancel.is_set():
                out.put(("failed", exc))
        finally:
            if holder.conn is not None:
                holder.conn.close()
            self.limiter.release()


# Command line


def setup_logging(level: str) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
    log.addHandler(handler)
    log.setLevel(level)
    threading.excepthook = lambda args: log.error(
        "thread %s crashed", args.thread.name if args.thread else "?",
        exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
    )


def serve(config_path: Path) -> int:
    try:
        store = ConfigStore(config_path)
    except (OSError, ValueError, TypeError, tomllib.TOMLDecodeError) as exc:
        setup_logging("INFO")
        log.error("cannot load %s: %s", config_path, exc)
        return 2
    cfg = store.get()
    setup_logging(cfg.log_level)
    try:
        server = Server(store)
    except OSError as exc:
        log.error("cannot listen on %s:%s: %s", cfg.listen_host, cfg.listen_port, exc)
        return 1
    host, port = server.server_address[:2]
    log.info("listening on http://%s:%s (pid %s)", host, port, os.getpid())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Use ArliAI models in Claude Code next to a claude.ai login.")
    parser.add_argument("--config", type=Path, required=True, help="settings file")
    return serve(parser.parse_args(argv).config)


if __name__ == "__main__":
    sys.exit(main())
