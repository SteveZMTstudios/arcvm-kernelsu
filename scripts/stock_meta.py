import json
import sys

PATH = "kernel/stock-vmlinux.json"

with open(PATH) as f:
    data = json.load(f)

if len(sys.argv) == 2 and sys.argv[1] == "--first-key":
    print(next(iter(data)))
    raise SystemExit(0)

if len(sys.argv) != 3:
    raise SystemExit("usage: stock_meta.py <version/arch> {url|md5} | --first-key")

key, field = sys.argv[1], sys.argv[2]
meta = data.get(key)
if not meta:
    raise SystemExit(f"no stock vmlinux entry for {key}")
print(meta.get(field, ""))
