import os
from flask import Flask
from .db import close_db, init_db_command
from .views import public_bp, admin_bp, api_bp
from .hls_proxy import hls_bp
from .db_upgrade import ensure_platform_foundation


def create_app():
    app = Flask(__name__, instance_relative_config=True)
    
    # Use environment variables for production, with safe dev defaults
    secret_key = os.environ.get("FLASK_SECRET_KEY", os.environ.get("CQ_SECRET_KEY", "dev-secret-change-this"))
    db_path = os.path.join(app.instance_path, "culturequest.db")
    
    app.config.from_mapping(
        SECRET_KEY=secret_key,
        DATABASE=db_path,
        UPLOAD_FOLDER=os.path.join(os.getcwd(), "app", "static", "uploads"),
        MAX_CONTENT_LENGTH=10 * 1024 * 1024 * 1024,
        SEND_FILE_MAX_AGE_DEFAULT=3600,
    )

    # On Vercel, the filesystem is read-only except for /tmp
    # We only create directories if we're not in a production postgres environment
    if not os.getenv("DATABASE_URL"):
        try:
            os.makedirs(app.instance_path, exist_ok=True)
            os.makedirs(app.config["UPLOAD_FOLDER"], exist_ok=True)
        except OSError:
            pass # Ignore if read-only

    app.teardown_appcontext(close_db)
    app.cli.add_command(init_db_command)

    with app.app_context():
        try:
            # Only run this if we have a DB URL or we are NOT on Vercel
            if os.getenv("DATABASE_URL") or not os.getenv("VERCEL"):
                ensure_platform_foundation()
        except Exception as e:
            app.logger.error(f"Migration error: {e}")
            # Do NOT crash the app if migration fails, just log it
            pass

    app.register_blueprint(public_bp)
    app.register_blueprint(admin_bp)
    app.register_blueprint(api_bp)
    app.register_blueprint(hls_bp)
    
    return app
