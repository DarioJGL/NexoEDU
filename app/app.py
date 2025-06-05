from functools import wraps
from pyexpat import model
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
from db import conectar_mysql
from flask import (
    Flask,
    flash,
    render_template,
    request,
    redirect,
    url_for,
    session,
    jsonify,
    request,
)
from flask_sqlalchemy import SQLAlchemy
import os, datetime, re
from templates.register.validations import (
    validar_email,
    validar_password,
    validar_documento,
)
from templates.login.validations import login_required, role_required
import random
import google.generativeai as genai
from dotenv import load_dotenv
import requests

load_dotenv()

app = Flask(__name__)

app.secret_key = os.urandom(24).hex()


@app.route("/")
def index():
    return render_template("index.html", title="Inicio")


@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        try:
            # Obtener datos del formulario
            nombres = request.form.get("nombres", "").strip()
            apellidos = request.form.get("apellidos", "").strip()
            email = request.form.get("email", "").strip().lower()
            documento_identidad = request.form.get("documento_identidad", "").strip()
            password = request.form.get("password", "")
            confirm_password = request.form.get("confirm_password", "")
            tipo_usuario = request.form.get("tipo_usuario", "estudiante")
            terms = request.form.get("terms")

            print(
                f"DEBUG - Datos recibidos: nombres={nombres}, apellidos={apellidos}, email={email}, documento={documento_identidad}"
            )

            # Validaciones
            errores = []

            # Validar nombres
            if len(nombres) < 2:
                errores.append("Los nombres deben tener al menos 2 caracteres")
            elif not re.match(r"^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s]+$", nombres):
                errores.append("Los nombres solo pueden contener letras y espacios")

            # Validar apellidos
            if len(apellidos) < 2:
                errores.append("Los apellidos deben tener al menos 2 caracteres")
            elif not re.match(r"^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s]+$", apellidos):
                errores.append("Los apellidos solo pueden contener letras y espacios")

            # Validar email
            if not validar_email(email):
                errores.append("El formato del email no es válido")

            # Validar documento
            es_valido_doc, mensaje_doc = validar_documento(documento_identidad)
            if not es_valido_doc:
                errores.append(mensaje_doc)

            # Validar contraseña
            es_valida, mensaje_password = validar_password(password)
            if not es_valida:
                errores.append(mensaje_password)

            # Validar confirmación de contraseña
            if password != confirm_password:
                errores.append("Las contraseñas no coinciden")

            # Validar términos
            if not terms:
                errores.append("Debes aceptar los términos y condiciones")

            if errores:
                for error in errores:
                    flash(error, "error")
                print(f"DEBUG - Errores de validación: {errores}")
                return render_template(
                    "register/register.html", title="Registro de Usuario"
                )

            # Conectar a la base de datos
            print("DEBUG - Intentando conectar a la base de datos...")
            conexion = conectar_mysql()
            if conexion is None:
                flash(
                    "Error de conexión a la base de datos. Intenta más tarde.", "error"
                )
                print("DEBUG - Error de conexión a la base de datos")
                return render_template(
                    "register/register.html", title="Registro de Usuario"
                )

            cursor = conexion.cursor()
            print("DEBUG - Conexión exitosa, verificando duplicados...")

            # Verificar si el email ya existe
            cursor.execute("SELECT id_usuario FROM USUARIO WHERE email = %s", (email,))
            if cursor.fetchone():
                flash(
                    "Este email ya está registrado. Usa otro email o inicia sesión.",
                    "error",
                )
                cursor.close()
                conexion.close()
                print("DEBUG - Email ya existe")
                return render_template(
                    "register/register.html", title="Registro de Usuario"
                )

            # Verificar si el documento ya existe
            cursor.execute(
                "SELECT id_usuario FROM USUARIO WHERE documento_identidad = %s",
                (documento_identidad,),
            )
            if cursor.fetchone():
                flash("Este documento ya está registrado. Verifica tus datos.", "error")
                cursor.close()
                conexion.close()
                print("DEBUG - Documento ya existe")
                return render_template(
                    "register/register.html", title="Registro de Usuario"
                )

            # Crear hash de la contraseña
            print("DEBUG - Creando hash de contraseña...")
            password_hash = generate_password_hash(password, method="pbkdf2:sha256")

            # Insertar nuevo usuario
            query = """
                INSERT INTO USUARIO (email, password_hash, nombres, apellidos, 
                                   documento_identidad, tipo_usuario, fecha_registro, activo)
                VALUES (%s, %s, %s, %s, %s, %s, %s, TRUE)
            """

            fecha_actual = datetime.datetime.now()
            valores = (
                email,
                password_hash,
                nombres,
                apellidos,
                documento_identidad,
                tipo_usuario,
                fecha_actual,
            )

            print(f"DEBUG - Ejecutando query con valores: {valores}")
            cursor.execute(query, valores)
            conexion.commit()

            # Obtener el ID del usuario recién creado
            user_id = cursor.lastrowid
            print(f"DEBUG - Usuario creado con ID: {user_id}")

            cursor.close()
            conexion.close()

            # Crear sesión
            session["user_id"] = user_id
            session["user_email"] = email
            session["user_name"] = f"{nombres} {apellidos}"
            session["user_tipo"] = tipo_usuario

            flash("¡Cuenta creada exitosamente! Bienvenido a NexoEDU", "success")
            print("DEBUG - Usuario registrado exitosamente")
            return redirect(url_for("login"))

        except Exception as e:
            print(f"DEBUG - Error en registro: {str(e)}")
            flash(f"Error al crear la cuenta: {str(e)}", "error")
            return render_template(
                "register/register.html", title="Registro de Usuario"
            )

    # GET request - mostrar formulario
    return render_template("register/register.html", title="Registro de Usuario")


@app.route("/login", methods=["GET", "POST"])
def login():

    if request.method == "POST":
        try:
            email = request.form.get("email", "").strip().lower()
            password = request.form.get("password", "")
            remember_me = request.form.get("remember_me")

            print(f"DEBUG - Intento de login: email={email}")

            # Validaciones básicas
            if not email or not password:
                flash("Email y contraseña son requeridos", "error")
                return render_template("login/login.html", title="Iniciar Sesión")

            # Conectar a la base de datos
            conexion = conectar_mysql()
            if conexion is None:
                flash(
                    "Error de conexión a la base de datos. Intenta más tarde.", "error"
                )
                return render_template("login/login.html", title="Iniciar Sesión")

            cursor = conexion.cursor(dictionary=True)

            # Buscar usuario por email
            query = """
                SELECT id_usuario, email, password_hash, nombres, apellidos, 
                       documento_identidad, tipo_usuario, activo, ultimo_acceso
                FROM USUARIO 
                WHERE email = %s AND activo = TRUE
            """

            cursor.execute(query, (email,))
            usuario = cursor.fetchone()

            if not usuario:
                flash("Email o contraseña incorrectos", "error")
                cursor.close()
                conexion.close()
                print(f"DEBUG - Usuario no encontrado: {email}")
                return render_template("login/login.html", title="Iniciar Sesión")

            # Verificar contraseña
            if not check_password_hash(usuario["password_hash"], password):
                flash("Email o contraseña incorrectos", "error")
                cursor.close()
                conexion.close()
                print(f"DEBUG - Contraseña incorrecta para: {email}")
                return render_template("login/login.html", title="Iniciar Sesión")

            # Actualizar último acceso
            update_query = "UPDATE USUARIO SET ultimo_acceso = %s WHERE id_usuario = %s"
            cursor.execute(
                update_query, (datetime.datetime.now(), usuario["id_usuario"])
            )
            conexion.commit()

            cursor.close()
            conexion.close()

            # Crear sesión
            session["user_id"] = usuario["id_usuario"]
            session["user_email"] = usuario["email"]
            session["user_name"] = f"{usuario['nombres']} {usuario['apellidos']}"
            session["user_tipo"] = usuario["tipo_usuario"]
            session["user_nombres"] = usuario["nombres"]
            session["user_apellidos"] = usuario["apellidos"]

            # Configurar duración de sesión si "recordarme" está marcado
            if remember_me:
                session.permanent = True
                app.permanent_session_lifetime = datetime.timedelta(days=30)

            print(
                f"DEBUG - Login exitoso para {email}, tipo: {usuario['tipo_usuario']}"
            )

            # Redirigir según el tipo de usuario
            flash(f"¡Bienvenido, {usuario['nombres']}!", "success")
            return redirect(url_for("dashboard"))

        except Exception as e:
            print(f"DEBUG - Error en login: {str(e)}")
            flash("Error inesperado. Intenta más tarde.", "error")
            return render_template("login/login.html", title="Iniciar Sesión")

    # GET request - mostrar formulario
    return render_template("login/login.html", title="Iniciar Sesión")


