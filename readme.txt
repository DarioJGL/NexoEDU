# NexoEDU - Instrucciones de Instalación y Ejecución

## Requisitos Previos
- Python 3.10 o superior
- pip (gestor de paquetes de Python)
- MySQL Server configurado y corriendo
- (Opcional) Entorno virtual recomendado

## 1. Clonar o descargar el proyecto
Descarga o clona este repositorio en tu equipo.

## 2. Crear y activar un entorno virtual (opcional pero recomendado)
En PowerShell:
```
python -m venv venv
.\venv\Scripts\Activate
```

## 3. Instalar dependencias
Ejecuta en la raíz del proyecto:
```
pip install -r requirements.txt
```

## 4. Configurar variables de entorno
Crea un archivo `.env` en la carpeta `app` con el siguiente contenido (ajusta los valores según tu configuración):
```
API_KEY=tu_clave_de_api_de_gemini
DB_HOST=localhost
DB_USER=tu_usuario_mysql
DB_PASSWORD=tu_contraseña_mysql
DB_NAME=nombre_de_tu_base_de_datos
```

## 5. Configurar la base de datos
- Crea la base de datos y las tablas necesarias en MySQL según el modelo de tu aplicación.
- Asegúrate de que los datos de conexión en el archivo `.env` sean correctos.

## 6. Ejecutar la aplicación
Desde la carpeta raíz del proyecto:
```
python -m app.app
```
O bien:
```
cd app
python app.py
```

La aplicación estará disponible en: http://127.0.0.1:5000/

## 7. Acceso
- Regístrate como usuario o inicia sesión con una cuenta existente.
- Accede a las diferentes funcionalidades según tu tipo de usuario.

## Notas adicionales
- Si tienes problemas con dependencias, asegúrate de tener actualizado pip: `python -m pip install --upgrade pip`
- Si usas otro sistema operativo, adapta los comandos de entorno virtual según corresponda.
- Para producción, configura una clave secreta segura y desactiva el modo debug.

---

¡Listo! Si tienes dudas, revisa la documentación interna o contacta al administrador del proyecto.
