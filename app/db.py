import mysql.connector
from mysql.connector import Error


def conectar_mysql():
    try:
        conexion = mysql.connector.connect(
            host="localhost", user="root", password="", database="nexoedu_bd"
        )
        if conexion.is_connected():
            print("Conexión exitosa a MySQL")
            return conexion
    except Error as e:
        print(f"Error al conectar a MySQL: {e}")
        return None
