import re


def validar_email(email):
    """Validar formato de email"""
    patron = r"^[^\s@]+@[^\s@]+\.[^\s@]+$"
    return re.match(patron, email) is not None


def validar_password(password):
    """Validar fortaleza de contraseña"""
    if len(password) < 8:
        return False, "La contraseña debe tener al menos 8 caracteres"
    if not re.search(r"[a-z]", password):
        return False, "La contraseña debe contener al menos una letra minúscula"
    if not re.search(r"[A-Z]", password):
        return False, "La contraseña debe contener al menos una letra mayúscula"
    if not re.search(r"[0-9]", password):
        return False, "La contraseña debe contener al menos un número"
    return True, "Contraseña válida"


def validar_documento(documento):
    """Validar documento de identidad"""
    # Solo números y longitud entre 5 y 20 caracteres
    if not re.match(r"^\d{5,20}$", documento):
        return (
            False,
            "El documento debe contener solo números y tener entre 5 y 20 dígitos",
        )
    return True, "Documento válido"
