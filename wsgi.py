# CultureQuest Production Entry Point - Vercel Ready
from app import create_app
import os
from dotenv import load_dotenv

# Load environment variables from .env for local development
load_dotenv()

app = create_app()

if __name__ == "__main__":
    app.run()
