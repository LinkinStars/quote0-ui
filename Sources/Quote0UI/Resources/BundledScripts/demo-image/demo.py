import base64
import io
import json
import sys
from pathlib import Path

from PIL import Image, ImageOps

WIDTH, HEIGHT = 296, 152


def clamp(value):
    return max(-1.0, min(1.0, float(value or 0)))


def render(picture):
    source = Path(str(picture.get("path") or ""))
    if not source.is_file():
        raise ValueError("请先选择展示图片")
    mode = picture.get("mode") or "fill"
    if mode not in ("fit", "fill", "stretch", "tile"):
        raise ValueError("图片显示方式无效")
    with Image.open(source) as opened:
        image = ImageOps.exif_transpose(opened).convert("RGB")
    if image.width * image.height > 100_000_000:
        raise ValueError("图片尺寸过大")
    canvas = Image.new("RGB", (WIDTH, HEIGHT), "white")
    x, y = clamp(picture.get("offsetX")), clamp(picture.get("offsetY"))
    if mode == "stretch":
        canvas = image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
    elif mode == "tile":
        scale = min(148 / image.width, 76 / image.height)
        tile = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.Resampling.LANCZOS)
        start_x = round(x * tile.width / 2) - tile.width
        start_y = round(y * tile.height / 2) - tile.height
        for top in range(start_y, HEIGHT, tile.height):
            for left in range(start_x, WIDTH, tile.width):
                canvas.paste(tile, (left, top))
    else:
        scale = min(WIDTH / image.width, HEIGHT / image.height) if mode == "fit" else max(WIDTH / image.width, HEIGHT / image.height)
        sized = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.Resampling.LANCZOS)
        slack_x, slack_y = WIDTH - sized.width, HEIGHT - sized.height
        left = round(slack_x / 2 + x * abs(slack_x) / 2)
        top = round(slack_y / 2 + y * abs(slack_y) / 2)
        canvas.paste(sized, (left, top))
    return canvas.convert("L").convert("RGB")


def main():
    picture = json.load(sys.stdin).get("parameters", {}).get("picture") or {}
    output = io.BytesIO()
    render(picture).save(output, format="PNG")
    json.dump({"protocolVersion": 1, "type": "image", "content": {
        "image": "data:image/png;base64," + base64.b64encode(output.getvalue()).decode("ascii"),
        "ditherType": "DIFFUSION", "border": 0
    }}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ImportError) as exc:
        print(f"图片处理失败：{exc}", file=sys.stderr)
        sys.exit(1)
