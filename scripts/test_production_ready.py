import os
import sys
from app import create_app

def verify():
    print("Checking Production Readiness...")
    
    # 1. Check requirements
    req_file = "requirements.txt"
    if os.path.exists(req_file):
        with open(req_file, 'r') as f:
            reqs = f.read()
            for r in ['boto3', 'psycopg2-binary', 'python-dotenv']:
                if r in reqs:
                    print(f"  [OK] Found {r} in requirements.txt")
                else:
                    print(f"  [ERR] Missing {r} in requirements.txt")
                    
    # 2. Check deployment files
    for f in ['vercel.json', 'wsgi.py', '.gitignore', '.env.example']:
        if os.path.exists(f):
            print(f"  [OK] Found {f}")
        else:
            print(f"  [ERR] Missing {f}")
            
    # 3. Try to initialize app
    try:
        app = create_app()
        print("  [OK] Flask app initialized successfully")
    except Exception as e:
        print(f"  [ERR] App initialization failed: {e}")
        
    print("\nNext Steps:")
    print("1. Create a Supabase project and get your DATABASE_URL.")
    print("2. Create a Cloudflare R2 bucket and get S3 credentials.")
    print("3. Push this code to a new GitHub repository.")
    print("4. Connect GitHub to Vercel and add your environment variables.")

if __name__ == "__main__":
    verify()
