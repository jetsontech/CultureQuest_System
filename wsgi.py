# CultureQuest Production Entry Point - Vercel Ready
from app import create_app
import os
from dotenv import load_dotenv

# Load environment variables from .env for local development
load_dotenv()

import sys
import traceback

try:
    app = create_app()
except Exception as e:
    print("FATAL: Failed to create app", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    # Create a dummy app to report the error if possible
    from flask import Flask
    app = Flask(__name__)
    @app.route('/')
    @app.route('/<path:path>')
    def error_page(path=None):
        return f"Startup Error: {e}<br><pre>{traceback.format_exc()}</pre>", 500

if __name__ == "__main__":
    app.run()
