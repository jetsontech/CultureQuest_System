python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
python init_db.py
Write-Host "`nCultureQuest is ready. Run: .\.venv\Scripts\Activate.ps1 ; python run.py"
