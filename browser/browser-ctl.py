#!/usr/bin/env python3
"""
browser-ctl.py — Chromium CDP controller for PryzentOS.

Automates the graphical Chromium browser via Chrome DevTools Protocol.
Requires Chromium launched with --remote-debugging-port=9222.

Commands:
  navigate <url>                        Navigate to a URL
  click <css-selector>                  Click an element by CSS selector
  type <css-selector> <text>            Fill an element with text
  clear <css-selector>                  Clear an input field
  press <key>                           Press a key (Enter, Tab, Escape, etc.)
  select <css-selector> <option-text>   Select an option in a <select>
  wait <css-selector> [timeout=10]      Wait for element to appear
  text [selector]                       Get page or element text
  html [selector]                       Get innerHTML of element or page
  screenshot [path=/tmp/screenshot.png] Capture page screenshot (PNG)
  cookies <url>                         Get cookies for a URL
  eval <javascript>                     Run JavaScript in the page context
  find <text>                           Find an element containing text
  scroll <direction>                    Scroll (up/down/left/right, default: down)
  keyinfo <selector>                    Get label/placeholder/aria-label near an input
  back                                  Go back
  forward                              Go forward
  reload                               Reload page
  url                                  Print current URL
  title                                Print page title
  bring-to-front                       Focus the browser window

The agent uses these to automate web flows: login, form fill, navigation,
data extraction — without coordinate-based clicking.
"""

import sys
import json
import os
import time
import socket
import struct
import base64
import urllib.request
import urllib.error

PORT = int(os.environ.get("BROWSER_DEBUG_PORT", "9222"))
DEBUG_URL = f"http://127.0.0.1:{PORT}"

# ═══════════════════════════════════════════════════════════════════════════════
# Minimal WebSocket client (client-to-server frames only — CDP server never
# sends masked frames, so we skip the unmasking step in ws_recv)
# ═══════════════════════════════════════════════════════════════════════════════

def _ws_key():
    return base64.b64encode(os.urandom(16)).decode()

