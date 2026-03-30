from flask import Flask`n`ndef create_app():`n    app = Flask(__name__)`n`n    @app.route("/")`n    def index():`n        return "Culture Quest System is running!"`n`n    return app
