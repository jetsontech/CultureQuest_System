import sys
import os

# 1. Add the current directory to path so 'app' folder can be found
sys.path.append(os.path.dirname(__file__))

# 2. Import the actual Flask/FastAPI instance from your app folder
# Assuming your Flask object is named 'app' inside 'app/__init__.py'
from app import app

# 3. Vercel MUST see a variable named 'app' or 'application' at the top level
application = app
app = app # Just to be safe for all Vercel versions

if __name__ == "__main__":
    app.run()