@app.route("/dashboard")
@login_required
def dashboard():
    """Dashboard principal que redirige según el tipo de usuario"""
    user_tipo = session.get("user_tipo", "estudiante")

    # Redirigir según el tipo de usuario
    if user_tipo == "estudiante":
        return redirect(url_for("dashboard_estudiante"))
    elif user_tipo == "docente":
        return redirect(url_for("dashboard_docente"))
    elif user_tipo == "admin_institucional":
        return redirect(url_for("dashboard_admin_institucional"))
    elif user_tipo == "admin_general":
        return redirect(url_for("dashboard_admin_general"))
    else:
        # Tipo de usuario no reconocido
        flash("Tipo de usuario no válido", "error")
        return redirect(url_for("logout"))


@app.route("/dashboard/estudiante")
@login_required
@role_required(["estudiante"])
def dashboard_estudiante():
    user_name = session.get("user_name", "Estudiante")
    user_email = session.get("user_email", "")
    # Fecha actual para mostrarla en el dashboard
    today = datetime.datetime.now().strftime("%d de %B, %Y")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return render_template(
                "dashboards/estudiante.html",
                title="Dashboard Estudiante",
                user_name=user_name,
                user_email=user_email,
                today=today,
            )

        cursor = conexion.cursor(dictionary=True)

        # Obtener todos los cursos activos
        query = """
            SELECT id_curso, titulo, descripcion, duracion_estimada_horas, 
                   nivel_dificultad, categoria, imagen_portada, competencias_desarrolladas
            FROM CURSO
            WHERE activo = TRUE
            ORDER BY fecha_creacion DESC
            LIMIT 6
        """

        cursor.execute(query)
        cursos = cursor.fetchall()

        # Asignar progreso aleatorio a cada curso para simular cursos en progreso
        cursos_en_progreso = []
        for curso in cursos[:3]:  # Los primeros 3 cursos serán "en progreso"
            progreso = random.randint(30, 90)
            curso["progreso"] = progreso
            cursos_en_progreso.append(curso)

        # Los cursos restantes serán recomendados
        cursos_recomendados = cursos[3:] if len(cursos) > 3 else []

        # Generar calificaciones aleatorias para cursos recomendados
        for curso in cursos_recomendados:
            curso["rating"] = round(random.uniform(4.0, 5.0), 1)

        # Datos para el gráfico de competencias
        competencias = [
            "Programación",
            "Finanzas",
            "Habilidades Blandas",
            "Emprendimiento",
            "Competencias Digitales",
            "Diseño",
        ]

        niveles_competencia = [random.randint(20, 85) for _ in range(len(competencias))]

        # Cerrar conexión
        cursor.close()
        conexion.close()

        return render_template(
            "dashboards/estudiante.html",
            title="Dashboard Estudiante",
            user_name=user_name,
            user_email=user_email,
            today=today,
            cursos_en_progreso=cursos_en_progreso,
            cursos_recomendados=cursos_recomendados,
            competencias=competencias,
            niveles_competencia=niveles_competencia,
        )
    except Exception as e:
        flash(f"Error al cargar el dashboard: {str(e)}", "error")
        print(f"DEBUG - Error en dashboard_estudiante: {str(e)}")
        return render_template(
            "dashboards/estudiante.html",
            title="Dashboard Estudiante",
            user_name=user_name,
            user_email=user_email,
            today=today,
        )


@app.route("/dashboard/docente")
@login_required
@role_required(["docente"])
def dashboard_docente():
    user_name = session.get("user_name", "Docente")
    user_email = session.get("user_email", "")

    return render_template(
        "dashboards/docente.html",
        title="Dashboard Docente",
        user_name=user_name,
        user_email=user_email,
    )


@app.route("/dashboard/admin-institucional")
@login_required
@role_required(["admin_institucional"])
def dashboard_admin_institucional():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    return render_template(
        "dashboards/admin_institucional.html",
        title="Dashboard Admin Institucional",
        user_name=user_name,
        user_email=user_email,
    )


@app.route("/dashboard/admin-general")
@login_required
@role_required(["admin_general"])
def dashboard_admin_general():
    user_name = session.get("user_name", "Super Admin")
    user_email = session.get("user_email", "")

    return render_template(
        "admin_general/usuario/index.html",
        title="Dashboard Admin General",
        user_name=user_name,
        user_email=user_email,
    )


@app.route("/dashboard/estudiante/cursos")
@login_required
@role_required(["estudiante"])
def cursos_estudiante():
    user_name = session.get("user_name", "Estudiante")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return render_template(
                "dashboards/cursos_est.html",
                title="Mis Cursos",
                user_name=user_name,
                user_email=user_email,
                cursos=[],
                total_cursos=0,
                categorias=[],
            )

        cursor = conexion.cursor(dictionary=True)

        # Obtener todos los cursos activos
        query = """
            SELECT id_curso, titulo, descripcion, duracion_estimada_horas, 
                   nivel_dificultad, categoria, imagen_portada, competencias_desarrolladas
            FROM CURSO
            WHERE activo = TRUE
            ORDER BY fecha_creacion DESC
        """

        cursor.execute(query)
        cursos = cursor.fetchall()

        # Obtener lista única de categorías para el filtro
        categorias = set()
        for curso in cursos:
            categorias.add(
                curso["categoria"]
            )  # Asignar progreso aleatorio a cada curso para simular inscripción
        for curso in cursos:
            # Comprobamos si es el curso de contabilidad
            if (
                "contabilidad" in curso["titulo"].lower()
                or "contabilidad" in curso["descripcion"].lower()
                or "contabilidad" in curso["categoria"].lower()
            ):
                # Si es el curso de contabilidad, asignamos exactamente 49% de progreso
                curso["progreso"] = 49
            else:
                # Para los demás cursos, asignamos un progreso aleatorio
                progreso = random.choices(
                    [0, random.randint(1, 99), 100], weights=[0.2, 0.6, 0.2], k=1
                )[0]
                curso["progreso"] = progreso

        # Asegurarnos de que hay un curso de contabilidad con 49% de progreso
        curso_contabilidad_existe = any(
            "contabilidad" in curso["titulo"].lower()
            or "contabilidad" in curso["descripcion"].lower()
            or "contabilidad" in curso["categoria"].lower()
            for curso in cursos
        )

        if not curso_contabilidad_existe:
            # Si no existe, creamos un curso de contabilidad
            curso_contabilidad = {
                "id_curso": 999,  # ID arbitrario que no debería colisionar
                "titulo": "Fundamentos de Contabilidad Financiera",
                "descripcion": "Aprende los conceptos esenciales de la contabilidad financiera y su aplicación práctica en empresas.",
                "duracion_estimada_horas": 40,
                "nivel_dificultad": "Intermedio",
                "categoria": "Contabilidad",
                "imagen_portada": "accounting.jpg",
                "competencias_desarrolladas": "Análisis financiero, Principios contables, Estados financieros",
                "progreso": 49,
            }
            cursos.append(curso_contabilidad)

        # Filtrar cursos con progreso > 0 (es decir, inscritos)
        cursos_inscritos = [curso for curso in cursos if curso["progreso"] > 0]

        # Cerrar conexión
        cursor.close()
        conexion.close()

        return render_template(
            "dashboards/cursos_est.html",
            title="Mis Cursos",
            user_name=user_name,
            user_email=user_email,
            cursos=cursos_inscritos,
            total_cursos=len(cursos_inscritos),
            categorias=sorted(categorias),
        )
    except Exception as e:
        flash(f"Error al cargar los cursos: {str(e)}", "error")
        print(f"DEBUG - Error en cursos_estudiante: {str(e)}")
        return render_template(
            "dashboards/cursos_est.html",
            title="Mis Cursos",
            user_name=user_name,
            user_email=user_email,
            cursos=[],
            total_cursos=0,
            categorias=[],
        )