def ws_connect(url, timeout=10):
    if not url.startswith("ws://"):
        raise ValueError(f"unsupported ws url: {url} (only ws:// supported)")
    rest = url[5:]
    if "/" in rest:
        host_port, path = rest.split("/", 1)
        path = "/" + path
    else:
        host_port = rest
        path = "/"
    if ":" in host_port:
        host, port_s = host_port.rsplit(":", 1)
        port = int(port_s)
    else:
        host = host_port
        port = 80
    sock = socket.create_connection((host, port), timeout=timeout)
    key = _ws_key()
    handshake = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(handshake.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv
        if not chunk:
            raise ConnectionError("closed during handshake")
        resp += chunk
    if b"101 Switching Protocols" not in resp:
        raise ConnectionError(f"upgrade failed: {resp[:200]}")
    sock.settimeout(timeout)
    return sock

def ws_send(conn, text):
    data = text.encode("utf-8")
    n = len(data)
    mask = os.urandom(4)
    if n <= 125:
        hdr = bytes([0x81, 0x80 | n]) + mask
    elif n <= 65535:
        hdr = bytes([0x81, 0x80 | 126]) + struct.pack(">H", n) + mask
    else:
        hdr = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", n) + mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    conn.sendall(hdr + masked)

def ws_recv(conn, timeout=5):
    conn.settimeout(timeout)
    try:
        b0 = conn.recv(2)
        if len(b0) < 2:
            return None
        opcode = b0[0] & 0x0F
        masked = b0[1] & 0x80
        length = b0[1] & 0x7F
        if length == 126:
            raw = conn.recv(2)
            length = struct.unpack(">H", raw)[0]
        elif length == 127:
            raw = conn.recv(8)
            length = struct.unpack(">Q", raw)[0]
        if masked:
            mask_key = conn.recv(4)
        payload = b""
        while len(payload) < length:
            chunk = conn.recv(min(length - len(payload), 65536))
            if not chunk:
                break
            payload += chunk
        if masked:
            payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        if opcode == 1:
            return payload.decode("utf-8", errors="replace")
        if opcode == 9:
            conn.sendall(bytes([0x8A, 0x00]))
            return None
        return None
    except (socket.timeout, OSError):
        return None

def ws_close(conn):
    try:
        conn.sendall(bytes([0x88, 0x00]))
        conn.close()
    except Exception:
        pass


# ═══════════════════════════════════════════════════════════════════════════════
# CDP helpers
# ═══════════════════════════════════════════════════════════════════════════════

_cdp_id = 0

def get_ws_url():
    try:
        req = urllib.request.Request(f"{DEBUG_URL}/json/list")
        with urllib.request.urlopen(req, timeout=4) as resp:
            tabs = json.loads(resp.read().decode())
        for t in tabs:
            if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                return t["webSocketDebuggerUrl"]
    except Exception as e:
        print(f"[browser-ctl] error listing tabs: {e}", file=sys.stderr)
    return None

def send_cdp(conn, method, params=None, timeout=15):
    global _cdp_id
    _cdp_id += 1
    msg_id = _cdp_id
    msg = {"id": msg_id, "method": method}
    if params:
        msg["params"] = params
    try:
        ws_send(conn, json.dumps(msg))
    except Exception as e:
        return None, f"send error: {e}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        raw = ws_recv(conn, timeout=min(2.0, deadline - time.time()))
        if raw is None:
            continue
        try:
            data = json.loads(raw)
            if data.get("id") == msg_id:
                if "result" in data:
                    return data["result"], None
                if "error" in data:
                    return None, data["error"]
        except Exception:
            pass
    return None, "timeout waiting for response"

def ensure_page(ws_url):
    return ws_connect(ws_url)


# ═══════════════════════════════════════════════════════════════════════════════
# Navigation
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_navigate(url):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page. Is Chromium running with --remote-debugging-port=9222?")
        return 1
    conn = ensure_page(ws)
    try:
        res, err = send_cdp(conn, "Page.navigate", {"url": url})
        if err:
            print(f"ERROR navigate: {err}")
            return 1
        print(f"OK navigated to {url}")
        time.sleep(0.8)
        return 0
    finally:
        ws_close(conn)

def cmd_back():
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        send_cdp(conn, "Page.navigate", {"url": ""})  # fallback
        send_cdp(conn, "Runtime.evaluate", {"expression": "history.back()", "returnByValue": True})
        print("OK went back")
        time.sleep(0.5)
        return 0
    finally:
        ws_close(conn)

def cmd_forward():
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        send_cdp(conn, "Runtime.evaluate", {"expression": "history.forward()", "returnByValue": True})
        print("OK went forward")
        time.sleep(0.5)
        return 0
    finally:
        ws_close(conn)

def cmd_reload():
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        send_cdp(conn, "Page.reload")
        print("OK reloaded")
        time.sleep(0.5)
        return 0
    finally:
        ws_close(conn)

def cmd_url():
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": "window.location.href", "returnByValue": True})
        if not err and res:
            print(res.get("result", {}).get("value", ""))
        return 0 if not err else 1
    finally:
        ws_close(conn)

def cmd_title():
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": "document.title", "returnByValue": True})
        if not err and res:
            print(res.get("result", {}).get("value", ""))
        return 0 if not err else 1
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Element interaction (CSS selector based — no coordinates)
# ═══════════════════════════════════════════════════════════════════════════════

def _wait_for_selector(conn, selector, timeout=10):
    """Wait for a selector to appear. Returns True/False."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        res, err = send_cdp(conn, "Runtime.evaluate", {
            "expression": f"document.querySelector({json.dumps(selector)}) !== null",
            "returnByValue": True
        })
        if res and res.get("result", {}).get("value") is True:
            return True
        time.sleep(0.25)
    return False

def _scroll_to_selector(conn, selector):
    """Scroll an element into view before interacting."""
    send_cdp(conn, "Runtime.evaluate", {
        "expression": (
            f"var el = document.querySelector({json.dumps(selector)});"
            "if (el) el.scrollIntoView({block:'center', behavior:'instant'});"
        ),
        "returnByValue": True
    })
    time.sleep(0.15)

def _input_set_value(conn, selector, value):
    """Set an input's value via JS and fire input/change events."""
    expr = (
        f"(function() {{"
        f"  var el = document.querySelector({json.dumps(selector)});"
        f"  if (!el) return 'not_found';"
        f"  var tag = el.tagName.toLowerCase();"
        f"  if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {{"
        f"    el.checked = {json.dumps(value).lower()};"
        f"    el.dispatchEvent(new Event('change', {{bubbles:true}}));"
        f"    return 'checked';"
        f"  }}"
        f"  if (tag === 'select') {{"
        f"    for (var i=0; i<el.options.length; i++) {{"
        f"      if (el.options[i].text === {json.dumps(value)}) {{ el.selectedIndex=i; break; }}"
        f"    }}"
        f"    el.dispatchEvent(new Event('change', {{bubbles:true}}));"
        f"    return 'selected';"
        f"  }}"
        f"  el.value = {json.dumps(value)};"
        f"  el.dispatchEvent(new Event('input', {{bubbles:true}}));"
        f"  el.dispatchEvent(new Event('change', {{bubbles:true}}));"
        f"  return 'set';"
        f"}})()"
    )
    res, err = send_cdp(conn, "Runtime.evaluate", {"expression": expr, "returnByValue": True})
    return res.get("result", {}).get("value", "error") if res else "error"

def _cdp_click_center(conn, selector):
    """Click via CDP Input.dispatchMouseEvent at the element's center."""
    js = (
        f"(function() {{"
        f"  var el = document.querySelector({json.dumps(selector)});"
        f"  if (!el) return 'not_found';"
        f"  var r = el.getBoundingClientRect();"
        f"  return JSON.stringify({{x: r.x + r.width/2, y: r.y + r.height/2}});"
        f"}})()"
    )
    res, err = send_cdp(conn, "Runtime.evaluate", {"expression": js, "returnByValue": True})
    if err or not res:
        return "no_position"
    try:
        pos = json.loads(res.get("result", {}).get("value", "{}"))
    except Exception:
        return "bad_position"
    x, y = pos.get("x", 0), pos.get("y", 0)
    if x == 0 and y == 0:
        return "zero_pos"
    # Scroll first, then click via native CDP mouse events
    _scroll_to_selector(conn, selector)
    send_cdp(conn, "Input.dispatchMouseEvent", {
        "type": "mouseMoved", "x": round(x), "y": round(y)
    })
    send_cdp(conn, "Input.dispatchMouseEvent", {
        "type": "mousePressed", "x": round(x), "y": round(y),
        "button": "left", "clickCount": 1
    })
    time.sleep(0.05)
    send_cdp(conn, "Input.dispatchMouseEvent", {
        "type": "mouseReleased", "x": round(x), "y": round(y),
        "button": "left", "clickCount": 1
    })
    return f"clicked at {round(x)},{round(y)}"

def cmd_click(selector):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        if not _wait_for_selector(conn, selector, timeout=8):
            print(f"ERROR: selector not found: {selector}")
            return 1
        result = _cdp_click_center(conn, selector)
        if result.startswith("ERROR") or result in ("not_found", "no_position", "zero_pos"):
            # fallback: JS click
            expr = f"var el = document.querySelector({json.dumps(selector)}); if(el){{el.scrollIntoView({{block:'center'}});el.click();'clicked';}} else 'not_found';"
            res, err = send_cdp(conn, "Runtime.evaluate", {"expression": expr, "returnByValue": True})
            val = res.get("result", {}).get("value", "") if res else ""
            if val == "clicked":
                print(f"OK clicked (js fallback): {selector}")
                return 0
            print(f"ERROR: could not click {selector}")
            return 1
        print(f"OK clicked: {selector} ({result})")
        return 0
    finally:
        ws_close(conn)

def cmd_type(selector, text):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        if not _wait_for_selector(conn, selector, timeout=8):
            print(f"ERROR: selector not found: {selector}")
            return 1
        _scroll_to_selector(conn, selector)
        # Focus the element via CDP
        send_cdp(conn, "Runtime.evaluate", {
            "expression": f"document.querySelector({json.dumps(selector)}).focus();"
        })
        time.sleep(0.1)
        # Clear existing content
        send_cdp(conn, "Runtime.evaluate", {
            "expression": f"var el = document.querySelector({json.dumps(selector)}); if(el){{ el.value=''; el.dispatchEvent(new Event('input',{{bubbles:true}})); }}"
        })
        time.sleep(0.05)
        # Type via CDP Input.insertText (handles IME, composition)
        chunk_size = 200
        for i in range(0, len(text), chunk_size):
            chunk = text[i:i+chunk_size]
            res, err = send_cdp(conn, "Input.insertText", {"text": chunk})
            if err:
                # fallback: character-by-character key events
                for ch in chunk:
                    send_cdp(conn, "Input.dispatchKeyEvent", {"type": "keyDown", "text": ch, "key": ch})
                    send_cdp(conn, "Input.dispatchKeyEvent", {"type": "keyUp", "text": ch, "key": ch})
            time.sleep(0.01)
        # Fire change event
        send_cdp(conn, "Runtime.evaluate", {
            "expression": (
                f"var el = document.querySelector({json.dumps(selector)});"
                f"if(el){{ el.dispatchEvent(new Event('change',{{bubbles:true}})); }}"
            )
        })
        print(f"OK typed into: {selector}")
        return 0
    finally:
        ws_close(conn)

def cmd_clear(selector):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        if not _wait_for_selector(conn, selector, timeout=5):
            print(f"ERROR: selector not found: {selector}")
            return 1
        res, err = send_cdp(conn, "Runtime.evaluate", {
            "expression": (
                f"var el = document.querySelector({json.dumps(selector)});"
                f"if(el){{ el.value=''; el.dispatchEvent(new Event('input',{{bubbles:true}})); 'cleared'; }}"
                f"else 'not_found';"
            ),
            "returnByValue": True
        })
        val = res.get("result", {}).get("value", "") if res else ""
        if val == "cleared":
            print(f"OK cleared: {selector}")
            return 0
        print(f"ERROR: could not clear {selector}")
        return 1
    finally:
        ws_close(conn)

def cmd_press(key):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        key_map = {
            "Enter": {"key": "Enter", "code": "Enter"},
            "Tab": {"key": "Tab", "code": "Tab"},
            "Escape": {"key": "Escape", "code": "Escape"},
            "Backspace": {"key": "Backspace", "code": "Backspace"},
            "Delete": {"key": "Delete", "code": "Delete"},
            "ArrowUp": {"key": "ArrowUp", "code": "ArrowUp"},
            "ArrowDown": {"key": "ArrowDown", "code": "ArrowDown"},
            "ArrowLeft": {"key": "ArrowLeft", "code": "ArrowLeft"},
            "ArrowRight": {"key": "ArrowRight", "code": "ArrowRight"},
            "Home": {"key": "Home", "code": "Home"},
            "End": {"key": "End", "code": "End"},
        }
        k = key_map.get(key, {"key": key, "code": key})
        send_cdp(conn, "Input.dispatchKeyEvent", {"type": "keyDown", **k})
        send_cdp(conn, "Input.dispatchKeyEvent", {"type": "keyUp", **k})
        print(f"OK pressed: {key}")
        return 0
    finally:
        ws_close(conn)

def cmd_select(selector, option_text):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        if not _wait_for_selector(conn, selector, timeout=5):
            print(f"ERROR: selector not found: {selector}")
            return 1
        expr = (
            f"var el = document.querySelector({json.dumps(selector)});"
            f"if (!el || el.tagName.toLowerCase() !== 'select') return 'not_select';"
            f"for (var i=0; i<el.options.length; i++) {{"
            f"  if (el.options[i].text === {json.dumps(option_text)}) {{ el.selectedIndex=i; break; }}"
            f"}}"
            f"el.dispatchEvent(new Event('change', {{bubbles:true}}));"
            f"'selected';"
        )
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": expr, "returnByValue": True})
        val = res.get("result", {}).get("value", "") if res else ""
        if val == "selected":
            print(f"OK selected '{option_text}' in: {selector}")
            return 0
        print(f"ERROR: could not select in {selector} (got: {val})")
        return 1
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Content extraction
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_get_content(selector=None):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        expr = (
            f"document.querySelector({json.dumps(selector)})?.innerText "
            f"|| document.querySelector({json.dumps(selector)})?.value "
            f"|| document.body?.innerText || ''"
        ) if selector else "document.body ? document.body.innerText : document.documentElement.innerText || ''"
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": expr, "returnByValue": True})
        if err:
            print(f"ERROR get_content: {err}")
            return 1
        value = res.get("result", {}).get("value", "") if res else ""
        print(value[:8000] if value else "(empty)")
        return 0
    finally:
        ws_close(conn)

def cmd_get_html(selector=None):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        expr = (
            f"document.querySelector({json.dumps(selector)})?.innerHTML "
            f"|| document.documentElement?.innerHTML || ''"
        ) if selector else "document.documentElement?.innerHTML || ''"
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": expr, "returnByValue": True})
        if err:
            print(f"ERROR get_html: {err}")
            return 1
        value = res.get("result", {}).get("value", "") if res else ""
        print(value[:8000] if value else "(empty)")
        return 0
    finally:
        ws_close(conn)

def cmd_eval(js_code):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        res, err = send_cdp(conn, "Runtime.evaluate", {
            "expression": js_code,
            "returnByValue": True,
            "awaitPromise": True
        })
        if err:
            print(f"ERROR eval: {err}")
            return 1
        result = res.get("result", {}) if res else {}
        val = result.get("value")
        if val is not None:
            if isinstance(val, (dict, list)):
                print(json.dumps(val, indent=2)[:8000])
            else:
                s = str(val)
                print(s[:8000] if s else "(null/undefined)")
        else:
            print("(no return value)")
        return 0
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Element discovery
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_find(text):
    """Find elements containing the given text. Returns CSS selectors."""
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        js = (
            f"(function() {{"
            f"  var matches = [];"
            f"  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);"
            f"  var node;"
            f"  var needle = {json.dumps(text)}.toLowerCase();"
            f"  while (node = walker.nextNode()) {{"
            f"    if (node.textContent.toLowerCase().indexOf(needle) !== -1) {{"
            f"      var el = node.parentElement;"
            f"      var tag = el.tagName.toLowerCase();"
            f"      if (tag !== 'script' && tag !== 'style') {{"
            f"        var id = el.id ? '#' + el.id : '';"
            f"        var cls = el.className ? '.' + el.className.trim().split(/\\s+/).join('.') : '';"
            f"        var tagSel = el.tagName.toLowerCase();"
            f"        matches.push(tagSel + id + cls);"
            f"      }}"
            f"    }}"
            f"  }}"
            f"  return JSON.stringify(matches.slice(0, 20));"
            f"}})()"
        )
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": js, "returnByValue": True})
        if err:
            print(f"ERROR find: {err}")
            return 1
        raw = res.get("result", {}).get("value", "[]") if res else "[]"
        try:
            selectors = json.loads(raw)
        except Exception:
            selectors = []
        if not selectors:
            print(f"No elements found containing: {text}")
        else:
            print(f"Found {len(selectors)} elements containing '{text}':")
            for s in selectors:
                print(f"  {s}")
        return 0
    finally:
        ws_close(conn)

def cmd_keyinfo(selector):
    """Get label, placeholder, aria-label near an input — for the agent to know what to type."""
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        js = (
            f"(function() {{"
            f"  var el = document.querySelector({json.dumps(selector)});"
            f"  if (!el) return 'not_found';"
            f"  var info = {{tag: el.tagName, type: el.type || '', placeholder: el.placeholder || '', name: el.name || '', id: el.id || ''}};"
            f"  // check associated label"
            f"  var label = null;"
            f"  if (el.id) {{"
            f"    label = document.querySelector('label[for=\"' + el.id + '\"]');"
            f"  }}"
            f"  if (!label) {{"
            f"    label = el.closest('label');"
            f"  }}"
            f"  info.label = label ? label.textContent.trim() : '';"
            f"  // aria-label"
            f"  info.aria = el.getAttribute('aria-label') || '';"
            f"  return JSON.stringify(info);"
            f"}})()"
        )
        res, err = send_cdp(conn, "Runtime.evaluate", {"expression": js, "returnByValue": True})
        if err:
            print(f"ERROR keyinfo: {err}")
            return 1
        val = res.get("result", {}).get("value", "") if res else ""
        if val == "not_found":
            print(f"Element not found: {selector}")
            return 1
        try:
            info = json.loads(val)
            parts = [f"tag={info.get('tag','')}", f"type={info.get('type','')}"]
            if info.get("label"):
                parts.append(f"label='{info['label']}'")
            if info.get("placeholder"):
                parts.append(f"placeholder='{info['placeholder']}'")
            if info.get("aria"):
                parts.append(f"aria='{info['aria']}'")
            if info.get("name"):
                parts.append(f"name='{info['name']}'")
            print("  ".join(parts))
        except Exception:
            print(val)
        return 0
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Screenshot
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_screenshot(path=None):
    if not path:
        path = "/tmp/screenshot.png"
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        # Get page dimensions first
        res, _ = send_cdp(conn, "Runtime.evaluate", {
            "expression": "({w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio || 1})",
            "returnByValue": True
        })
        dims = res.get("result", {}).get("value", {}) if res else {}
        w = int(dims.get("w", 1280))
        h = int(dims.get("h", 800))
        dpr = dims.get("dpr", 1)
        res2, err = send_cdp(conn, "Page.captureScreenshot", {
            "format": "png",
            "captureBeyondViewport": False,
            "clip": {"x": 0, "y": 0, "width": w, "height": h, "scale": dpr}
        }, timeout=20)
        if err:
            print(f"ERROR screenshot: {err}")
            return 1
        data = res2.get("data", "") if res2 else ""
        if not data:
            print("ERROR: empty screenshot data")
            return 1
        import base64
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))
        print(f"OK screenshot saved: {path} ({len(data)} chars base64)")
        return 0
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Cookies & storage (for credential inspection)
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_cookies(url=None):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        if not url:
            res2, _ = send_cdp(conn, "Runtime.evaluate", {
                "expression": "window.location.href", "returnByValue": True
            })
            url = res2.get("result", {}).get("value", "") if res2 else ""
        if not url:
            print("ERROR: no URL specified and cannot detect current URL")
            return 1
        res, err = send_cdp(conn, "Network.getAllCookies")
        if err:
            print(f"ERROR cookies: {err}")
            return 1
        cookies = res.get("cookies", []) if res else []
        # Filter to relevant domain
        domain = url.split("/")[2] if "://" in url else url
        relevant = [c for c in cookies if domain in c.get("domain", "")]
        if not relevant:
            relevant = cookies
        for c in relevant[:30]:
            print(f"  {c.get('name','')} = {c.get('value','')[:40]}  (domain={c.get('domain','')})")
        print(f"({len(relevant)} cookies shown)")
        return 0
    finally:
        ws_close(conn)

