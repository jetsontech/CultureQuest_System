import os
from flask import Flask
from .db import init_app
from .views import public_bp, admin_bp, api_bp
from .hls_proxy import hls_bp

def create_app():
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("CQ_SECRET_KEY", "dev-secret-change-this"),
        DATABASE=os.path.join(app.instance_path, "culturequest.db"),
        UPLOAD_FOLDER=os.path.join(app.instance_path, "uploads"),
        MAX_CONTENT_LENGTH=1024 * 1024 * 1024,
    )

    try:
        os.makedirs(app.instance_path, exist_ok=True)
        os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)
    except OSError:
        pass # Support read-only filesystems like Vercel

    init_app(app)

    app.register_blueprint(public_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(hls_bp)

    return app
