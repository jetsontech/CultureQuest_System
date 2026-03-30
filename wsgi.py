import sys
import traceback
from app import create_app

try:
    app = create_app()
    application = app
except Exception as e:
    print("CRITICAL: Failed to create app", file=sys.stderr)
    traceback.print_exc()
    raise e