@app.route("/curso/<int:curso_id>")
@login_required
@role_required(["estudiante"])
def contenido_curso(curso_id):
    user_name = session.get("user_name", "Estudiante")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("dashboard_estudiante"))

        cursor = conexion.cursor(dictionary=True)

        # Obtener información del curso
        query = """
            SELECT id_curso, titulo, descripcion, duracion_estimada_horas, 
                   nivel_dificultad, categoria, imagen_portada, competencias_desarrolladas
            FROM CURSO
            WHERE id_curso = %s AND activo = TRUE
        """

        cursor.execute(query, (curso_id,))
        curso = cursor.fetchone()

        if not curso:
            flash("El curso solicitado no existe o no está disponible", "error")
            return redirect(url_for("cursos_estudiante"))  # Asignar progreso
        # Si es un curso de contabilidad, asegurarse de que tenga 49% de progreso
        if (
            "contabilidad" in curso["titulo"].lower()
            or "contabilidad" in curso["descripcion"].lower()
            or "contabilidad" in curso["categoria"].lower()
        ):
            curso["progreso"] = 49

        # Cerrar conexión
        cursor.close()
        conexion.close()

        return render_template(
            "cursos/cont_curso.html",
            title=curso["titulo"],
            user_name=user_name,
            user_email=user_email,
            curso=curso,
            # Valores por defecto para esta demo
            modulo_actual=2,  # Estamos en el módulo 3 (índice 2)
            leccion_actual=1,  # Estamos en la segunda lección (índice 1)
        )
    except Exception as e:
        flash(f"Error al cargar el contenido del curso: {str(e)}", "error")
        print(f"DEBUG - Error en contenido_curso: {str(e)}")
        return redirect(url_for("cursos_estudiante"))


@app.route("/logout")
def logout():
    user_name = session.get("user_name", "Usuario")
    session.clear()
    flash(f"¡Hasta pronto, {user_name}! Has cerrado sesión correctamente", "success")
    return redirect(url_for("index"))


# =============== RUTAS ADMINISTRATIVAS ===============


@app.route("/dashboard/admin-general/usuarios")
@login_required
@role_required(["admin_general"])
def usuario_index():

    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    return render_template(
        "admin_general/usuario/index.html",
        title="Gestión de Usuarios",
        user_name=user_name,
        user_email=user_email,
    )


@app.route("/dashboard/admin-general/usuarios/list")
@login_required
@role_required(["admin_general"])
def usuario_list():

    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            return jsonify({"error": "Error de conexión a la base de datos"}), 500

        cursor = conexion.cursor(dictionary=True)

        # Obtener todos los usuarios activos
        query = """
            SELECT id_usuario, email, nombres, apellidos, documento_identidad, 
                   tipo_usuario, fecha_registro, activo
            FROM USUARIO
            WHERE activo = TRUE
            ORDER BY fecha_registro DESC
        """

        cursor.execute(query)
        usuarios = cursor.fetchall()

        # Cerrar conexión
        cursor.close()
        conexion.close()

        # return jsonify(usuarios)
        return render_template(
            "admin_general/usuario/view.html",
            title="Lista de Usuarios",
            usuarios=usuarios,
            user_name=user_name,
            user_email=user_email,
        )

    except Exception as e:
        print(f"DEBUG - Error al obtener usuarios: {str(e)}")
        return jsonify({"error": "Error al obtener usuarios"}), 500


@app.route(
    "/dashboard/admin-general/usuarios/update/<int:user_id>", methods=["GET", "POST"]
)
@login_required
@role_required(["admin_general"])
def usuario_update(user_id):
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("usuario_list"))

        cursor = conexion.cursor(dictionary=True)

        if request.method == "POST":
            # Obtener datos del formulario
            nombres = request.form.get("nombres", "").strip()
            apellidos = request.form.get("apellidos", "").strip()
            email = request.form.get("email", "").strip().lower()
            documento_identidad = request.form.get("documento_identidad", "").strip()
            password = request.form.get("password", "")

            print(
                f"DEBUG - Actualizando usuario {user_id}: nombres={nombres}, email={email}"
            )

            # Validaciones
            errores = []

            # Validar nombres
            if len(nombres) < 2:
                errores.append("Los nombres deben tener al menos 2 caracteres")
            elif not re.match(r"^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s]+$", nombres):
                errores.append("Los nombres solo pueden contener letras y espacios")

            # Validar apellidos
            if len(apellidos) < 2:
                errores.append("Los apellidos deben tener al menos 2 caracteres")
            elif not re.match(r"^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s]+$", apellidos):
                errores.append("Los apellidos solo pueden contener letras y espacios")

            # Validar email
            if not validar_email(email):
                errores.append("El formato del email no es válido")

            # Validar documento
            es_valido_doc, mensaje_doc = validar_documento(documento_identidad)
            if not es_valido_doc:
                errores.append(mensaje_doc)

            # Validar contraseña si se proporciona
            if password:
                es_valida, mensaje_password = validar_password(password)
                if not es_valida:
                    errores.append(mensaje_password)

            # Verificar duplicados (excluyendo el usuario actual)
            cursor.execute(
                "SELECT id_usuario FROM USUARIO WHERE email = %s AND id_usuario != %s",
                (email, user_id),
            )
            if cursor.fetchone():
                errores.append("Este email ya está registrado por otro usuario")

            cursor.execute(
                "SELECT id_usuario FROM USUARIO WHERE documento_identidad = %s AND id_usuario != %s",
                (documento_identidad, user_id),
            )
            if cursor.fetchone():
                errores.append("Este documento ya está registrado por otro usuario")

            if errores:
                for error in errores:
                    flash(error, "error")

                # Obtener datos del usuario para mostrar en el formulario
                cursor.execute(
                    "SELECT * FROM USUARIO WHERE id_usuario = %s", (user_id,)
                )
                usuario = cursor.fetchone()
                cursor.close()
                conexion.close()

                return render_template(
                    "admin_general/usuario/update.html",
                    title="Actualizar Usuario",
                    usuario=usuario,
                    user_name=user_name,
                    user_email=user_email,
                )

            # Preparar query de actualización
            if password:
                # Si se proporciona nueva contraseña
                password_hash = generate_password_hash(password, method="pbkdf2:sha256")
                query = """
                    UPDATE USUARIO 
                    SET email = %s, password_hash = %s, nombres = %s, apellidos = %s, 
                        documento_identidad = %s
                    WHERE id_usuario = %s
                """
                valores = (
                    email,
                    password_hash,
                    nombres,
                    apellidos,
                    documento_identidad,
                    user_id,
                )
            else:
                # Sin cambio de contraseña
                query = """
                    UPDATE USUARIO 
                    SET email = %s, nombres = %s, apellidos = %s, 
                        documento_identidad = %s
                    WHERE id_usuario = %s
                """
                valores = (
                    email,
                    nombres,
                    apellidos,
                    documento_identidad,
                    user_id,
                )

            cursor.execute(query, valores)
            conexion.commit()

            cursor.close()
            conexion.close()

            flash("Usuario actualizado exitosamente", "success")
            return redirect(url_for("usuario_list"))

        else:
            # GET request - mostrar formulario con datos actuales
            cursor.execute("SELECT * FROM USUARIO WHERE id_usuario = %s", (user_id,))
            usuario = cursor.fetchone()

            if not usuario:
                flash("Usuario no encontrado", "error")
                cursor.close()
                conexion.close()
                return redirect(url_for("usuario_list"))

            cursor.close()
            conexion.close()

            return render_template(
                "admin_general/usuario/update.html",
                title="Actualizar Usuario",
                usuario=usuario,
                user_name=user_name,
                user_email=user_email,
            )

    except Exception as e:
        print(f"DEBUG - Error al actualizar usuario: {str(e)}")
        flash(f"Error al actualizar usuario: {str(e)}", "error")
        return redirect(url_for("usuario_list"))


