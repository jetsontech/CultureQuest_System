import os
import sys
import importlib.util

# Ensure the project root is FIRST in the python path
_project_root = os.path.dirname(os.path.abspath(__file__))
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

_init_error = None
_real_app = None

try:
    # Explicitly load the local app package by file path to avoid
    # Vercel's internal 'app' module shadowing our package
    _app_init = os.path.join(_project_root, "app", "__init__.py")
    _spec = importlib.util.spec_from_file_location("app", _app_init, 
        submodule_search_locations=[os.path.join(_project_root, "app")])
    _mod = importlib.util.module_from_spec(_spec)
    sys.modules["app"] = _mod
    _spec.loader.exec_module(_mod)
    
    _real_app = _mod.create_app()
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
