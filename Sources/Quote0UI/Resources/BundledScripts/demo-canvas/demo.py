import json
import sys
from datetime import datetime

# Based on Dot.'s public Canvas API card example:
# https://dot.mindreset.tech/docs/service/open/canvas_api

json.load(sys.stdin)

def node(kind, classes, children, style=None):
    props = {"tw": classes, "children": children}
    if style:
        props["style"] = style
    return {"type": kind, "props": props}

content = {
    "taskAlias": "Dot. Canvas 示例",
    "data": {
        "badge": "DOT OPENAPI",
        "status": "LIVE",
        "title": "Canvas API",
        "message": "Compose screen content, state, and layout with JSON.",
        "footer": "QUOTE0UI / " + datetime.now().strftime("%H:%M"),
    },
    "windowData": {"default": [
        node("div", "flex flex-col w-full h-full min-w-0 min-h-0 bg-white text-black gap-[8px]", [
            node("div", "flex flex-row items-center justify-between shrink-0 text-10-chillduansans", [
                node("span", "font-bold", '{{get inputData "badge"}}'),
                node("span", "", '{{get inputData "status"}}'),
            ]),
            node("div", "flex flex-col flex-1 min-h-0 justify-center gap-[6px]", [
                node("div", "text-28-chillduansans font-bold leading-none min-w-0", '{{get inputData "title"}}',
                     {"lineClamp": 2, "overflow": "hidden", "textOverflow": "ellipsis"}),
                node("div", "text-16-chillduansans leading-[1.16] min-w-0", '{{get inputData "message"}}',
                     {"lineClamp": 3, "overflow": "hidden", "textOverflow": "ellipsis"}),
            ]),
            node("div", "flex flex-row items-center gap-[6px] shrink-0 text-10-chillduansans", [
                node("span", "w-[6px] h-[6px] rounded-full bg-black shrink-0", ""),
                node("span", "min-w-0", '{{get inputData "footer"}}',
                     {"overflow": "hidden", "textOverflow": "ellipsis", "whiteSpace": "nowrap"}),
            ]),
        ])
    ]},
    "layoutFull": {"tw": "p-[12px]"},
    "border": 0,
}
json.dump({"protocolVersion": 1, "type": "canvas", "content": content}, sys.stdout, ensure_ascii=False)
