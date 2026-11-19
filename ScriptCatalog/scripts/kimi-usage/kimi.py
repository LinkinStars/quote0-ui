#!/usr/bin/env python3
"""Fetch Kimi usage and render a 296×152 monochrome progress dashboard."""
import base64
import io
import json
import math
import sys
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 296, 152


def remaining_percent(detail):
    limit = float(detail.get("limit") or 0)
    used = float(detail.get("used") or 0)
    return max(0, min(100, round(100 - used / limit * 100))) if limit > 0 else None


def reset_label(value, weekly=False):
    if value is None:
        return ""
    try:
        if isinstance(value, (int, float)):
            reset = datetime.fromtimestamp(value / 1000 if value > 1e10 else value, tz=timezone.utc)
        else:
            reset = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        minutes = max(0, math.ceil((reset - datetime.now(timezone.utc)).total_seconds() / 60))
        if weekly and minutes >= 1440:
            days, remaining_minutes = divmod(minutes, 1440)
            return f"  {days}d{remaining_minutes // 60}h"
        return f"  {minutes // 60}h{minutes % 60:02d}m" if minutes >= 60 else f"  {minutes}m"
    except (ValueError, TypeError, OSError):
        return ""


def font(size):
    # Verdana's wider letterforms stay legible on the 296 px e-ink display.
    for name in ("Verdana Bold.ttf", "Arial Bold.ttf"):
        try:
            return ImageFont.truetype("/System/Library/Fonts/Supplemental/" + name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def draw_bar(draw, y, label, remaining, reset):
    draw.text((12, y), label, font=font(13), fill=0)
    note = f"{remaining}% left" + reset
    note_font = font(15)
    note_width = draw.textlength(note, font=note_font)
    draw.text((WIDTH - 12 - note_width, y), note, font=note_font, fill=0)
    left, top, right, bottom = 12, y + 20, WIDTH - 12, y + 37
    draw.rectangle((left, top, right, bottom), outline=0, width=1)
    used_width = round((right - left - 3) * (100 - remaining) / 100)
    if used_width:
        draw.rectangle((left + 2, top + 2, left + 1 + used_width, bottom - 2), fill=0)
    for x in range(left + 4 + used_width, right - 2, 5):
        for dot_y in range(top + 4, bottom - 2, 5):
            draw.point((x, dot_y), fill=0)


def main():
    parameters = json.load(sys.stdin).get("parameters", {})
    key = str(parameters.get("kimiApiKey") or "").strip()
    if not key:
        raise ValueError("请在脚本配置中填写 Kimi API Key")
    request = Request("https://api.kimi.com/coding/v1/usages", headers={
        "Authorization": "Bearer " + key, "Accept": "application/json"})
    with urlopen(request, timeout=15) as response:
        data = json.load(response)
    rows = []
    limits = data.get("limits") or []
    if limits:
        detail = limits[0].get("detail") or {}
        remaining = remaining_percent(detail)
        if remaining is not None:
            rows.append(("5 HOUR", remaining, reset_label(detail.get("resetTime"))))
    usage = data.get("usage") or {}
    remaining = remaining_percent(usage)
    if remaining is not None:
            rows.append(("WEEKLY", remaining, reset_label(usage.get("resetTime"), weekly=True)))
    if not rows:
        raise ValueError("Kimi 返回的数据没有可显示的用量")
    if not parameters.get("showResetTime", True):
        rows = [(label, pct, "") for label, pct, _ in rows]

    image = Image.new("L", (WIDTH, HEIGHT), 255)
    draw = ImageDraw.Draw(image)
    level = ((data.get("user") or {}).get("membership") or {}).get("level") or ""
    title = "KIMI" + ("  /  " + str(level).removeprefix("LEVEL_") if level else "")
    draw.text((12, 8), title, font=font(17), fill=0)
    stamp = datetime.now().strftime("%m-%d %H:%M")
    stamp_font = font(11)
    stamp_width = draw.textlength(stamp, font=stamp_font)
    draw.text((WIDTH - 12 - stamp_width, 13), stamp, font=stamp_font, fill=0)
    draw.line((0, 34, WIDTH, 34), fill=0, width=1)
    first_y = 50 if len(rows) == 2 else 72
    for index, (label, pct, reset) in enumerate(rows):
        draw_bar(draw, first_y + index * 52, label, pct, reset)
    output = io.BytesIO()
    # Remove antialiased grey edge pixels; the device renders pure black and white sharply.
    image.point(lambda value: 255 if value >= 180 else 0).convert("RGB").save(output, format="PNG")
    json.dump({"protocolVersion": 1, "type": "image", "content": {
        "image": "data:image/png;base64," + base64.b64encode(output.getvalue()).decode("ascii"),
        "ditherType": "NONE", "border": 0}}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except HTTPError as exc:
        if exc.code == 429:
            print("Kimi 用量接口返回 429：请求过于频繁或当前额度受限，请稍后再试。", file=sys.stderr)
        else:
            print(f"Kimi 用量接口返回 HTTP {exc.code}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, URLError, TimeoutError, ImportError) as exc:
        print(f"Kimi 用量获取或渲染失败：{exc}", file=sys.stderr)
        sys.exit(1)
