import json
import sys

parameters = json.load(sys.stdin).get("parameters", {})
message = str(parameters.get("message") or "")
if not message.strip():
    print("请填写展示文字", file=sys.stderr)
    sys.exit(1)
json.dump({"protocolVersion": 1, "type": "text", "content": {"message": message}}, sys.stdout, ensure_ascii=False)