def cmd_has_session():
    """Check if the browser has any logged-in sessions (non-expired cookies)."""
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        res, err = send_cdp(conn, "Network.getAllCookies")
        if err:
            print(f"ERROR: {err}")
            return 1
        cookies = res.get("cookies", []) if res else []
        now = time.time()
        active = [c for c in cookies if c.get("expires", -1) > now or c.get("expires", -1) == -1]
        domains = set(c.get("domain", "").lstrip(".") for c in active)
        print(f"Active sessions on {len(domains)} domains:")
        for d in sorted(domains):
            count = sum(1 for c in active if c.get("domain", "").lstrip(".") == d)
            print(f"  {d} ({count} cookies)")
        return 0
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Scrolling
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_scroll(direction="down", amount="page"):
    ws = get_ws_url()
    if not ws:
        print("ERROR: no debuggable page")
        return 1
    conn = ensure_page(ws)
    try:
        pixels = {"page": 800, "half": 400, "line": 100}.get(amount, 800)
        axis = {"down": "y", "up": "y", "left": "x", "right": "x"}.get(direction, "y")
        sign = -1 if direction in ("down", "right") else 1
        res, err = send_cdp(conn, "Runtime.evaluate", {
            "expression": f"window.scrollBy({{'{axis}': {sign * pixels}}}); 'scrolled {direction}'",
            "returnByValue": True
        })
        if not err:
            print(f"OK scrolled {direction}")
        return 0 if not err else 1
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# Window management
# ═══════════════════════════════════════════════════════════════════════════════

