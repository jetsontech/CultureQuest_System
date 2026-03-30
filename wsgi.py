import sys
import os

# Add the current directory to sys.path
sys.path.insert(0, os.path.dirname(__file__))

# Import the 'app' instance from your 'app' folder
try:
    from app import app
    # Vercel specifically looks for a variable named 'app' or 'application'
    application = app
except ImportError as e:
    print(f"Import Error: {e}")
    raise

if __name__ == "__main__":
    app.run()