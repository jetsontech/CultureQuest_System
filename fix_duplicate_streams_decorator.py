from pathlib import Path
import re

path = Path(r".\app\views.py")
text = path.read_text(encoding="utf-8")

text = re.sub(
    r'@public_bp\.route\(\'/streams/<path:filename>\'\)\s*@public_bp\.route\("/streams/<path:filename>"\)',
    '@public_bp.route("/streams/<path:filename>")',
    text
)

path.write_text(text, encoding="utf-8")
print("Removed duplicate streams decorator.")