@app.route("/dashboard/admin-general/usuarios/create", methods=["GET", "POST"])
@login_required
@role_required(["admin_general"])
def usuario_create():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    if request.method == "POST":
        try:
            # Obtener datos del formulario
            nombres = request.form.get("nombres", "").strip()
            apellidos = request.form.get("apellidos", "").strip()
            email = request.form.get("email", "").strip().lower()
            documento_identidad = request.form.get("documento_identidad", "").strip()
            password = request.form.get("password", "")
            confirm_password = request.form.get("confirm_password", "")
            tipo_usuario = request.form.get("tipo_usuario", "estudiante")

            telefono = request.form.get("telefono", "").strip() or None
            fecha_nacimiento = request.form.get("fecha_nacimiento", "") or None

            print(
                f"DEBUG - Creando usuario: nombres={nombres}, email={email}, tipo={tipo_usuario}"
            )

            # Validaciones
            errores = []

            # Validar nombres
            if len(nombres) < 2:
                errores.append("Los nombres deben tener al menos 2 caracteres")
            elif not re.match(r"^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s]+$", nombres):
                errores.append("Los nombres solo pueden contener letras y espacios")

            # Validar apellidos
            if len(apellidos) < 2:
                errores.append("Los apellidos deben tener al menos 2 caracteres")
            elif not re.match(r"^[a-zA-ZáéíóúÁÉÍÓÚñÑ\s]+$", apellidos):
                errores.append("Los apellidos solo pueden contener letras y espacios")

            # Validar email
            if not validar_email(email):
                errores.append("El formato del email no es válido")

            # Validar documento
            es_valido_doc, mensaje_doc = validar_documento(documento_identidad)
            if not es_valido_doc:
                errores.append(mensaje_doc)

            # Validar contraseña
            es_valida_pw, mensaje_pw = validar_password(password)
            if not es_valida_pw:
                errores.append(mensaje_pw)

            # Validar confirmación de contraseña
            if password != confirm_password:
                errores.append("Las contraseñas no coinciden")

            # Validar tipo de usuario
            if not tipo_usuario or tipo_usuario not in [
                "estudiante",
                "docente",
                "admin_institucional",
                "admin_general",
            ]:
                errores.append("Debes seleccionar un tipo de usuario válido")

            if fecha_nacimiento:
                try:
                    fecha_nacimiento_dt = datetime.datetime.strptime(
                        fecha_nacimiento, "%Y-%m-%d"
                    ).date()
                    # Verificar que la fecha no sea futura
                    if fecha_nacimiento_dt > datetime.date.today():
                        errores.append("La fecha de nacimiento no puede ser futura")
                except ValueError:
                    errores.append("Formato de fecha de nacimiento inválido")

            # Conectar a la base de datos para verificar duplicados
            conexion = conectar_mysql()
            if conexion is None:
                flash(
                    "Error de conexión a la base de datos. Intenta más tarde.", "error"
                )
                return render_template(
                    "admin_general/usuario/create.html",
                    title="Crear Usuario",
                    user_name=user_name,
                    user_email=user_email,
                )

            cursor = conexion.cursor(dictionary=True)

            # Verificar si el email ya existe
            cursor.execute("SELECT id_usuario FROM USUARIO WHERE email = %s", (email,))
            if cursor.fetchone():
                errores.append("Este email ya está registrado. Usa otro email.")

            # Verificar si el documento ya existe
            cursor.execute(
                "SELECT id_usuario FROM USUARIO WHERE documento_identidad = %s",
                (documento_identidad,),
            )
            if cursor.fetchone():
                errores.append("Este documento ya está registrado. Verifica los datos.")

            if errores:
                for error in errores:
                    flash(error, "error")
                cursor.close()
                conexion.close()
                return render_template(
                    "admin_general/usuario/create.html",
                    title="Crear Usuario",
                    user_name=user_name,
                    user_email=user_email,
                )

            # Crear hash de la contraseña
            password_hash = generate_password_hash(password, method="pbkdf2:sha256")

            # Insertar nuevo usuario
            query = """
                INSERT INTO USUARIO (email, password_hash, nombres, apellidos, documento_identidad, tipo_usuario, fecha_registro, telefono, fecha_nacimiento, activo)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, TRUE)
            """

            fecha_actual = datetime.datetime.now()
            valores = (
                email,
                password_hash,
                nombres,
                apellidos,
                documento_identidad,
                tipo_usuario,
                fecha_actual,
                telefono,
                fecha_nacimiento if fecha_nacimiento else None,
            )

            cursor.execute(query, valores)
            conexion.commit()

            # Obtener el ID del usuario recién creado
            
            

            cursor.close()
            conexion.close()

            flash(f"Usuario {nombres} {apellidos} creado exitosamente", "success")
            return redirect(url_for("usuario_list"))

        except Exception as e:
            print(f"DEBUG - Error en creación de usuario: {str(e)}")
            flash(f"Error al crear usuario: {str(e)}", "error")
            return render_template(
                "admin_general/usuario/create.html",
                title="Crear Usuario",
                user_name=user_name,
                user_email=user_email,
            )

    # GET request - mostrar formulario
    return render_template(
        "admin_general/usuario/create.html",
        title="Crear Usuario",
        user_name=user_name,
        user_email=user_email,
    )