def cmd_bring_to_front():
    ws = get_ws_url()
    if not ws:
        print("OK (no page to focus)")
        return 0
    conn = ensure_page(ws)
    try:
        send_cdp(conn, "Page.bringToFront")
        print("OK brought to front")
        return 0
    finally:
        ws_close(conn)


# ═══════════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    cmd = sys.argv[1].lower().replace("-", "_")

    if cmd in ("navigate", "nav", "go"):
        if len(sys.argv) < 3:
            print("usage: browser-ctl navigate <url>")
            return 1
        return cmd_navigate(sys.argv[2])

    elif cmd == "click":
        if len(sys.argv) < 3:
            print("usage: browser-ctl click <css-selector>")
            return 1
        return cmd_click(sys.argv[2])

    elif cmd == "type":
        if len(sys.argv) < 4:
            print("usage: browser-ctl type <css-selector> <text>")
            return 1
        return cmd_type(sys.argv[2], " ".join(sys.argv[3:]))

    elif cmd == "clear":
        if len(sys.argv) < 3:
            print("usage: browser-ctl clear <css-selector>")
            return 1
        return cmd_clear(sys.argv[2])

    elif cmd == "press":
        if len(sys.argv) < 3:
            print("usage: browser-ctl press <key>")
            return 1
        return cmd_press(sys.argv[2])

    elif cmd == "select":
        if len(sys.argv) < 4:
            print("usage: browser-ctl select <css-selector> <option-text>")
            return 1
        return cmd_select(sys.argv[2], sys.argv[3])

    elif cmd == "wait":
        if len(sys.argv) < 3:
            print("usage: browser-ctl wait <css-selector> [timeout]")
            return 1
        timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 10
        ws = get_ws_url()
        if not ws:
            print("ERROR: no debuggable page")
            return 1
        conn = ensure_page(ws)
        try:
            found = _wait_for_selector(conn, sys.argv[2], timeout)
            print(f"OK found: {sys.argv[2]}" if found else f"TIMEOUT: {sys.argv[2]}")
            return 0 if found else 1
        finally:
            ws_close(conn)

    elif cmd == "text":
        sel = sys.argv[2] if len(sys.argv) > 2 else None
        return cmd_get_content(sel)

    elif cmd in ("html", "source"):
        sel = sys.argv[2] if len(sys.argv) > 2 else None
        return cmd_get_html(sel)

    elif cmd == "screenshot":
        path = sys.argv[2] if len(sys.argv) > 2 else None
        return cmd_screenshot(path)

    elif cmd == "cookies":
        url = sys.argv[2] if len(sys.argv) > 2 else None
        return cmd_cookies(url)

    elif cmd == "has_session":
        return cmd_has_session()

    elif cmd == "eval":
        if len(sys.argv) < 3:
            print("usage: browser-ctl eval <javascript>")
            return 1
        return cmd_eval(" ".join(sys.argv[2:]))

    elif cmd == "find":
        if len(sys.argv) < 3:
            print("usage: browser-ctl find <text>")
            return 1
        return cmd_find(" ".join(sys.argv[2:]))

    elif cmd == "keyinfo":
        if len(sys.argv) < 3:
            print("usage: browser-ctl keyinfo <css-selector>")
            return 1
        return cmd_keyinfo(sys.argv[2])

    elif cmd == "scroll":
        direction = sys.argv[2] if len(sys.argv) > 2 else "down"
        amount = sys.argv[3] if len(sys.argv) > 3 else "page"
        return cmd_scroll(direction, amount)

    elif cmd in ("back",):
        return cmd_back()

    elif cmd in ("forward",):
        return cmd_forward()

    elif cmd in ("reload",):
        return cmd_reload()

    elif cmd == "url":
        return cmd_url()

    elif cmd == "title":
        return cmd_title()

    elif cmd in ("bring-to-front", "front", "activate"):
        return cmd_bring_to_front()

    else:
        print(f"unknown command: {cmd}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
