# CultureQuest

CultureQuest is a working local MVP for a streaming platform with a public viewer experience and an admin control panel.

## What this build includes
- Public home page
- Beacon live TV guide
- Channel detail pages with playable media or stream URLs
- Admin login
- Channel CRUD
- Asset upload and media library
- Schedule CRUD
- Premium plan management
- JSON API endpoints
- Local SQLite database
- FFmpeg helper scripts for HLS-oriented media prep

## Default admin login
- Email: `admin@culturequest.local`
- Password: `ChangeMe123!`

Change the password after first login.

## Quick start
### Windows PowerShell
```powershell
./setup.ps1
.\.venv\Scripts\Activate.ps1
python run.py
```

### macOS / Linux
```bash
chmod +x setup.sh
./setup.sh
source .venv/bin/activate
python run.py
```

Then open `http://127.0.0.1:5000`.

## Important notes
This is a real working local MVP. It is not a licensed premium carriage platform. Disney, HBO, ESPN, and similar premium networks require distribution rights, carriage agreements, or reseller partnerships before they can legally be offered.
small note
