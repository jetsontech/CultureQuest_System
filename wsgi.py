import os
import sys

# Ensure the project root is FIRST in the python path so our 'app' package
# is found before any Vercel-internal 'app' module
_project_root = os.path.dirname(os.path.abspath(__file__))
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

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
    from flask import Flask
    app = Flask(__name__)

    @app.route("/")
    def index():
        return f"<pre>CultureQuest failed to start:\n\n{_init_error}</pre>", 500

    @app.route("/health")
    def health():
        return f"<pre>INIT ERROR:\n\n{_init_error}</pre>", 500

application = app