@app.route(
    "/dashboard/admin-general/usuarios/delete/<int:user_id>", methods=["GET", "POST"]
)
@login_required
@role_required(["admin_general"])
def usuario_delete(user_id):
    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("usuario_list"))

        cursor = conexion.cursor(dictionary=True)

        # Verificar que el usuario existe
        cursor.execute(
            "SELECT nombres, apellidos FROM USUARIO WHERE id_usuario = %s", (user_id,)
        )
        usuario = cursor.fetchone()

        if not usuario:
            flash("El usuario que intenta eliminar no existe", "error")
            return redirect(url_for("usuario_list"))

        # Marcar el usuario como inactivo en lugar de eliminarlo físicamente
        cursor.execute(
            "UPDATE USUARIO SET activo = FALSE WHERE id_usuario = %s", (user_id,)
        )
        conexion.commit()

        nombre_completo = f"{usuario['nombres']} {usuario['apellidos']}"
        flash(f"Usuario {nombre_completo} eliminado correctamente", "success")

        cursor.close()
        conexion.close()
        return redirect(url_for("usuario_list"))

    except Exception as e:
        print(f"DEBUG - Error al eliminar usuario: {str(e)}")
        flash(f"Error al eliminar usuario: {str(e)}", "error")
        return redirect(url_for("usuario_list"))


# =================== RUTAS CRUD PARA INSTITUCIONES ===================


@app.route("/dashboard/admin-general/instituciones")
@login_required
@role_required(["admin_general"])
def institucion_index():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    return render_template(
        "admin_general/institucion/index.html",
        title="Gestión de Instituciones",
        user_name=user_name,
        user_email=user_email,
    )


@app.route("/dashboard/admin-general/instituciones/list")
@login_required
@role_required(["admin_general"])
def institucion_list():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            return jsonify({"error": "Error de conexión a la base de datos"}), 500

        cursor = conexion.cursor(
            dictionary=True
        )  # Obtener todas las instituciones activas
        query = """
            SELECT id_institucion, nombre_institucion, nit, direccion, 
                   telefono, email_institucional, ciudad, departamento, 
                   fecha_registro, activo
            FROM INSTITUCION
            WHERE activo = TRUE
            ORDER BY fecha_registro DESC
        """

        cursor.execute(query)
        instituciones = cursor.fetchall()

        # Cerrar conexión
        cursor.close()
        conexion.close()

        return render_template(
            "admin_general/institucion/view.html",
            title="Lista de Instituciones",
            instituciones=instituciones,
            user_name=user_name,
            user_email=user_email,
        )

    except Exception as e:
        print(f"DEBUG - Error al obtener instituciones: {str(e)}")
        flash(f"Error al obtener instituciones: {str(e)}", "error")
        return render_template(
            "admin_general/institucion/view.html",
            title="Lista de Instituciones",
            instituciones=[],
            user_name=user_name,
            user_email=user_email,
        )


@app.route("/dashboard/admin-general/instituciones/create", methods=["GET", "POST"])
@login_required
@role_required(["admin_general"])
def institucion_create():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    if request.method == "POST":
        # Obtener datos del formulario
        nombre_institucion = request.form.get("nombre_institucion", "").strip()
        nit = request.form.get("nit", "").strip()
        direccion = request.form.get("direccion", "").strip()
        telefono = request.form.get("telefono", "").strip()
        email_institucional = request.form.get("email_institucional", "").strip()
        ciudad = request.form.get("ciudad", "").strip()
        departamento = request.form.get("departamento", "").strip()

        # Validaciones
        errores = []

        if len(nombre_institucion) < 3:
            errores.append(
                "El nombre de la institución debe tener al menos 3 caracteres"
            )

        if len(nit) < 9:
            errores.append("El NIT debe tener al menos 9 caracteres")

        if not departamento:
            errores.append("El departamento es requerido")

        if not ciudad:
            errores.append("La ciudad es requerida")

        if len(direccion) < 5:
            errores.append("La dirección debe tener al menos 5 caracteres")

        if email_institucional and not re.match(
            r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email_institucional
        ):
            errores.append("El formato del email no es válido")

        if telefono and not re.match(r"^[\d\s\+\-\(\)]+$", telefono):
            errores.append("El formato del teléfono no es válido")

        try:
            # Conectar a la base de datos
            conexion = conectar_mysql()
            if conexion is None:
                errores.append("Error de conexión a la base de datos")

            if not errores and conexion:
                cursor = conexion.cursor(
                    dictionary=True
                )  # Verificar si ya existe una institución con el mismo NIT
                cursor.execute(
                    "SELECT id_institucion FROM INSTITUCION WHERE nit = %s",
                    (nit,),
                )
                if cursor.fetchone():
                    errores.append("Ya existe una institución con este NIT")

                # Verificar si ya existe una institución con el mismo nombre
                cursor.execute(
                    "SELECT id_institucion FROM INSTITUCION WHERE nombre_institucion = %s",
                    (nombre_institucion,),
                )
                if cursor.fetchone():
                    errores.append("Ya existe una institución con este nombre")

                if errores:
                    for error in errores:
                        flash(error, "error")
                    cursor.close()
                    conexion.close()
                    return render_template(
                        "admin_general/institucion/create.html",
                        title="Crear Institución",
                        user_name=user_name,
                        user_email=user_email,
                    )  # Insertar nueva institución
                query = """
                    INSERT INTO INSTITUCION (nombre_institucion, nit, direccion, 
                                           telefono, email_institucional, ciudad, 
                                           departamento, fecha_registro, activo)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, TRUE)
                """

                fecha_actual = datetime.datetime.now()
                valores = (
                    nombre_institucion,
                    nit,
                    direccion,
                    telefono if telefono else None,
                    email_institucional if email_institucional else None,
                    ciudad,
                    departamento,
                    fecha_actual,
                )

                cursor.execute(query, valores)
                conexion.commit()

                # Obtener el ID de la institución recién creada
                institucion_id = cursor.lastrowid

                cursor.close()
                conexion.close()

                flash(
                    f"Institución {nombre_institucion} creada exitosamente", "success"
                )
                return redirect(url_for("institucion_list"))

        except Exception as e:
            print(f"DEBUG - Error en creación de institución: {str(e)}")
            flash(f"Error al crear la institución: {str(e)}", "error")

        if errores:
            for error in errores:
                flash(error, "error")

    return render_template(
        "admin_general/institucion/create.html",
        title="Crear Institución",
        user_name=user_name,
        user_email=user_email,
    )


