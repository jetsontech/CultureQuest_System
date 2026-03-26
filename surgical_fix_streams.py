from pathlib import Path

path = Path(r".\app\views.py")
lines = path.read_text(encoding="utf-8").splitlines()

out = []
i = 0
seen_routed_streams = False

while i < len(lines):
    line = lines[i]

    # remove orphan bare def streams block
    if line.strip() == "def streams(filename):":
        prev = lines[i-1].strip() if i > 0 else ""
        if prev != '@public_bp.route("/streams/<path:filename>")':
            i += 1
            # skip indented body lines
            while i < len(lines) and (lines[i].startswith("    ") or lines[i].strip() == ""):
                i += 1
            continue

    # keep only one routed streams block
    if line.strip() == '@public_bp.route("/streams/<path:filename>")':
        if seen_routed_streams:
            i += 1
            while i < len(lines) and (lines[i].startswith("def streams(") or lines[i].startswith("    ") or lines[i].strip() == ""):
                i += 1
            continue
        seen_routed_streams = True

    out.append(line)
    i += 1

path.write_text("\n".join(out) + "\n", encoding="utf-8")
print("Removed orphan/duplicate streams blocks.")
