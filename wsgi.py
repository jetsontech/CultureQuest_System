import os
import sys

# Ensure the root directory is in the python path
sys.path.append(os.path.dirname(__file__))

# Minimal test: does the Vercel runtime work at all?
from flask import Flask

_init_error = None
_real_app = None

try:
    from app import create_app
    _real_app = create_app()
except Exception:
    import traceback
    _init_error = traceback.format_exc()

if _real_app:
    app = _real_app
else:
    app = Flask(__name__)

    @app.route("/")
    def index():
        return f"<pre>CultureQuest failed to start:\n\n{_init_error}</pre>", 500

    @app.route("/health")
    def health():
        return f"<pre>INIT ERROR:\n\n{_init_error}</pre>", 500

application = app