@app.route(
    "/dashboard/admin-general/instituciones/update/<int:institucion_id>",
    methods=["GET", "POST"],
)
@login_required
@role_required(["admin_general"])
def institucion_update(institucion_id):
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("institucion_list"))

        cursor = conexion.cursor(dictionary=True)  # Obtener datos de la institución
        query = """
            SELECT id_institucion, nombre_institucion, nit, direccion, 
                   telefono, email_institucional, ciudad, departamento, 
                   fecha_registro
            FROM INSTITUCION
            WHERE id_institucion = %s AND activo = TRUE
        """

        cursor.execute(query, (institucion_id,))
        institucion = cursor.fetchone()

        if not institucion:
            flash("La institución solicitada no existe", "error")
            cursor.close()
            conexion.close()
            return redirect(url_for("institucion_list"))
        if request.method == "POST":
            # Obtener datos del formulario
            nombre_institucion = request.form.get("nombre_institucion", "").strip()
            nit = request.form.get("nit", "").strip()
            direccion = request.form.get("direccion", "").strip()
            telefono = request.form.get("telefono", "").strip()
            email_institucional = request.form.get("email_institucional", "").strip()
            ciudad = request.form.get("ciudad", "").strip()
            departamento = request.form.get("departamento", "").strip()

            # Validaciones
            errores = []

            if len(nombre_institucion) < 3:
                errores.append(
                    "El nombre de la institución debe tener al menos 3 caracteres"
                )

            if len(nit) < 9:
                errores.append("El NIT debe tener al menos 9 caracteres")

            if not departamento:
                errores.append("El departamento es requerido")

            if not ciudad:
                errores.append("La ciudad es requerida")

            if len(direccion) < 5:
                errores.append("La dirección debe tener al menos 5 caracteres")

            if email_institucional and not re.match(
                r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email_institucional
            ):
                errores.append("El formato del email no es válido")

            if telefono and not re.match(r"^[\d\s\+\-\(\)]+$", telefono):
                errores.append("El formato del teléfono no es válido")

            # Verificar duplicados (excluyendo la institución actual)
            cursor.execute(
                "SELECT id_institucion FROM INSTITUCION WHERE nit = %s AND id_institucion != %s",
                (nit, institucion_id),
            )
            if cursor.fetchone():
                errores.append("Ya existe otra institución con este NIT")

            cursor.execute(
                "SELECT id_institucion FROM INSTITUCION WHERE nombre_institucion = %s AND id_institucion != %s",
                (nombre_institucion, institucion_id),
            )
            if cursor.fetchone():
                errores.append("Ya existe otra institución con este nombre")

            if errores:
                for error in errores:
                    flash(error, "error")
                return render_template(
                    "admin_general/institucion/update.html",
                    title="Actualizar Institución",
                    institucion=institucion,
                    user_name=user_name,
                    user_email=user_email,
                )

            # Actualizar institución
            query = """
                UPDATE INSTITUCION 
                SET nombre_institucion = %s, nit = %s, direccion = %s, 
                    telefono = %s, email_institucional = %s, ciudad = %s, 
                    departamento = %s
                WHERE id_institucion = %s
            """

            valores = (
                nombre_institucion,
                nit,
                direccion,
                telefono if telefono else None,
                email_institucional if email_institucional else None,
                ciudad,
                departamento,
                institucion_id,
            )
            cursor.execute(query, valores)
            conexion.commit()

            cursor.close()
            conexion.close()

            flash(
                f"Institución {nombre_institucion} actualizada exitosamente", "success"
            )
            return redirect(url_for("institucion_list"))

        cursor.close()
        conexion.close()

        return render_template(
            "admin_general/institucion/update.html",
            title="Actualizar Institución",
            institucion=institucion,
            user_name=user_name,
            user_email=user_email,
        )

    except Exception as e:
        print(f"DEBUG - Error al actualizar institución: {str(e)}")
        flash(f"Error al actualizar la institución: {str(e)}", "error")
        return redirect(url_for("institucion_list"))


@app.route("/dashboard/admin-general/instituciones/delete/<int:institucion_id>")
@login_required
@role_required(["admin_general"])
def institucion_delete(institucion_id):
    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("institucion_list"))

        cursor = conexion.cursor(
            dictionary=True
        )  # Obtener información de la institución antes de eliminarla
        cursor.execute(
            "SELECT nombre_institucion FROM INSTITUCION WHERE id_institucion = %s AND activo = TRUE",
            (institucion_id,),
        )
        institucion = cursor.fetchone()

        if not institucion:
            flash("La institución no existe o ya ha sido eliminada", "error")
            cursor.close()
            conexion.close()
            return redirect(url_for("institucion_list"))

        # Marcar como inactiva (eliminación suave)
        cursor.execute(
            "UPDATE INSTITUCION SET activo = FALSE WHERE id_institucion = %s",
            (institucion_id,),
        )
        conexion.commit()

        flash(
            f"Institución {institucion['nombre_institucion']} eliminada correctamente",
            "success",
        )

        cursor.close()
        conexion.close()
        return redirect(url_for("institucion_list"))

    except Exception as e:
        print(f"DEBUG - Error al eliminar institución: {str(e)}")
        flash(f"Error al eliminar institución: {str(e)}", "error")
        return redirect(url_for("institucion_list"))


# ========================================
# RUTAS PARA CRUD DE CURSOS
# ========================================


@app.route("/dashboard/admin-general/cursos")
@login_required
@role_required(["admin_general"])
def curso_index():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    return render_template(
        "admin_general/curso/index.html",
        title="Gestión de Cursos",
        user_name=user_name,
        user_email=user_email,
    )


@app.route("/dashboard/admin-general/cursos/list")
@login_required
@role_required(["admin_general"])
def curso_list():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return render_template(
                "admin_general/curso/view.html",
                title="Lista de Cursos",
                user_name=user_name,
                user_email=user_email,
                cursos=[],
            )

        cursor = conexion.cursor(dictionary=True)

        # Obtener todos los cursos
        query = """
            SELECT id_curso, titulo, descripcion, duracion_estimada_horas, 
                   nivel_dificultad, categoria, imagen_portada, competencias_desarrolladas,
                   fecha_creacion, activo
            FROM CURSO
            ORDER BY fecha_creacion DESC
        """

        cursor.execute(query)
        cursos = cursor.fetchall()

        cursor.close()
        conexion.close()

        return render_template(
            "admin_general/curso/view.html",
            title="Lista de Cursos",
            user_name=user_name,
            user_email=user_email,
            cursos=cursos,
        )

    except Exception as e:
        print(f"DEBUG - Error al obtener cursos: {str(e)}")
        flash(f"Error al obtener la lista de cursos: {str(e)}", "error")
        return render_template(
            "admin_general/curso/view.html",
            title="Lista de Cursos",
            user_name=user_name,
            user_email=user_email,
            cursos=[],
        )


@app.route("/dashboard/admin-general/cursos/create", methods=["GET", "POST"])
@login_required
@role_required(["admin_general"])
def curso_create():
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    if request.method == "POST":
        try:
            # Obtener datos del formulario
            titulo = request.form.get("titulo", "").strip()
            descripcion = request.form.get("descripcion", "").strip()
            duracion_estimada_horas = request.form.get(
                "duracion_estimada_horas", ""
            ).strip()
            nivel_dificultad = request.form.get("nivel_dificultad", "").strip()
            categoria = request.form.get("categoria", "").strip()
            competencias_desarrolladas = request.form.get(
                "competencias_desarrolladas", ""
            ).strip()
            imagen_portada = request.form.get("imagen_portada", "").strip() or None

            print(f"DEBUG - Creando curso: titulo={titulo}, categoria={categoria}")

            # Validaciones
            errores = []

            # Validar título
            if len(titulo) < 3:
                errores.append("El título debe tener al menos 3 caracteres")

            # Validar descripción
            if len(descripcion) < 10:
                errores.append("La descripción debe tener al menos 10 caracteres")

            # Validar duración
            try:
                duracion_float = float(duracion_estimada_horas)
                if duracion_float <= 0:
                    errores.append("La duración debe ser mayor a 0")
            except ValueError:
                errores.append("La duración debe ser un número válido")

            # Validar nivel de dificultad
            niveles_validos = ["Básico", "Intermedio", "Avanzado"]
            if nivel_dificultad not in niveles_validos:
                errores.append("Selecciona un nivel de dificultad válido")

            # Validar categoría
            if len(categoria) < 2:
                errores.append("La categoría es requerida")

            # Validar competencias desarrolladas
            if len(competencias_desarrolladas) < 10:
                errores.append(
                    "Las competencias desarrolladas deben tener al menos 10 caracteres"
                )

            if errores:
                for error in errores:
                    flash(error, "error")
                return render_template(
                    "admin_general/curso/create.html",
                    title="Crear Curso",
                    user_name=user_name,
                    user_email=user_email,
                )

            # Conectar a la base de datos
            conexion = conectar_mysql()
            if conexion is None:
                flash(
                    "Error de conexión a la base de datos. Intenta más tarde.", "error"
                )
                return render_template(
                    "admin_general/curso/create.html",
                    title="Crear Curso",
                    user_name=user_name,
                    user_email=user_email,
                )

            cursor = conexion.cursor()

            # Verificar si el título ya existe
            cursor.execute("SELECT id_curso FROM CURSO WHERE titulo = %s", (titulo,))
            if cursor.fetchone():
                flash(
                    "Ya existe un curso con este título. Usa un título diferente.",
                    "error",
                )
                cursor.close()
                conexion.close()
                return render_template(
                    "admin_general/curso/create.html",
                    title="Crear Curso",
                    user_name=user_name,
                    user_email=user_email,
                )

            # Insertar nuevo curso
            query = """
                INSERT INTO CURSO (titulo, descripcion, duracion_estimada_horas, 
                                 nivel_dificultad, categoria, imagen_portada, 
                                 competencias_desarrolladas, fecha_creacion, activo)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, TRUE)
            """

            fecha_actual = datetime.datetime.now()
            valores = (
                titulo,
                descripcion,
                duracion_float,
                nivel_dificultad,
                categoria,
                imagen_portada,
                competencias_desarrolladas,
                fecha_actual,
            )

            cursor.execute(query, valores)
            conexion.commit()

            # Obtener el ID del curso recién creado
            curso_id = cursor.lastrowid

            cursor.close()
            conexion.close()

            flash(f"Curso '{titulo}' creado exitosamente", "success")
            return redirect(url_for("curso_list"))

        except Exception as e:
            print(f"DEBUG - Error en creación de curso: {str(e)}")
            flash(f"Error al crear curso: {str(e)}", "error")
            return render_template(
                "admin_general/curso/create.html",
                title="Crear Curso",
                user_name=user_name,
                user_email=user_email,
            )

    # GET request - mostrar formulario
    return render_template(
        "admin_general/curso/create.html",
        title="Crear Curso",
        user_name=user_name,
        user_email=user_email,
    )


