#!/usr/bin/env bash
set -e
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
python init_db.py
printf "
CultureQuest is ready. Run: source .venv/bin/activate && python run.py
"
