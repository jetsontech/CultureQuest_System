from pathlib import Path

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

out = []
skip_mode = False
seen_stream_route = False

i = 0
while i < len(lines):
    line = lines[i].rstrip("\n")
    stripped = line.strip()

    # kill single-quote duplicate decorator
    if stripped == "@public_bp.route('/streams/<path:filename>')":
        i += 1
        continue

    # handle main double-quote decorator
    if stripped == '@public_bp.route("/streams/<path:filename>")':
        if seen_stream_route:
            i += 1
            continue
        seen_stream_route = True
        out.append(line)
        i += 1
        continue

    # remove orphan def streams not immediately preceded by the decorator
    if stripped == "def streams(filename):":
        prev = out[-1].strip() if out else ""
        if prev != '@public_bp.route("/streams/<path:filename>")':
            i += 1
            while i < len(lines) and (lines[i].startswith("    ") or lines[i].strip() == ""):
                i += 1
            continue
        out.append(line)
        i += 1
        continue

    out.append(line)
    i += 1

path.write_text("\n".join(out) + "\n", encoding="utf-8")
print("Cleaned duplicate streams route definitions.")
