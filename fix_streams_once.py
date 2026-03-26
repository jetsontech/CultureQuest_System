from pathlib import Path
import re

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")

# remove every existing streams() block
text = re.sub(
    r'(?ms)@public_bp\.route\("/streams/<path:filename>"\)\s*def streams\(filename\):\s*return send_from_directory\(os\.path\.join\(os\.getcwd\(\), "streams"\), filename\)\s*',
    '',
    text
)

text = re.sub(
    r'(?ms)def streams\(filename\):\s*return send_from_directory\(os\.path\.join\(os\.getcwd\(\), "streams"\), filename\)\s*',
    '',
    text
)

# add back exactly one correct block
text = text.rstrip() + """

@public_bp.route("/streams/<path:filename>")
def streams(filename):
    return send_from_directory(os.path.join(os.getcwd(), "streams"), filename)
"""

path.write_text(text, encoding="utf-8")
print("Fixed duplicate streams route.")