@app.route(
    "/dashboard/admin-general/cursos/update/<int:curso_id>", methods=["GET", "POST"]
)
@login_required
@role_required(["admin_general"])
def curso_update(curso_id):
    user_name = session.get("user_name", "Administrador")
    user_email = session.get("user_email", "")

    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("curso_list"))

        cursor = conexion.cursor(dictionary=True)

        # Obtener datos del curso
        cursor.execute(
            """SELECT id_curso, titulo, descripcion, duracion_estimada_horas, 
               nivel_dificultad, categoria, imagen_portada, competencias_desarrolladas,
               fecha_creacion, activo
               FROM CURSO WHERE id_curso = %s""",
            (curso_id,),
        )
        curso = cursor.fetchone()

        if not curso:
            flash("Curso no encontrado", "error")
            cursor.close()
            conexion.close()
            return redirect(url_for("curso_list"))

        if request.method == "POST":
            # Obtener datos del formulario
            titulo = request.form.get("titulo", "").strip()
            descripcion = request.form.get("descripcion", "").strip()
            duracion_estimada_horas = request.form.get(
                "duracion_estimada_horas", ""
            ).strip()
            nivel_dificultad = request.form.get("nivel_dificultad", "").strip()
            categoria = request.form.get("categoria", "").strip()
            competencias_desarrolladas = request.form.get(
                "competencias_desarrolladas", ""
            ).strip()
            imagen_portada = request.form.get("imagen_portada", "").strip() or None

            print(f"DEBUG - Actualizando curso {curso_id}: titulo={titulo}")

            # Validaciones
            errores = []

            # Validar título
            if len(titulo) < 3:
                errores.append("El título debe tener al menos 3 caracteres")

            # Validar descripción
            if len(descripcion) < 10:
                errores.append("La descripción debe tener al menos 10 caracteres")

            # Validar duración
            try:
                duracion_float = float(duracion_estimada_horas)
                if duracion_float <= 0:
                    errores.append("La duración debe ser mayor a 0")
            except ValueError:
                errores.append("La duración debe ser un número válido")

            # Validar nivel de dificultad
            niveles_validos = ["Básico", "Intermedio", "Avanzado"]
            if nivel_dificultad not in niveles_validos:
                errores.append("Selecciona un nivel de dificultad válido")

            # Validar categoría
            if len(categoria) < 2:
                errores.append("La categoría es requerida")

            # Validar competencias desarrolladas
            if len(competencias_desarrolladas) < 10:
                errores.append(
                    "Las competencias desarrolladas deben tener al menos 10 caracteres"
                )

            # Verificar si el título ya existe en otro curso
            cursor.execute(
                "SELECT id_curso FROM CURSO WHERE titulo = %s AND id_curso != %s",
                (titulo, curso_id),
            )
            if cursor.fetchone():
                errores.append("Ya existe otro curso con este título")

            if errores:
                for error in errores:
                    flash(error, "error")
                cursor.close()
                conexion.close()
                return render_template(
                    "admin_general/curso/update.html",
                    title="Actualizar Curso",
                    user_name=user_name,
                    user_email=user_email,
                    curso=curso,
                )

            # Actualizar curso
            query = """
                UPDATE CURSO SET titulo = %s, descripcion = %s, duracion_estimada_horas = %s,
                               nivel_dificultad = %s, categoria = %s, imagen_portada = %s,
                               competencias_desarrolladas = %s
                WHERE id_curso = %s
            """

            valores = (
                titulo,
                descripcion,
                duracion_float,
                nivel_dificultad,
                categoria,
                imagen_portada,
                competencias_desarrolladas,
                curso_id,
            )

            cursor.execute(query, valores)
            conexion.commit()

            cursor.close()
            conexion.close()

            flash(f"Curso '{titulo}' actualizado exitosamente", "success")
            return redirect(url_for("curso_list"))

        # GET request - mostrar formulario con datos del curso
        cursor.close()
        conexion.close()

        return render_template(
            "admin_general/curso/update.html",
            title="Actualizar Curso",
            user_name=user_name,
            user_email=user_email,
            curso=curso,
        )

    except Exception as e:
        print(f"DEBUG - Error al actualizar curso: {str(e)}")
        flash(f"Error al actualizar curso: {str(e)}", "error")
        return redirect(url_for("curso_list"))


@app.route("/dashboard/admin-general/cursos/delete/<int:curso_id>")
@login_required
@role_required(["admin_general"])
def curso_delete(curso_id):
    try:
        # Conectar a la base de datos
        conexion = conectar_mysql()
        if conexion is None:
            flash("Error de conexión a la base de datos", "error")
            return redirect(url_for("curso_list"))

        cursor = conexion.cursor(dictionary=True)

        # Verificar que el curso existe
        cursor.execute("SELECT titulo FROM CURSO WHERE id_curso = %s", (curso_id,))
        curso = cursor.fetchone()

        if not curso:
            flash("Curso no encontrado", "error")
            cursor.close()
            conexion.close()
            return redirect(url_for("curso_list"))

        # Eliminar curso (cambiar activo a FALSE en lugar de DELETE físico)
        cursor.execute(
            "UPDATE CURSO SET activo = FALSE WHERE id_curso = %s", (curso_id,)
        )
        conexion.commit()

        flash(f"Curso '{curso['titulo']}' eliminado exitosamente", "success")

        cursor.close()
        conexion.close()
        return redirect(url_for("curso_list"))

    except Exception as e:
        print(f"DEBUG - Error al eliminar curso: {str(e)}")
        flash(f"Error al eliminar curso: {str(e)}", "error")
        return redirect(url_for("curso_list"))

    data = request.get_json()
    user_message = data.get("message", "").strip()

    if not user_message:
        return jsonify({"response": "Mensaje vacío."}), 400

    # Agregar mensaje del usuario al historial
    chat_history.append({"role": "user", "content": user_message})

    headers = {
        "Authorization": "Bearer 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",
        "Content-Type": "application/json",
        "HTTP-Referer": "http://127.0.0.1:5000/",
        "X-Title": "NexoEDU-Chat",
    }

    payload = {
        "model": "deepseek/deepseek",  # Modelo gratuito
        "messages": chat_history
    }

    try:
        response = requests.post(
            "https://openrouter.ai/api/v1/chat/completions",
            headers=headers,
            json=payload,
        )
        response.raise_for_status()
        reply = response.json()["choices"][0]["message"]["content"]
        chat_history.append({"role": "assistant", "content": reply})
        return jsonify({"response": reply})
    except requests.exceptions.RequestException as e:
        print("Error:", e)
        return jsonify({"response": "Error al procesar tu solicitud."}), 500

