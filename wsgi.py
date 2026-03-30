import sys
import os

# Add the current directory to path so the 'app' folder can be found
sys.path.append(os.path.dirname(__file__))

# 1. Import your factory function (just like run.py)
from app import create_app

# 2. Build the app instance!
app = create_app()

# 3. Hand the built app over to Vercel
application = app