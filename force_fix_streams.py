from pathlib import Path
import re

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")

pattern = re.compile(
    r'(?ms)(?:@public_bp\.route\("/streams/<path:filename>"\)\s*)?def streams\(filename\):\s*return send_from_directory\(os\.path\.join\(os\.getcwd\(\), "streams"\), filename\)\s*'
)

matches = list(pattern.finditer(text))
print("matches found:", len(matches))

# remove all existing streams blocks
text = pattern.sub("", text).rstrip()

# add exactly one correct block
text += """

@public_bp.route("/streams/<path:filename>")
def streams(filename):
    return send_from_directory(os.path.join(os.getcwd(), "streams"), filename)
"""

path.write_text(text, encoding="utf-8")
print("Rebuilt streams route cleanly.")
