from functools import wraps
from flask import session, redirect, url_for, flash


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        from flask import request, jsonify
        if not session.get('user_id'):
            if request.path.startswith('/api/'):
                return jsonify({"error": "Unauthorized", "message": "Please sign in to continue."}), 401
            flash('Please sign in to continue.', 'warning')
            return redirect(url_for('admin.login'))
        return view(*args, **kwargs)
    return wrapped


def admin_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        from flask import request, jsonify
        if not session.get('user_id'):
            if request.path.startswith('/api/'):
                return jsonify({"error": "Unauthorized", "message": "Please sign in to continue."}), 401
            flash('Please sign in to continue.', 'warning')
            return redirect(url_for('admin.login'))
        if not session.get('is_admin'):
            if request.path.startswith('/api/'):
                return jsonify({"error": "Forbidden", "message": "Admin access required."}), 403
            flash('Admin access required.', 'danger')
            return redirect(url_for('public.home'))
        return view(*args, **kwargs)
    return wrapped
