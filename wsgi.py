import os
import sys

# Ensure the root directory is in the python path
sys.path.append(os.path.dirname(__file__))

try:
    from app import create_app
    app = create_app()
except Exception as e:
    import traceback
    # If the app fails to initialize, create a minimal diagnostic app
    from flask import Flask
    app = Flask(__name__)
    _error = traceback.format_exc()

    @app.route("/health")
    def health():
        return f"INIT ERROR:\n{_error}", 500

    @app.route("/")
    def index():
        return f"CultureQuest failed to start:\n{_error}", 500

application = app
