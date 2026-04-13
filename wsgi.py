import os
import sys

# Ensure the root directory is in the python path
sys.path.append(os.path.dirname(__file__))

from app import create_app

app = create_app()
application = app