# ========================================
# Componente de IA
# ========================================

API_KEY = os.getenv("API_KEY")
if not API_KEY:
    print("Error: La variable de entorno GEMINI_API_KEY no está configurada.")
    exit(1)

genai.configure(api_key=API_KEY)
model = genai.GenerativeModel("gemini-1.5-flash")

NEXOEDU_SYSTEM_INSTRUCTIONS = """
Te llamaras Nexo con su diminutivo Nexito

Eres un asistente de chatbot amable, servicial y experto para la plataforma NexoEDU. Tu objetivo es ayudar a los estudiantes de bachillerato a navegar por la plataforma, responder preguntas sobre los cursos, aclarar cualquier duda que tengan sobre cómo funciona NexoEDU y guiarlos paso a paso en las funcionalidades principales.

Aquí tienes información clave y una guía detallada sobre NexoEDU:

**1. Sobre NexoEDU:**
- **Nombre de la plataforma:** NexoEDU
- **Audiencia:** Estudiantes de bachillerato.
- **Propósito:** Plataforma complementaria para el aprendizaje, ofreciendo cursos especializados.
- **Cursos ofrecidos (ejemplos):**
    - Finanzas personales para jóvenes
    - Introducción a la Programación (Python, HTML/CSS)
    - Habilidades Blandas (comunicación, liderazgo, resolución de problemas)
    - Preparación para exámenes universitarios
    - Gestión del tiempo y técnicas de estudio
- **Características principales:**
    - Contenido interactivo y fácil de entender.
    - Ejercicios prácticos.
    - Acceso 24/7 desde cualquier dispositivo.
    - Seguimiento de progreso personalizado.

**2. Guía de Uso de NexoEDU:**

**Acceso al Sistema:**
- **Iniciar sesión:**
    1. Ingresa a la página principal de NexoEDU.
    2. Haz clic en el botón "Iniciar Sesión".
    3. Introduce tu correo electrónico y contraseña en los campos correspondientes.
    4. (Opcional) Marca "Recordarme" si deseas mantener la sesión activa por 30 días para un acceso más rápido.

**Dashboard Principal:**
- **Navegación por el dashboard:**
    - En la pantalla principal después de iniciar sesión, encontrarás:
        - Tus **cursos en progreso** (se muestran hasta 3 de tus cursos más recientes).
        - **Cursos recomendados** basados en tu perfil e intereses.
        - Un **gráfico de tus competencias y habilidades** que muestra tu desarrollo.
    - Utiliza el **menú lateral** para acceder a todas las secciones y funcionalidades de la plataforma.

**Explorar tus Cursos:**
- **Acceder a "Mis Cursos":**
    1. Haz clic en "Mis Cursos" en el menú lateral.
    2. Verás una lista completa de todos tus cursos inscritos, incluyendo su porcentaje de progreso individual.
    3. Puedes utilizar las opciones de **filtrado por categorías** para encontrar cursos específicos más rápidamente.

**Dentro de los Cursos:**
- **Acceder al contenido del curso:**
    1. Haz clic en el título o la tarjeta de cualquier curso para acceder a su contenido completo.
    2. Navega entre los **módulos y lecciones** utilizando los controles de navegación intuitivos proporcionados.
    3. El sistema **guardará automáticamente tu progreso** en cada lección, permitiéndote retomar donde lo dejaste.
- **Recursos de aprendizaje:**
    - Cada curso está diseñado con diferentes tipos de **recursos educativos** (videos, lecturas, cuestionarios, ejercicios).
    - El **progreso** del curso se actualiza automáticamente conforme completes las lecciones y actividades.

**Asistente Virtual (¡Soy yo!):**
- **Utilizar el chat con IA:**
    - Encuentra el botón de chat en la esquina inferior derecha de la interfaz (una burbuja con un icono de chat).
    - Puedes hacer preguntas sobre:
        - Contenidos específicos de los cursos.
        - Dudas académicas generales relacionadas con los temas de NexoEDU.
        - Recomendaciones de estudio o sobre qué curso tomar.
    - El asistente conservará el historial de tu conversación **durante la sesión actual**, permitiendo un diálogo fluido.

**Cierre de Sesión:**
- **Salir del sistema:**
    1. Para cerrar tu sesión de forma segura, haz clic en tu **nombre de usuario** que se encuentra en la parte superior derecha de la pantalla.
    2. En el menú desplegable, selecciona la opción "Cerrar Sesión".
    3. Se mostrará un mensaje de confirmación indicando que has salido correctamente del sistema.

**Tu estilo de respuesta debe ser:**
- Extremadamente amigable, claro y conciso.
- Siempre relacionado con la información proporcionada sobre NexoEDU.
- Proporciona **instrucciones paso a paso** claras cuando se pregunte cómo hacer algo (ej. "Cómo iniciar sesión").
- Si no sabes la respuesta o la pregunta está fuera del alcance de la información de NexoEDU, di amablemente que no tienes esa información, pero ofrece guiar al usuario a la sección de ayuda o a la página de inicio.
- **Evita inventar información.** Si no está en esta guía, no lo inventes.
- Usa emojis de forma ocasional para sonar más cercano y alentador (pero no en exceso).
- Anima al usuario a explorar la plataforma.
"""


@app.route('/chat', methods=['POST'])
def chat():
    user_message = request.json.get("message")

    if not user_message:
        return jsonify({"error": "El mensaje no puede estar vacío."}), 400

    
    if "chat_history" not in session or not session["chat_history"]:
        session["chat_history"] = [
            {
                "role": "user",
                "parts": [NEXOEDU_SYSTEM_INSTRUCTIONS],
            } 
        ]

    try:
        # Pasa el historial al modelo
        chat_session = model.start_chat(history=session["chat_history"])

        response = chat_session.send_message(user_message)
        bot_response = response.text

        
        session["chat_history"].append({"role": "user", "parts": [user_message]})
        session["chat_history"].append({"role": "model", "parts": [bot_response]})

        
        max_history_length = (
            21  
        )
        if len(session["chat_history"]) > max_history_length:
            
            session["chat_history"] = [session["chat_history"][0]] + session[
                "chat_history"
            ][-(max_history_length - 1) :]

        return jsonify({"response": bot_response})
    except Exception as e:
        print(f"Error al llamar a la API de Gemini: {e}")
        
        session["chat_history"] = []
        return (
            jsonify(
                {
                    "error": "Lo siento, hubo un error al procesar tu solicitud. Por favor, intenta de nuevo más tarde."
                }
            ),
            500,
        )


if __name__ == "__main__":
    app.run(debug=True)
