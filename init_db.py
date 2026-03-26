from app import create_app
from app.db import init_db, seed_defaults

app = create_app()
with app.app_context():
    init_db()
    seed_defaults()
print('Database initialized and seeded.')
