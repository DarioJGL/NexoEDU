from functools import wraps
import re
from flask import flash, redirect, url_for, session
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
from db import conectar_mysql
from flask import Flask


# Función para verificar si el usuario está logueado
def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if "user_id" not in session:
            flash("Debes iniciar sesión para acceder a esta página", "warning")
            return redirect(url_for("login"))
        return f(*args, **kwargs)

    return decorated_function


# Función para verificar rol específico
def role_required(roles):
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            if "user_tipo" not in session or session["user_tipo"] not in roles:
                flash("No tienes permisos para acceder a esta página", "error")
                return redirect(url_for("dashboard"))
            return f(*args, **kwargs)

        return decorated_function

    return decorator
