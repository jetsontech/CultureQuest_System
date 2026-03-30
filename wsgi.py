import sys
import traceback

try:
    from app import create_app
    app = create_app()
    application = app
except Exception as e:
    print("CRITICAL: Failed to create app at import or call time", file=sys.stderr)
    traceback.print_exc()
    raise e
