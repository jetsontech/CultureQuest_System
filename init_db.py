from cq_app import create_app
from cq_app.db import init_db
from cq_app.db_upgrade import ensure_platform_foundation

app = create_app()
with app.app_context():
    init_db()
    ensure_platform_foundation()
print('Database initialized and seeded.')
