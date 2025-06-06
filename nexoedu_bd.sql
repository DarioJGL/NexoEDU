-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Servidor: 127.0.0.1
-- Tiempo de generación: 05-06-2025 a las 05:59:57
-- Versión del servidor: 10.4.32-MariaDB
-- Versión de PHP: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Base de datos: `nexoedu_bd`
--

DELIMITER $$
--
-- Procedimientos
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_actualizar_progreso_leccion` (IN `p_id_inscripcion` INT, IN `p_id_leccion` INT, IN `p_tiempo_invertido` INT, IN `p_completada` BOOLEAN)   BEGIN
    DECLARE v_progreso_actual DECIMAL(5,2) DEFAULT 0;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
    END;
    
    START TRANSACTION;
    
    -- Insertar o actualizar progreso de lección
    INSERT INTO PROGRESO_LECCION 
    (id_inscripcion, id_leccion, completada, fecha_inicio, fecha_completado, 
     tiempo_invertido_minutos, numero_visitas, progreso_porcentaje)
    VALUES 
    (p_id_inscripcion, p_id_leccion, p_completada, 
     CASE WHEN p_completada THEN NOW() ELSE NOW() END,
     CASE WHEN p_completada THEN NOW() ELSE NULL END,
     p_tiempo_invertido, 1, 
     CASE WHEN p_completada THEN 100.00 ELSE 50.00 END)
    ON DUPLICATE KEY UPDATE
        completada = p_completada,
        fecha_completado = CASE WHEN p_completada AND completada = FALSE THEN NOW() ELSE fecha_completado END,
        tiempo_invertido_minutos = tiempo_invertido_minutos + p_tiempo_invertido,
        numero_visitas = numero_visitas + 1,
        progreso_porcentaje = CASE WHEN p_completada THEN 100.00 ELSE GREATEST(progreso_porcentaje, 50.00) END;
    
    -- Actualizar progreso general del curso
    SELECT 
        ROUND(
            (COUNT(CASE WHEN pl.completada = TRUE THEN 1 END) * 100.0) / COUNT(*), 2
        ) INTO v_progreso_actual
    FROM LECCION l
    JOIN MODULO m ON l.id_modulo = m.id_modulo
    JOIN INSCRIPCION_CURSO ic ON m.id_curso = ic.id_curso
    LEFT JOIN PROGRESO_LECCION pl ON l.id_leccion = pl.id_leccion AND pl.id_inscripcion = ic.id_inscripcion
    WHERE ic.id_inscripcion = p_id_inscripcion
      AND l.activa = TRUE;
    
    UPDATE INSCRIPCION_CURSO 
    SET progreso_porcentaje = v_progreso_actual,
        estado_inscripcion = CASE 
            WHEN v_progreso_actual = 100.00 THEN 'completada'
            ELSE estado_inscripcion 
        END,
        fecha_completado = CASE 
            WHEN v_progreso_actual = 100.00 AND estado_inscripcion != 'completada' THEN NOW()
            ELSE fecha_completado 
        END
    WHERE id_inscripcion = p_id_inscripcion;
    
    COMMIT;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_generar_certificado` (IN `p_id_inscripcion` INT, OUT `p_codigo_verificacion` VARCHAR(50))   BEGIN
    DECLARE v_inscripcion_completada INT DEFAULT 0;
    DECLARE v_certificado_existe INT DEFAULT 0;
    DECLARE v_hash_verificacion VARCHAR(255);
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_codigo_verificacion = NULL;
    END;
    
    START TRANSACTION;
    
    -- Verificar si la inscripción está completada
    SELECT COUNT(*) INTO v_inscripcion_completada
    FROM INSCRIPCION_CURSO
    WHERE id_inscripcion = p_id_inscripcion 
      AND estado_inscripcion = 'completada';
    
    IF v_inscripcion_completada = 0 THEN
        SET p_codigo_verificacion = NULL;
        ROLLBACK;
    ELSE
        -- Verificar si ya existe certificado
        SELECT COUNT(*) INTO v_certificado_existe
        FROM CERTIFICADO
        WHERE id_inscripcion = p_id_inscripcion AND activo = TRUE;
        
        IF v_certificado_existe > 0 THEN
            -- Devolver código existente
            SELECT codigo_verificacion INTO p_codigo_verificacion
            FROM CERTIFICADO
            WHERE id_inscripcion = p_id_inscripcion AND activo = TRUE
            LIMIT 1;
        ELSE
            -- Generar nuevo código
            SET p_codigo_verificacion = CONCAT('CERT-', YEAR(NOW()), '-', 
                LPAD(p_id_inscripcion, 6, '0'), '-', 
                LPAD(FLOOR(RAND() * 999999), 6, '0'));
            
            SET v_hash_verificacion = SHA2(CONCAT(p_codigo_verificacion, NOW()), 256);
            
            -- Insertar certificado
            INSERT INTO CERTIFICADO 
            (id_inscripcion, codigo_verificacion, hash_verificacion, plantilla_usada)
            VALUES 
            (p_id_inscripcion, p_codigo_verificacion, v_hash_verificacion, 'standard');
        END IF;
        
        COMMIT;
    END IF;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_inscribir_estudiante` (IN `p_id_usuario` INT, IN `p_id_curso` INT, OUT `p_resultado` VARCHAR(100))   BEGIN
    DECLARE v_existe_inscripcion INT DEFAULT 0;
    DECLARE v_curso_disponible INT DEFAULT 0;
    DECLARE v_es_estudiante INT DEFAULT 0;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_resultado = 'ERROR: No se pudo procesar la inscripción';
    END;
    
    START TRANSACTION;
    
    -- Verificar si el usuario es estudiante
    SELECT COUNT(*) INTO v_es_estudiante
    FROM USUARIO 
    WHERE id_usuario = p_id_usuario 
      AND tipo_usuario = 'estudiante' 
      AND activo = TRUE;
    
    IF v_es_estudiante = 0 THEN
        SET p_resultado = 'ERROR: Usuario no válido o no es estudiante';
        ROLLBACK;
    ELSE
        -- Verificar si ya existe inscripción
        SELECT COUNT(*) INTO v_existe_inscripcion
        FROM INSCRIPCION_CURSO
        WHERE id_usuario = p_id_usuario AND id_curso = p_id_curso;
        
        IF v_existe_inscripcion > 0 THEN
            SET p_resultado = 'ERROR: El estudiante ya está inscrito en este curso';
            ROLLBACK;
        ELSE
            -- Verificar si el curso está disponible para la institución
            SELECT COUNT(*) INTO v_curso_disponible
            FROM CURSO_INSTITUCION ci
            JOIN USUARIO u ON ci.id_institucion = u.id_institucion
            WHERE u.id_usuario = p_id_usuario 
              AND ci.id_curso = p_id_curso 
              AND ci.activo = TRUE;
            
            IF v_curso_disponible = 0 THEN
                SET p_resultado = 'ERROR: Curso no disponible para esta institución';
                ROLLBACK;
            ELSE
                -- Realizar la inscripción
                INSERT INTO INSCRIPCION_CURSO (id_usuario, id_curso, estado_inscripcion)
                VALUES (p_id_usuario, p_id_curso, 'activa');
                
                SET p_resultado = 'SUCCESS: Inscripción realizada correctamente';
                COMMIT;
            END IF;
        END IF;
    END IF;
END$$

--
-- Funciones
--
CREATE DEFINER=`root`@`localhost` FUNCTION `fn_calcular_progreso_curso` (`p_id_inscripcion` INT) RETURNS DECIMAL(5,2) DETERMINISTIC READS SQL DATA BEGIN
    DECLARE v_progreso DECIMAL(5,2) DEFAULT 0.00;
    
    SELECT 
        COALESCE(
            ROUND(
                (COUNT(CASE WHEN pl.completada = TRUE THEN 1 END) * 100.0) / 
                NULLIF(COUNT(*), 0), 2
            ), 0.00
        ) INTO v_progreso
    FROM LECCION l
    JOIN MODULO m ON l.id_modulo = m.id_modulo
    JOIN INSCRIPCION_CURSO ic ON m.id_curso = ic.id_curso
    LEFT JOIN PROGRESO_LECCION pl ON l.id_leccion = pl.id_leccion 
                                   AND pl.id_inscripcion = ic.id_inscripcion
    WHERE ic.id_inscripcion = p_id_inscripcion
      AND l.activa = TRUE;
    
    RETURN v_progreso;
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `auditoria`
--

CREATE TABLE `auditoria` (
  `id_auditoria` int(11) NOT NULL,
  `id_usuario` int(11) DEFAULT NULL,
  `tabla_afectada` varchar(100) NOT NULL,
  `accion` enum('INSERT','UPDATE','DELETE') NOT NULL,
  `datos_anteriores` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`datos_anteriores`)),
  `datos_nuevos` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`datos_nuevos`)),
  `fecha_accion` datetime DEFAULT current_timestamp(),
  `ip_address` varchar(45) DEFAULT NULL,
  `descripcion_accion` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Registro de auditoría de todas las operaciones críticas';

--
-- Volcado de datos para la tabla `auditoria`
--

INSERT INTO `auditoria` (`id_auditoria`, `id_usuario`, `tabla_afectada`, `accion`, `datos_anteriores`, `datos_nuevos`, `fecha_accion`, `ip_address`, `descripcion_accion`) VALUES
(1, 1, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 1, \"email\": \"admin@nexoedu.co\", \"tipo_usuario\": \"admin_general\"}', '2025-05-23 00:56:46', NULL, 'Usuario creado: Administrador General'),
(2, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-05-23 18:00:05', NULL, 'Usuario actualizado: Administrador General'),
(3, 3, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 3, \"email\": \"dariojgl0211@gmail.com\", \"tipo_usuario\": \"estudiante\"}', '2025-05-23 18:34:25', NULL, 'Usuario creado: Dario Gutierrez'),
(4, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-05-23 13:35:19', NULL, 'Usuario actualizado: Administrador General'),
(5, 4, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 4, \"email\": \"dariojgl02@gmail.com\", \"tipo_usuario\": \"estudiante\"}', '2025-05-23 18:48:47', NULL, 'Usuario creado: Dario Gutierrez'),
(6, 3, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-05-23 13:49:58', NULL, 'Usuario actualizado: Dario Gutierrez'),
(7, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-05-23 13:50:11', NULL, 'Usuario actualizado: Administrador General'),
(11, 6, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 6, \"email\": \"prueba1@gmail.com\", \"tipo_usuario\": \"estudiante\"}', '2025-05-29 16:02:50', NULL, 'Usuario creado: Prueba Aprueba'),
(12, 6, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:52:20\"}', '2025-05-29 16:52:20', NULL, 'Usuario actualizado: Prueba Aprueba'),
(13, 6, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:52:20\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:53:41\"}', '2025-05-29 16:53:41', NULL, 'Usuario actualizado: Prueba Aprueba'),
(14, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-05-29 16:55:00', NULL, 'Usuario actualizado: Administrador General'),
(15, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:55:27\"}', '2025-05-29 16:55:27', NULL, 'Usuario actualizado: Administrador General'),
(16, 6, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:53:41\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:53:41\"}', '2025-05-29 16:56:49', NULL, 'Usuario actualizado: Prueba Aprueba'),
(17, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@nexoedu.co\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:55:27\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:55:27\"}', '2025-05-29 16:57:03', NULL, 'Usuario actualizado: Administrador General'),
(18, 7, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 7, \"email\": \"prueba1@gmail.com\", \"tipo_usuario\": \"estudiante\"}', '2025-05-29 17:04:01', NULL, 'Usuario creado: Prueba Aprueba'),
(19, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:53:41\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:07:39\"}', '2025-05-29 17:07:39', NULL, 'Usuario actualizado: Prueba Aprueba'),
(20, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:09:14\"}', '2025-05-29 17:09:14', NULL, 'Usuario actualizado: Prueba Aprueba'),
(21, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:09:14\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:21:59\"}', '2025-05-29 17:21:59', NULL, 'Usuario actualizado: Prueba Aprueba'),
(22, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:07:39\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:22:12\"}', '2025-05-29 17:22:12', NULL, 'Usuario actualizado: Prueba Aprueba'),
(23, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:21:59\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:29:21\"}', '2025-05-29 17:29:21', NULL, 'Usuario actualizado: Prueba Aprueba'),
(24, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:29:21\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 20:29:27\"}', '2025-05-29 20:29:27', NULL, 'Usuario actualizado: Prueba Aprueba'),
(25, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 17:22:12\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 20:47:04\"}', '2025-05-29 20:47:04', NULL, 'Usuario actualizado: Prueba Aprueba'),
(26, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 20:29:27\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 21:37:02\"}', '2025-05-29 21:37:02', NULL, 'Usuario actualizado: Prueba Aprueba'),
(27, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 21:37:02\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 21:54:17\"}', '2025-05-29 21:54:17', NULL, 'Usuario actualizado: Prueba Aprueba'),
(28, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 21:54:17\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 23:03:43\"}', '2025-05-29 23:03:43', NULL, 'Usuario actualizado: Prueba Aprueba'),
(29, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 23:03:43\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 23:06:42\"}', '2025-05-29 23:06:42', NULL, 'Usuario actualizado: Prueba Aprueba'),
(30, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 23:06:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 23:24:56\"}', '2025-05-29 23:24:56', NULL, 'Usuario actualizado: Prueba Aprueba'),
(31, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 16:55:27\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 09:46:32\"}', '2025-05-30 09:46:32', NULL, 'Usuario actualizado: Administrador General'),
(32, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 09:46:32\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 10:30:14\"}', '2025-05-30 10:30:14', NULL, 'Usuario actualizado: Administrador General'),
(33, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 10:30:14\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 10:43:56\"}', '2025-05-30 10:43:56', NULL, 'Usuario actualizado: Administrador General'),
(34, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 10:43:56\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 10:57:01\"}', '2025-05-30 10:57:01', NULL, 'Usuario actualizado: Administrador General'),
(35, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 10:57:01\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 11:44:53\"}', '2025-05-30 11:44:53', NULL, 'Usuario actualizado: Administrador General'),
(36, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 11:44:53\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 12:03:40\"}', '2025-05-30 12:03:40', NULL, 'Usuario actualizado: Administrador General'),
(37, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 12:03:40\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 12:05:05\"}', '2025-05-30 12:05:05', NULL, 'Usuario actualizado: Administrador General'),
(38, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 12:05:05\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:38:32\"}', '2025-05-30 13:38:32', NULL, 'Usuario actualizado: Administrador General'),
(39, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:38:32\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:40:21\"}', '2025-05-30 13:40:21', NULL, 'Usuario actualizado: Administrador General'),
(40, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:40:21\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:41:41\"}', '2025-05-30 13:41:41', NULL, 'Usuario actualizado: Administrador General'),
(41, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:41:41\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:46:35\"}', '2025-05-30 13:46:35', NULL, 'Usuario actualizado: Administrador General'),
(42, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 13:46:35\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:19:44\"}', '2025-05-30 14:19:44', NULL, 'Usuario actualizado: Administrador General'),
(43, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:19:44\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:43:43\"}', '2025-05-30 14:43:43', NULL, 'Usuario actualizado: Administrador General'),
(44, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:43:43\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:47:40\"}', '2025-05-30 14:47:40', NULL, 'Usuario actualizado: Administrador General'),
(45, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:47:40\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:51:13\"}', '2025-05-30 14:51:13', NULL, 'Usuario actualizado: Administrador General'),
(46, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:51:13\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:51:27\"}', '2025-05-30 14:51:27', NULL, 'Usuario actualizado: Administrador General'),
(47, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:51:27\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:53:52\"}', '2025-05-30 14:53:52', NULL, 'Usuario actualizado: Administrador General'),
(48, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:53:52\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:55:53\"}', '2025-05-30 14:55:53', NULL, 'Usuario actualizado: Administrador General'),
(49, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 14:55:53\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 15:00:18\"}', '2025-05-30 15:00:18', NULL, 'Usuario actualizado: Administrador General'),
(50, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 15:00:18\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 15:02:20\"}', '2025-05-30 15:02:20', NULL, 'Usuario actualizado: Administrador General'),
(51, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 15:02:20\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 15:11:22\"}', '2025-05-30 15:11:22', NULL, 'Usuario actualizado: Administrador General'),
(52, 4, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl02@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"dariojgl02@gmail.com\", \"activo\": 0, \"ultimo_acceso\": null}', '2025-05-30 16:39:15', NULL, 'Usuario actualizado: Dario Gutierrez'),
(53, 3, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 0, \"ultimo_acceso\": null}', '2025-05-30 16:39:21', NULL, 'Usuario actualizado: Dario Gutierrez'),
(54, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 15:11:22\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:41:52\"}', '2025-05-30 16:41:52', NULL, 'Usuario actualizado: Administrador General'),
(55, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 23:24:56\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-05-30 16:43:42', NULL, 'Usuario actualizado: Prueba Aprueba'),
(56, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:41:52\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:46:45\"}', '2025-05-30 16:46:45', NULL, 'Usuario actualizado: Administrador General'),
(57, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:46:45\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:47:47\"}', '2025-05-30 16:47:47', NULL, 'Usuario actualizado: Administrador General'),
(58, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:47:47\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:51:18\"}', '2025-05-30 16:51:18', NULL, 'Usuario actualizado: Administrador General'),
(59, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:51:18\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:56:21\"}', '2025-05-30 16:56:21', NULL, 'Usuario actualizado: Administrador General'),
(60, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:56:21\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:56:55\"}', '2025-05-30 16:56:55', NULL, 'Usuario actualizado: Administrador General'),
(61, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:56:55\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:59:20\"}', '2025-05-30 16:59:20', NULL, 'Usuario actualizado: Administrador General'),
(62, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:59:20\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:59:41\"}', '2025-05-30 16:59:41', NULL, 'Usuario actualizado: Administrador General'),
(63, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:59:41\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:00:37\"}', '2025-05-30 17:00:37', NULL, 'Usuario actualizado: Administrador General'),
(64, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:00:37\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:01:25\"}', '2025-05-30 17:01:25', NULL, 'Usuario actualizado: Administrador General'),
(65, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:01:25\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:02:15\"}', '2025-05-30 17:02:15', NULL, 'Usuario actualizado: Administrador General'),
(66, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:02:15\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:02:31\"}', '2025-05-30 17:02:31', NULL, 'Usuario actualizado: Administrador General'),
(67, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-29 20:47:04\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 16:23:16\"}', '2025-06-01 16:23:16', NULL, 'Usuario actualizado: Prueba Aprueba'),
(68, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 17:02:31\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 16:23:36\"}', '2025-06-01 16:23:36', NULL, 'Usuario actualizado: Administrador General'),
(69, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 16:23:36\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 17:02:41\"}', '2025-06-01 17:02:41', NULL, 'Usuario actualizado: Administrador General'),
(70, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 17:02:41\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 17:50:30\"}', '2025-06-01 17:50:30', NULL, 'Usuario actualizado: Administrador General'),
(71, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-01 18:09:49', NULL, 'Usuario actualizado: Prueba prueba'),
(72, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-01 18:26:47', NULL, 'Usuario actualizado: Estudiante prueba'),
(73, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-01 18:27:23', NULL, 'Usuario actualizado: Estudiante prueba'),
(74, 3, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 0, \"ultimo_acceso\": null}', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-06-01 18:27:27', NULL, 'Usuario actualizado: Dario Gutierrez'),
(75, 4, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl02@gmail.com\", \"activo\": 0, \"ultimo_acceso\": null}', '{\"email\": \"dariojgl02@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-06-01 18:27:31', NULL, 'Usuario actualizado: Dario Gutierrez'),
(76, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-01 18:29:20', NULL, 'Usuario actualizado: Estudiante prueba'),
(77, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 17:50:30\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:29:35\"}', '2025-06-01 18:29:35', NULL, 'Usuario actualizado: Administrador General'),
(78, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:29:35\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:31:53\"}', '2025-06-01 18:31:53', NULL, 'Usuario actualizado: Administrador General'),
(79, 3, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl0211@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"estudiante2@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-06-01 18:32:29', NULL, 'Usuario actualizado: Dario Gutierrez'),
(80, 3, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante2@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"estudiante2@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-06-01 18:33:21', NULL, 'Usuario actualizado: Estudiante Prueba'),
(81, 4, 'USUARIO', 'UPDATE', '{\"email\": \"dariojgl02@gmail.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"estudiante3@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '2025-06-01 18:34:19', NULL, 'Usuario actualizado: Estudiante Prueba'),
(82, 4, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante3@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"estudiante3@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:34:47\"}', '2025-06-01 18:34:47', NULL, 'Usuario actualizado: Estudiante Prueba'),
(83, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:31:53\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:35:33\"}', '2025-06-01 18:35:33', NULL, 'Usuario actualizado: Administrador General'),
(84, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 16:23:16\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 16:23:16\"}', '2025-06-01 19:11:37', NULL, 'Usuario actualizado: Prueba Prueba'),
(85, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:35:33\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 20:57:35\"}', '2025-06-01 20:57:35', NULL, 'Usuario actualizado: Administrador General'),
(86, 8, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 8, \"email\": \"admin2@demo.com\", \"tipo_usuario\": \"admin_institucional\"}', '2025-06-01 21:00:11', NULL, 'Usuario creado: Admin Prueba'),
(87, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 20:57:35\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 21:23:09\"}', '2025-06-01 21:23:09', NULL, 'Usuario actualizado: Administrador General'),
(88, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 21:23:09\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 21:26:39\"}', '2025-06-01 21:26:39', NULL, 'Usuario actualizado: Administrador General'),
(89, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 21:26:39\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 08:14:57\"}', '2025-06-02 08:14:57', NULL, 'Usuario actualizado: Administrador General'),
(90, 9, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 9, \"email\": \"docente@demo.com\", \"tipo_usuario\": \"docente\"}', '2025-06-02 08:16:21', NULL, 'Usuario creado: Admin Prueba'),
(91, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 08:14:57\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 09:04:01\"}', '2025-06-02 09:04:01', NULL, 'Usuario actualizado: Administrador General'),
(92, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-02 09:04:05', NULL, 'Usuario actualizado: Estudiante prueba'),
(93, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-02 09:04:38', NULL, 'Usuario actualizado: Estudiante prueba'),
(94, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 09:04:01\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 09:14:45\"}', '2025-06-02 09:14:45', NULL, 'Usuario actualizado: Administrador General'),
(95, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-02 09:19:15', NULL, 'Usuario actualizado: Estudiante prueba'),
(96, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-02 09:19:28', NULL, 'Usuario actualizado: Estudiante prueba'),
(97, 7, 'USUARIO', 'UPDATE', '{\"email\": \"prueba1@gmail.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '{\"email\": \"prueba1@gmail.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-05-30 16:43:42\"}', '2025-06-02 09:21:37', NULL, 'Usuario actualizado: Estudiante prueba'),
(98, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 09:14:45\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 09:23:35\"}', '2025-06-02 09:23:35', NULL, 'Usuario actualizado: Administrador General'),
(99, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 09:23:35\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 10:08:36\"}', '2025-06-02 10:08:36', NULL, 'Usuario actualizado: Administrador General'),
(100, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 10:08:36\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 10:33:56\"}', '2025-06-02 10:33:56', NULL, 'Usuario actualizado: Administrador General'),
(101, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 10:33:56\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 11:11:01\"}', '2025-06-02 11:11:01', NULL, 'Usuario actualizado: Administrador General'),
(102, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 16:23:16\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 12:14:41\"}', '2025-06-02 12:14:41', NULL, 'Usuario actualizado: Prueba Prueba'),
(103, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 11:11:01\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 12:33:22\"}', '2025-06-02 12:33:22', NULL, 'Usuario actualizado: Administrador General'),
(104, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 12:14:41\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 15:47:50\"}', '2025-06-02 15:47:50', NULL, 'Usuario actualizado: Prueba Prueba'),
(105, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 12:33:22\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 15:50:43\"}', '2025-06-02 15:50:43', NULL, 'Usuario actualizado: Administrador General'),
(106, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 15:47:50\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 15:55:58\"}', '2025-06-02 15:55:58', NULL, 'Usuario actualizado: Prueba Prueba'),
(107, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 15:55:58\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 20:26:58\"}', '2025-06-02 20:26:58', NULL, 'Usuario actualizado: Prueba Prueba'),
(108, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 15:50:43\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 20:27:17\"}', '2025-06-02 20:27:17', NULL, 'Usuario actualizado: Administrador General'),
(109, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 20:26:58\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 20:29:49\"}', '2025-06-02 20:29:49', NULL, 'Usuario actualizado: Prueba Prueba'),
(110, 6, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 20:29:49\"}', '{\"email\": \"estudiante@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 21:07:19\"}', '2025-06-02 21:07:19', NULL, 'Usuario actualizado: Prueba Prueba'),
(111, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 20:27:17\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 21:09:00\"}', '2025-06-02 21:09:00', NULL, 'Usuario actualizado: Administrador General'),
(112, 4, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante3@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:34:47\"}', '{\"email\": \"estudiante3@demo.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-06-01 18:34:47\"}', '2025-06-02 21:09:49', NULL, 'Usuario actualizado: Estudiante Prueba'),
(113, 4, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante3@demo.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-06-01 18:34:47\"}', '{\"email\": \"estudiante3@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-01 18:34:47\"}', '2025-06-02 21:10:31', NULL, 'Usuario actualizado: Estudiante Prueba'),
(114, 10, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 10, \"email\": \"estudiante5@demo.com\", \"tipo_usuario\": \"estudiante\"}', '2025-06-04 22:19:37', NULL, 'Usuario creado: Prueba Apellido'),
(115, 10, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '2025-06-04 22:19:57', NULL, 'Usuario actualizado: Prueba Apellido'),
(116, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-02 21:09:00\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:21:27\"}', '2025-06-04 22:21:27', NULL, 'Usuario actualizado: Administrador General'),
(117, 10, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '2025-06-04 22:24:39', NULL, 'Usuario actualizado: Prueba Apellido'),
(118, 10, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '2025-06-04 22:24:49', NULL, 'Usuario actualizado: Prueba Apellido'),
(119, 10, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '2025-06-04 22:26:26', NULL, 'Usuario actualizado: Prueba Apellido'),
(120, 10, 'USUARIO', 'UPDATE', '{\"email\": \"estudiante5@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '{\"email\": \"estudiante5@demo.com\", \"activo\": 0, \"ultimo_acceso\": \"2025-06-04 22:19:57\"}', '2025-06-04 22:26:32', NULL, 'Usuario actualizado: Prueba Apellido'),
(121, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:21:27\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:33:59\"}', '2025-06-04 22:33:59', NULL, 'Usuario actualizado: Administrador General'),
(122, 1, 'USUARIO', 'UPDATE', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:33:59\"}', '{\"email\": \"admin@demo.com\", \"activo\": 1, \"ultimo_acceso\": \"2025-06-04 22:44:01\"}', '2025-06-04 22:44:01', NULL, 'Usuario actualizado: Administrador General'),
(123, 11, 'USUARIO', 'INSERT', NULL, '{\"id_usuario\": 11, \"email\": \"docente3@demo.com\", \"tipo_usuario\": \"docente\"}', '2025-06-04 22:44:57', NULL, 'Usuario creado: Docente Docente'),
(124, 11, 'USUARIO', 'UPDATE', '{\"email\": \"docente3@demo.com\", \"activo\": 1, \"ultimo_acceso\": null}', '{\"email\": \"docente3@demo.com\", \"activo\": 0, \"ultimo_acceso\": null}', '2025-06-04 22:45:31', NULL, 'Usuario actualizado: Docente Docente');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `certificado`
--

CREATE TABLE `certificado` (
  `id_certificado` int(11) NOT NULL,
  `id_inscripcion` int(11) NOT NULL,
  `codigo_verificacion` varchar(50) NOT NULL,
  `fecha_emision` datetime DEFAULT current_timestamp(),
  `plantilla_usada` varchar(100) DEFAULT 'standard',
  `contenido_certificado` text DEFAULT NULL,
  `hash_verificacion` varchar(255) NOT NULL,
  `activo` tinyint(1) DEFAULT 1,
  `fecha_descarga` datetime DEFAULT NULL,
  `numero_descargas` int(11) DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Certificados digitales emitidos';

--
-- Disparadores `certificado`
--
DELIMITER $$
CREATE TRIGGER `tr_certificado_audit` AFTER INSERT ON `certificado` FOR EACH ROW BEGIN
    INSERT INTO AUDITORIA (tabla_afectada, accion, datos_nuevos, descripcion_accion)
    VALUES ('CERTIFICADO', 'INSERT',
            JSON_OBJECT('id_certificado', NEW.id_certificado, 'codigo_verificacion', NEW.codigo_verificacion),
            CONCAT('Certificado emitido: ', NEW.codigo_verificacion));
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `configuracion_sistema`
--

CREATE TABLE `configuracion_sistema` (
  `id_configuracion` int(11) NOT NULL,
  `clave_configuracion` varchar(100) NOT NULL,
  `valor_configuracion` text NOT NULL,
  `descripcion` text DEFAULT NULL,
  `tipo_dato` enum('string','number','boolean','json') DEFAULT 'string',
  `modificable_usuario` tinyint(1) DEFAULT 0,
  `fecha_modificacion` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `id_usuario_modificacion` int(11) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `configuracion_sistema`
--

INSERT INTO `configuracion_sistema` (`id_configuracion`, `clave_configuracion`, `valor_configuracion`, `descripcion`, `tipo_dato`, `modificable_usuario`, `fecha_modificacion`, `id_usuario_modificacion`) VALUES
(1, 'sistema.nombre', 'NexoEDU', 'Nombre de la plataforma', 'string', 0, '2025-05-23 00:56:46', NULL),
(2, 'sistema.version', '1.0.0', 'Versión actual del sistema', 'string', 0, '2025-05-23 00:56:46', NULL),
(3, 'certificados.plantilla_default', 'standard', 'Plantilla por defecto para certificados', 'string', 0, '2025-05-23 00:56:46', NULL),
(4, 'evaluaciones.intentos_default', '3', 'Número de intentos por defecto para evaluaciones', 'number', 0, '2025-05-23 00:56:46', NULL),
(5, 'evaluaciones.tiempo_default', '60', 'Tiempo límite por defecto en minutos', 'number', 0, '2025-05-23 00:56:46', NULL),
(6, 'notificaciones.email_habilitado', 'true', 'Habilitar envío de notificaciones por email', 'boolean', 0, '2025-05-23 00:56:46', NULL),
(7, 'sistema.mantenimiento', 'false', 'Modo mantenimiento activado', 'boolean', 0, '2025-05-23 00:56:46', NULL),
(8, 'seguridad.sesion_timeout', '120', 'Tiempo de expiración de sesión en minutos', 'number', 0, '2025-05-23 00:56:46', NULL),
(9, 'reportes.max_registros', '10000', 'Máximo número de registros en reportes', 'number', 0, '2025-05-23 00:56:46', NULL),
(10, 'sistema.timezone', 'America/Bogota', 'Zona horaria del sistema', 'string', 0, '2025-05-23 00:56:46', NULL);

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `curso`
--

CREATE TABLE `curso` (
  `id_curso` int(11) NOT NULL,
  `titulo` varchar(255) NOT NULL,
  `descripcion` text NOT NULL,
  `objetivos` text DEFAULT NULL,
  `duracion_estimada_horas` int(11) DEFAULT 0,
  `nivel_dificultad` enum('basico','intermedio','avanzado') DEFAULT 'basico',
  `categoria` varchar(100) DEFAULT NULL,
  `prerequisitos` text DEFAULT NULL,
  `activo` tinyint(1) DEFAULT 1,
  `fecha_creacion` datetime DEFAULT current_timestamp(),
  `fecha_actualizacion` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `id_creador` int(11) DEFAULT NULL,
  `imagen_portada` varchar(500) DEFAULT NULL,
  `competencias_desarrolladas` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Cursos complementarios disponibles en la plataforma';

--
-- Volcado de datos para la tabla `curso`
--

INSERT INTO `curso` (`id_curso`, `titulo`, `descripcion`, `objetivos`, `duracion_estimada_horas`, `nivel_dificultad`, `categoria`, `prerequisitos`, `activo`, `fecha_creacion`, `fecha_actualizacion`, `id_creador`, `imagen_portada`, `competencias_desarrolladas`) VALUES
(1, 'Introducción a Python', 'Aprende los fundamentos de la programación con Python.', 'Dominar sintaxis básica, estructuras de datos y funciones.', 20, 'basico', 'Programación', 'Ninguno', 1, '2025-05-01 10:00:00', '2025-06-02 11:52:20', NULL, 'python.jpg', 'Resolución de problemas, pensamiento lógico, programación básica'),
(2, 'Desarrollo Web con JavaScript', 'Crea aplicaciones web interactivas usando JavaScript.', 'Construir interfaces dinámicas y manejar eventos.', 30, 'intermedio', 'Programación', 'Conocimientos básicos de HTML y CSS', 1, '2025-05-10 09:00:00', '2025-05-10 09:00:00', NULL, 'js_web.jpg', 'Desarrollo front-end, lógica de programación, diseño responsivo'),
(3, 'Algoritmos Datos', 'Explora algoritmos  y estructuras de datos.', 'Optimizar código y resolver problemas complejos.', 40, 'avanzado', 'Programación', 'Programación intermedia', 1, '2025-05-15 12:00:00', '2025-05-29 21:39:55', NULL, 'algoritmos.jpg', 'Análisis algorítmico, optimización, pensamiento computacional'),
(4, 'Finanzas Personales Básicas', 'Gestiona tu dinero de forma efectiva.', 'Crear presupuestos y planificar ahorros.', 15, 'basico', 'Finanzas', 'Ninguno', 1, '2025-05-02 11:00:00', '2025-06-02 11:52:15', NULL, 'finanzas_personales.jpg', 'Gestión financiera, planificación, ahorro'),
(5, 'Inversión en Bolsa', 'Aprende a invertir en mercados financieros.', 'Analizar acciones y construir un portafolio.', 25, 'intermedio', 'Finanzas', 'Conocimientos básicos de economía', 1, '2025-05-12 14:00:00', '2025-05-12 14:00:00', NULL, 'bolsa.jpg', 'Análisis financiero, toma de decisiones, gestión de riesgos'),
(6, 'Contabilidad', 'contables clave para tu negocio.', 'Llevar registros financieros y entender balances.', 20, 'intermedio', 'Finanzas', 'Ninguno', 1, '2025-05-20 08:00:00', '2025-05-29 21:39:22', NULL, 'contabilidad.jpg', 'Contabilidad básica, análisis financiero, gestión empresarial'),
(7, 'Lanzamiento de Startups', 'Convierte tu idea en un negocio exitoso.', 'Desarrollar un plan de negocio y atraer inversores.', 30, 'intermedio', 'Emprendimiento', 'Ninguno', 1, '2025-05-05 13:00:00', '2025-05-05 13:00:00', NULL, 'startup.jpg', 'Planificación estratégica, innovación, liderazgo'),
(8, 'Marketing ', 'Estrategias para promocionar tu negocio.', 'Crear campañas efectivas y construir una marca.', 25, 'intermedio', 'Emprendimiento', 'Conocimientos básicos de marketing', 1, '2025-05-18 10:00:00', '2025-05-29 21:40:03', NULL, 'marketing.jpg', 'Marketing digital, branding, análisis de mercado'),
(9, 'Gestión de Proyectos Ágiles', 'Aplica metodologías ágiles en tus proyectos.', 'Implementar Scrum y Kanban en equipos.', 20, 'avanzado', 'Emprendimiento', 'Experiencia en gestión de proyectos', 1, '2025-05-25 15:00:00', '2025-05-25 15:00:00', NULL, 'agile.jpg', 'Gestión de proyectos, trabajo en equipo, adaptabilidad'),
(10, 'Comunicación Efectiva', 'Mejora tus habilidades de comunicación interpersonal.', 'Hablar en público y transmitir ideas claras.', 15, 'basico', 'HabilidadesBlandas', 'Ninguno', 1, '2025-05-03 09:30:00', '2025-06-02 11:52:10', NULL, 'comunicacion.jpg', 'Comunicación verbal, escucha activa, empatía'),
(11, 'Liderazgo y Gestión de Equipos', 'Desarrolla habilidades para liderar equipos.', 'Motivar equipos y resolver conflictos.', 20, 'intermedio', 'HabilidadesBlandas', 'Experiencia laboral básica', 1, '2025-05-14 11:00:00', '2025-06-02 11:51:28', NULL, 'liderazgo.jpg', 'Liderazgo, resolución de conflictos, motivación'),
(12, 'Gestión del Tiempo', 'Optimiza tu productividad personal y profesional. mejora', 'Priorizar tareas y establecer metas efectivas.', 10, 'basico', 'HabilidadesBlandas', 'Ninguno', 1, '2025-05-22 12:00:00', '2025-06-04 22:28:06', NULL, 'gestion_tiempo.jpg', 'Productividad, organización, planificación');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `curso_institucion`
--

CREATE TABLE `curso_institucion` (
  `id_asignacion` int(11) NOT NULL,
  `id_curso` int(11) NOT NULL,
  `id_institucion` int(11) NOT NULL,
  `fecha_asignacion` datetime DEFAULT current_timestamp(),
  `fecha_vencimiento` datetime DEFAULT NULL,
  `activo` tinyint(1) DEFAULT 1,
  `cupos_disponibles` int(11) DEFAULT NULL,
  `condiciones_especiales` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `evaluacion`
--

CREATE TABLE `evaluacion` (
  `id_evaluacion` int(11) NOT NULL,
  `id_curso` int(11) DEFAULT NULL,
  `id_modulo` int(11) DEFAULT NULL,
  `titulo` varchar(255) NOT NULL,
  `descripcion` text DEFAULT NULL,
  `tipo_evaluacion` enum('quiz','proyecto','ensayo','practica') DEFAULT 'quiz',
  `tiempo_limite_minutos` int(11) DEFAULT 60,
  `puntaje_minimo_aprobacion` decimal(5,2) DEFAULT 70.00,
  `intentos_permitidos` int(11) DEFAULT 3,
  `activa` tinyint(1) DEFAULT 1,
  `fecha_creacion` datetime DEFAULT current_timestamp(),
  `instrucciones` text DEFAULT NULL
) ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `inscripcion_curso`
--

CREATE TABLE `inscripcion_curso` (
  `id_inscripcion` int(11) NOT NULL,
  `id_usuario` int(11) NOT NULL,
  `id_curso` int(11) NOT NULL,
  `fecha_inscripcion` datetime DEFAULT current_timestamp(),
  `estado_inscripcion` enum('activa','completada','abandonada','suspendida') DEFAULT 'activa',
  `progreso_porcentaje` decimal(5,2) DEFAULT 0.00,
  `fecha_completado` datetime DEFAULT NULL,
  `tiempo_total_invertido_minutos` int(11) DEFAULT 0,
  `calificacion_final` decimal(5,2) DEFAULT NULL,
  `observaciones` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Inscripciones de estudiantes en cursos';

--
-- Disparadores `inscripcion_curso`
--
DELIMITER $$
CREATE TRIGGER `tr_inscripcion_audit` AFTER INSERT ON `inscripcion_curso` FOR EACH ROW BEGIN
    INSERT INTO AUDITORIA (id_usuario, tabla_afectada, accion, datos_nuevos, descripcion_accion)
    VALUES (NEW.id_usuario, 'INSCRIPCION_CURSO', 'INSERT',
            JSON_OBJECT('id_inscripcion', NEW.id_inscripcion, 'id_curso', NEW.id_curso),
            'Nuevo estudiante inscrito en curso');
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `institucion`
--

CREATE TABLE `institucion` (
  `id_institucion` int(11) NOT NULL,
  `nombre_institucion` varchar(255) NOT NULL,
  `nit` varchar(20) NOT NULL,
  `direccion` varchar(500) DEFAULT NULL,
  `telefono` varchar(20) DEFAULT NULL,
  `email_institucional` varchar(100) DEFAULT NULL,
  `ciudad` varchar(100) NOT NULL,
  `departamento` varchar(100) NOT NULL,
  `fecha_registro` datetime DEFAULT current_timestamp(),
  `activo` tinyint(1) DEFAULT 1,
  `descripcion` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Almacena información de las instituciones educativas registradas';

--
-- Volcado de datos para la tabla `institucion`
--

INSERT INTO `institucion` (`id_institucion`, `nombre_institucion`, `nit`, `direccion`, `telefono`, `email_institucional`, `ciudad`, `departamento`, `fecha_registro`, `activo`, `descripcion`) VALUES
(1, 'Universidad Nacional de Colombia', '899999063-3', 'Calle 45 #30-03', '6013165000', 'info@unal.edu.co', 'Bogotá', 'Cundinamarca', '2023-01-01 00:00:00', 0, NULL),
(2, 'Universidad de los Andes', '860007386-1', 'Cra. 1 #18A-12', '6013394949', 'info@uniandes.edu.co', 'Bogotá', 'Cundinamarca', '2023-01-05 00:00:00', 0, NULL),
(3, 'Universidad Javeriana', '860013720-1', 'Carrera 7 #40-62', '6013208320', 'info@javeriana.edu.co', 'Bogotá', 'Cundinamarca', '2023-01-10 00:00:00', 1, NULL),
(4, 'Bogota', '899999034-1', 'Calle 57 #8-69', '6013430111', 'info@sena.edu.co', 'Barranquilla', 'Atlantico', '2023-01-15 00:00:00', 0, NULL),
(5, 'Colegio de Santa marta', '860007759-3', 'Cl. 12c #6-25', '6012970200', 'info@santa.edu.co', 'Santa Marta', 'Magdalena', '2023-01-20 00:00:00', 1, NULL),
(6, 'Colegio de Galapa', '86000158-2', 'galapa@correo.com', '6012970300', 'info@galapa.edu.co', 'Galapa', 'Atlantico', '2025-06-02 10:53:18', 1, NULL);

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `intento_evaluacion`
--

CREATE TABLE `intento_evaluacion` (
  `id_intento` int(11) NOT NULL,
  `id_inscripcion` int(11) NOT NULL,
  `id_evaluacion` int(11) NOT NULL,
  `numero_intento` int(11) NOT NULL,
  `fecha_inicio` datetime DEFAULT current_timestamp(),
  `fecha_envio` datetime DEFAULT NULL,
  `puntaje_obtenido` decimal(5,2) DEFAULT 0.00,
  `puntaje_maximo` decimal(5,2) NOT NULL,
  `estado_intento` enum('en_progreso','enviado','calificado','vencido') DEFAULT 'en_progreso',
  `comentarios_docente` text DEFAULT NULL,
  `aprobado` tinyint(1) DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `leccion`
--

CREATE TABLE `leccion` (
  `id_leccion` int(11) NOT NULL,
  `id_modulo` int(11) NOT NULL,
  `titulo` varchar(255) NOT NULL,
  `contenido_html` longtext DEFAULT NULL,
  `tipo_contenido` enum('texto','video','documento','interactivo') DEFAULT 'texto',
  `url_recurso` varchar(1000) DEFAULT NULL,
  `orden_leccion` int(11) NOT NULL,
  `duracion_estimada_minutos` int(11) DEFAULT 0,
  `obligatoria` tinyint(1) DEFAULT 1,
  `activa` tinyint(1) DEFAULT 1,
  `fecha_creacion` datetime DEFAULT current_timestamp(),
  `instrucciones_especiales` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Lecciones individuales dentro de cada módulo';

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `modulo`
--

CREATE TABLE `modulo` (
  `id_modulo` int(11) NOT NULL,
  `id_curso` int(11) NOT NULL,
  `titulo` varchar(255) NOT NULL,
  `descripcion` text DEFAULT NULL,
  `orden_modulo` int(11) NOT NULL,
  `duracion_estimada_minutos` int(11) DEFAULT 0,
  `activo` tinyint(1) DEFAULT 1,
  `fecha_creacion` datetime DEFAULT current_timestamp(),
  `objetivos_especificos` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Módulos que componen cada curso';

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `notificacion`
--

CREATE TABLE `notificacion` (
  `id_notificacion` int(11) NOT NULL,
  `id_usuario_destinatario` int(11) NOT NULL,
  `asunto` varchar(255) NOT NULL,
  `mensaje` text NOT NULL,
  `tipo_notificacion` enum('inscripcion','completado','evaluacion','general','sistema') DEFAULT 'general',
  `leida` tinyint(1) DEFAULT 0,
  `fecha_creacion` datetime DEFAULT current_timestamp(),
  `fecha_leida` datetime DEFAULT NULL,
  `url_accion` varchar(500) DEFAULT NULL,
  `prioridad` enum('baja','media','alta','critica') DEFAULT 'media'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `opcion_respuesta`
--

CREATE TABLE `opcion_respuesta` (
  `id_opcion` int(11) NOT NULL,
  `id_pregunta` int(11) NOT NULL,
  `texto_opcion` text NOT NULL,
  `es_correcta` tinyint(1) DEFAULT 0,
  `orden_opcion` int(11) NOT NULL,
  `explicacion` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `pregunta`
--

CREATE TABLE `pregunta` (
  `id_pregunta` int(11) NOT NULL,
  `id_evaluacion` int(11) NOT NULL,
  `enunciado` text NOT NULL,
  `tipo_pregunta` enum('multiple','verdadero_falso','abierta','completar') DEFAULT 'multiple',
  `puntaje` decimal(5,2) DEFAULT 1.00,
  `orden_pregunta` int(11) NOT NULL,
  `activa` tinyint(1) DEFAULT 1,
  `retroalimentacion` text DEFAULT NULL,
  `recursos_apoyo` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `progreso_leccion`
--

CREATE TABLE `progreso_leccion` (
  `id_progreso` int(11) NOT NULL,
  `id_inscripcion` int(11) NOT NULL,
  `id_leccion` int(11) NOT NULL,
  `completada` tinyint(1) DEFAULT 0,
  `fecha_inicio` datetime DEFAULT NULL,
  `fecha_completado` datetime DEFAULT NULL,
  `tiempo_invertido_minutos` int(11) DEFAULT 0,
  `numero_visitas` int(11) DEFAULT 0,
  `progreso_porcentaje` decimal(5,2) DEFAULT 0.00
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `reporte_institucional`
--

CREATE TABLE `reporte_institucional` (
  `id_reporte` int(11) NOT NULL,
  `id_institucion` int(11) NOT NULL,
  `id_usuario_solicitante` int(11) NOT NULL,
  `tipo_reporte` enum('progreso_estudiantes','uso_cursos','certificaciones','actividad') NOT NULL,
  `fecha_generacion` datetime DEFAULT current_timestamp(),
  `fecha_inicio_periodo` date NOT NULL,
  `fecha_fin_periodo` date NOT NULL,
  `archivo_generado` varchar(500) DEFAULT NULL,
  `parametros_reporte` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`parametros_reporte`)),
  `estado_reporte` enum('generando','completado','error') DEFAULT 'generando'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `respuesta_estudiante`
--

CREATE TABLE `respuesta_estudiante` (
  `id_respuesta` int(11) NOT NULL,
  `id_intento` int(11) NOT NULL,
  `id_pregunta` int(11) NOT NULL,
  `respuesta_texto` text DEFAULT NULL,
  `id_opcion_seleccionada` int(11) DEFAULT NULL,
  `puntaje_obtenido` decimal(5,2) DEFAULT 0.00,
  `es_correcta` tinyint(1) DEFAULT 0,
  `comentario_docente` text DEFAULT NULL,
  `fecha_respuesta` datetime DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `sesion_usuario`
--

CREATE TABLE `sesion_usuario` (
  `id_sesion` int(11) NOT NULL,
  `id_usuario` int(11) NOT NULL,
  `token_sesion` varchar(255) NOT NULL,
  `fecha_inicio` datetime DEFAULT current_timestamp(),
  `fecha_ultimo_acceso` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` text DEFAULT NULL,
  `activa` tinyint(1) DEFAULT 1,
  `fecha_cierre` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `soporte_ticket`
--

CREATE TABLE `soporte_ticket` (
  `id_ticket` int(11) NOT NULL,
  `id_usuario` int(11) NOT NULL,
  `asunto` varchar(255) NOT NULL,
  `descripcion` text NOT NULL,
  `categoria` enum('tecnico','academico','acceso','contenido','certificados') DEFAULT 'tecnico',
  `prioridad` enum('baja','media','alta','critica') DEFAULT 'media',
  `estado` enum('abierto','en_proceso','resuelto','cerrado') DEFAULT 'abierto',
  `fecha_creacion` datetime DEFAULT current_timestamp(),
  `fecha_resolucion` datetime DEFAULT NULL,
  `id_usuario_asignado` int(11) DEFAULT NULL,
  `respuesta_soporte` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `usuario`
--

CREATE TABLE `usuario` (
  `id_usuario` int(11) NOT NULL,
  `email` varchar(100) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `nombres` varchar(100) NOT NULL,
  `apellidos` varchar(100) NOT NULL,
  `documento_identidad` varchar(20) NOT NULL,
  `telefono` varchar(20) DEFAULT NULL,
  `fecha_nacimiento` date DEFAULT NULL,
  `tipo_usuario` enum('estudiante','docente','admin_institucional','admin_general') NOT NULL,
  `id_institucion` int(11) DEFAULT NULL,
  `fecha_registro` datetime DEFAULT current_timestamp(),
  `ultimo_acceso` datetime DEFAULT NULL,
  `activo` tinyint(1) DEFAULT 1,
  `token_recuperacion` varchar(255) DEFAULT NULL,
  `token_expiracion` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Usuarios del sistema: estudiantes, docentes y administradores';

--
-- Volcado de datos para la tabla `usuario`
--

INSERT INTO `usuario` (`id_usuario`, `email`, `password_hash`, `nombres`, `apellidos`, `documento_identidad`, `telefono`, `fecha_nacimiento`, `tipo_usuario`, `id_institucion`, `fecha_registro`, `ultimo_acceso`, `activo`, `token_recuperacion`, `token_expiracion`) VALUES
(1, 'admin@demo.com', 'pbkdf2:sha256:1000000$NRZmWixsPKeSUly4$90a25eaf384a43d7336dfa50239b203e9ed5c2326395d9046193f40ebaa47fb9', 'Administrador', 'General', '12345678', '', NULL, 'admin_general', NULL, '2025-05-23 00:56:46', '2025-06-04 22:44:01', 1, '', NULL),
(3, 'estudiante2@demo.com', '$2y$10$edAKaEhUO0VSweBDXeZqCeKABUj6DX5PmaW64wXVv.jo3JpBK4XbO', 'Estudiante', 'Prueba', '1047216677', '3028072004', '2004-11-02', 'estudiante', NULL, '2025-05-23 18:34:25', NULL, 1, NULL, NULL),
(4, 'estudiante3@demo.com', 'pbkdf2:sha256:1000000$WTHcMq62itU4qYYj$34725d9734df6f99aa406ebb621a03c84bfe218634b5f43492df711e8274e2d2', 'Estudiante', 'Prueba', '1047216673', '3028072004', '2013-10-16', 'estudiante', NULL, '2025-05-23 18:48:47', '2025-06-01 18:34:47', 1, NULL, NULL),
(6, 'estudiante@demo.com', 'pbkdf2:sha256:1000000$NRZmWixsPKeSUly4$90a25eaf384a43d7336dfa50239b203e9ed5c2326395d9046193f40ebaa47fb9', 'Prueba', 'Prueba', '1047216674', NULL, NULL, 'estudiante', NULL, '2025-05-29 16:02:50', '2025-06-02 21:07:19', 1, NULL, NULL),
(7, 'prueba1@gmail.com', 'pbkdf2:sha256:1000000$q9yr2G2hUpK9Wcj5$22f74b65509719576b045e752917d500ba2487f7c9a2e6dd900d55897c663e70', 'Estudiante', 'prueba', '1047216675', NULL, NULL, 'estudiante', NULL, '2025-05-29 17:04:01', '2025-05-30 16:43:42', 0, NULL, NULL),
(8, 'admin2@demo.com', 'pbkdf2:sha256:1000000$zP2fTzDxDgFDzmLh$001c1a73c9d07b6c4d8d4c51554fae94bd331f56a2249a03fcd344ee601a7cef', 'Admin', 'Prueba', '10472165874', NULL, NULL, 'admin_institucional', NULL, '2025-06-01 21:00:11', NULL, 1, NULL, NULL),
(9, 'docente@demo.com', 'pbkdf2:sha256:1000000$AK4MSZ3HdkZRFmxA$dcd43f3ad651335f97d7d5cbe01d63a182ab8b41389190c8823729952ddfbe6f', 'Admin', 'Prueba', '25669845', '3214587968', '2015-07-02', 'docente', NULL, '2025-06-02 08:16:21', NULL, 1, NULL, NULL),
(10, 'estudiante5@demo.com', 'pbkdf2:sha256:1000000$qbKIR94Po3mcQeKn$3f263d4c9b895b2a70306231a9964c92c8455720aa402d7f104b8ada5775c76a', 'Prueba', 'Apellido', '123456789568', NULL, NULL, 'estudiante', NULL, '2025-06-04 22:19:37', '2025-06-04 22:19:57', 0, NULL, NULL),
(11, 'docente3@demo.com', 'pbkdf2:sha256:1000000$OgJb36JdBbvbOM9r$c65adc3501728e8e206e9f884dc79d417c05e60992fd654294c956a725157bdf', 'Docente', 'Docente', '4567894', NULL, NULL, 'docente', NULL, '2025-06-04 22:44:57', NULL, 0, NULL, NULL);

--
-- Disparadores `usuario`
--
DELIMITER $$
CREATE TRIGGER `tr_usuario_audit_insert` AFTER INSERT ON `usuario` FOR EACH ROW BEGIN
    INSERT INTO AUDITORIA (id_usuario, tabla_afectada, accion, datos_nuevos, descripcion_accion)
    VALUES (NEW.id_usuario, 'USUARIO', 'INSERT', 
            JSON_OBJECT('id_usuario', NEW.id_usuario, 'email', NEW.email, 'tipo_usuario', NEW.tipo_usuario),
            CONCAT('Usuario creado: ', NEW.nombres, ' ', NEW.apellidos));
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `tr_usuario_audit_update` AFTER UPDATE ON `usuario` FOR EACH ROW BEGIN
    INSERT INTO AUDITORIA (id_usuario, tabla_afectada, accion, datos_anteriores, datos_nuevos, descripcion_accion)
    VALUES (NEW.id_usuario, 'USUARIO', 'UPDATE',
            JSON_OBJECT('email', OLD.email, 'activo', OLD.activo, 'ultimo_acceso', OLD.ultimo_acceso),
            JSON_OBJECT('email', NEW.email, 'activo', NEW.activo, 'ultimo_acceso', NEW.ultimo_acceso),
            CONCAT('Usuario actualizado: ', NEW.nombres, ' ', NEW.apellidos));
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura Stand-in para la vista `v_actividad_instituciones`
-- (Véase abajo para la vista actual)
--
CREATE TABLE `v_actividad_instituciones` (
`id_institucion` int(11)
,`nombre_institucion` varchar(255)
,`ciudad` varchar(100)
,`departamento` varchar(100)
,`total_usuarios` bigint(21)
,`estudiantes` bigint(21)
,`docentes` bigint(21)
,`total_inscripciones` bigint(21)
,`inscripciones_completadas` bigint(21)
,`certificados_emitidos` bigint(21)
);

-- --------------------------------------------------------

--
-- Estructura Stand-in para la vista `v_estadisticas_cursos`
-- (Véase abajo para la vista actual)
--
CREATE TABLE `v_estadisticas_cursos` (
`id_curso` int(11)
,`titulo` varchar(255)
,`categoria` varchar(100)
,`nivel_dificultad` enum('basico','intermedio','avanzado')
,`total_inscripciones` bigint(21)
,`completadas` bigint(21)
,`activas` bigint(21)
,`progreso_promedio` decimal(9,6)
,`calificacion_promedio` decimal(9,6)
,`certificados_emitidos` bigint(21)
);

-- --------------------------------------------------------

--
-- Estructura Stand-in para la vista `v_progreso_estudiantes`
-- (Véase abajo para la vista actual)
--
CREATE TABLE `v_progreso_estudiantes` (
`id_usuario` int(11)
,`nombres` varchar(100)
,`apellidos` varchar(100)
,`email` varchar(100)
,`nombre_institucion` varchar(255)
,`curso_titulo` varchar(255)
,`fecha_inscripcion` datetime
,`estado_inscripcion` enum('activa','completada','abandonada','suspendida')
,`progreso_porcentaje` decimal(5,2)
,`calificacion_final` decimal(5,2)
,`fecha_completado` datetime
,`tiempo_total_invertido_minutos` int(11)
);

-- --------------------------------------------------------

--
-- Estructura Stand-in para la vista `v_rendimiento_evaluaciones`
-- (Véase abajo para la vista actual)
--
CREATE TABLE `v_rendimiento_evaluaciones` (
`id_evaluacion` int(11)
,`evaluacion_titulo` varchar(255)
,`curso_titulo` varchar(255)
,`total_intentos` bigint(21)
,`intentos_aprobados` bigint(21)
,`puntaje_promedio` decimal(9,6)
,`puntaje_minimo` decimal(5,2)
,`puntaje_maximo` decimal(5,2)
,`tiempo_promedio_minutos` decimal(24,4)
);

-- --------------------------------------------------------

--
-- Estructura para la vista `v_actividad_instituciones`
--
DROP TABLE IF EXISTS `v_actividad_instituciones`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_actividad_instituciones`  AS SELECT `i`.`id_institucion` AS `id_institucion`, `i`.`nombre_institucion` AS `nombre_institucion`, `i`.`ciudad` AS `ciudad`, `i`.`departamento` AS `departamento`, count(distinct `u`.`id_usuario`) AS `total_usuarios`, count(distinct case when `u`.`tipo_usuario` = 'estudiante' then `u`.`id_usuario` end) AS `estudiantes`, count(distinct case when `u`.`tipo_usuario` = 'docente' then `u`.`id_usuario` end) AS `docentes`, count(distinct `ic`.`id_inscripcion`) AS `total_inscripciones`, count(distinct case when `ic`.`estado_inscripcion` = 'completada' then `ic`.`id_inscripcion` end) AS `inscripciones_completadas`, count(distinct `cert`.`id_certificado`) AS `certificados_emitidos` FROM (((`institucion` `i` left join `usuario` `u` on(`i`.`id_institucion` = `u`.`id_institucion` and `u`.`activo` = 1)) left join `inscripcion_curso` `ic` on(`u`.`id_usuario` = `ic`.`id_usuario`)) left join `certificado` `cert` on(`ic`.`id_inscripcion` = `cert`.`id_inscripcion`)) WHERE `i`.`activo` = 1 GROUP BY `i`.`id_institucion`, `i`.`nombre_institucion`, `i`.`ciudad`, `i`.`departamento` ;

-- --------------------------------------------------------

--
-- Estructura para la vista `v_estadisticas_cursos`
--
DROP TABLE IF EXISTS `v_estadisticas_cursos`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_estadisticas_cursos`  AS SELECT `c`.`id_curso` AS `id_curso`, `c`.`titulo` AS `titulo`, `c`.`categoria` AS `categoria`, `c`.`nivel_dificultad` AS `nivel_dificultad`, count(`ic`.`id_inscripcion`) AS `total_inscripciones`, count(case when `ic`.`estado_inscripcion` = 'completada' then 1 end) AS `completadas`, count(case when `ic`.`estado_inscripcion` = 'activa' then 1 end) AS `activas`, avg(`ic`.`progreso_porcentaje`) AS `progreso_promedio`, avg(`ic`.`calificacion_final`) AS `calificacion_promedio`, count(distinct `cert`.`id_certificado`) AS `certificados_emitidos` FROM ((`curso` `c` left join `inscripcion_curso` `ic` on(`c`.`id_curso` = `ic`.`id_curso`)) left join `certificado` `cert` on(`ic`.`id_inscripcion` = `cert`.`id_inscripcion`)) WHERE `c`.`activo` = 1 GROUP BY `c`.`id_curso`, `c`.`titulo`, `c`.`categoria`, `c`.`nivel_dificultad` ;

-- --------------------------------------------------------

--
-- Estructura para la vista `v_progreso_estudiantes`
--
DROP TABLE IF EXISTS `v_progreso_estudiantes`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_progreso_estudiantes`  AS SELECT `u`.`id_usuario` AS `id_usuario`, `u`.`nombres` AS `nombres`, `u`.`apellidos` AS `apellidos`, `u`.`email` AS `email`, `i`.`nombre_institucion` AS `nombre_institucion`, `c`.`titulo` AS `curso_titulo`, `ic`.`fecha_inscripcion` AS `fecha_inscripcion`, `ic`.`estado_inscripcion` AS `estado_inscripcion`, `ic`.`progreso_porcentaje` AS `progreso_porcentaje`, `ic`.`calificacion_final` AS `calificacion_final`, `ic`.`fecha_completado` AS `fecha_completado`, `ic`.`tiempo_total_invertido_minutos` AS `tiempo_total_invertido_minutos` FROM (((`usuario` `u` join `institucion` `i` on(`u`.`id_institucion` = `i`.`id_institucion`)) join `inscripcion_curso` `ic` on(`u`.`id_usuario` = `ic`.`id_usuario`)) join `curso` `c` on(`ic`.`id_curso` = `c`.`id_curso`)) WHERE `u`.`tipo_usuario` = 'estudiante' AND `u`.`activo` = 1 ;

-- --------------------------------------------------------

--
-- Estructura para la vista `v_rendimiento_evaluaciones`
--
DROP TABLE IF EXISTS `v_rendimiento_evaluaciones`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_rendimiento_evaluaciones`  AS SELECT `e`.`id_evaluacion` AS `id_evaluacion`, `e`.`titulo` AS `evaluacion_titulo`, `c`.`titulo` AS `curso_titulo`, count(`ie`.`id_intento`) AS `total_intentos`, count(case when `ie`.`aprobado` = 1 then 1 end) AS `intentos_aprobados`, avg(`ie`.`puntaje_obtenido`) AS `puntaje_promedio`, min(`ie`.`puntaje_obtenido`) AS `puntaje_minimo`, max(`ie`.`puntaje_obtenido`) AS `puntaje_maximo`, avg(timestampdiff(MINUTE,`ie`.`fecha_inicio`,`ie`.`fecha_envio`)) AS `tiempo_promedio_minutos` FROM ((`evaluacion` `e` join `curso` `c` on(`e`.`id_curso` = `c`.`id_curso`)) left join `intento_evaluacion` `ie` on(`e`.`id_evaluacion` = `ie`.`id_evaluacion`)) WHERE `e`.`activa` = 1 GROUP BY `e`.`id_evaluacion`, `e`.`titulo`, `c`.`titulo` ;

--
-- Índices para tablas volcadas
--

--
-- Indices de la tabla `auditoria`
--
ALTER TABLE `auditoria`
  ADD PRIMARY KEY (`id_auditoria`),
  ADD KEY `idx_auditoria_usuario` (`id_usuario`),
  ADD KEY `idx_auditoria_tabla` (`tabla_afectada`),
  ADD KEY `idx_auditoria_accion` (`accion`),
  ADD KEY `idx_auditoria_fecha` (`fecha_accion`),
  ADD KEY `idx_auditoria_fecha_tabla` (`fecha_accion`,`tabla_afectada`);

--
-- Indices de la tabla `certificado`
--
ALTER TABLE `certificado`
  ADD PRIMARY KEY (`id_certificado`),
  ADD UNIQUE KEY `codigo_verificacion` (`codigo_verificacion`),
  ADD KEY `idx_certificado_codigo` (`codigo_verificacion`),
  ADD KEY `idx_certificado_inscripcion` (`id_inscripcion`),
  ADD KEY `idx_certificado_fecha` (`fecha_emision`),
  ADD KEY `idx_certificado_activo` (`activo`);

--
-- Indices de la tabla `configuracion_sistema`
--
ALTER TABLE `configuracion_sistema`
  ADD PRIMARY KEY (`id_configuracion`),
  ADD UNIQUE KEY `clave_configuracion` (`clave_configuracion`),
  ADD KEY `id_usuario_modificacion` (`id_usuario_modificacion`),
  ADD KEY `idx_config_clave` (`clave_configuracion`),
  ADD KEY `idx_config_modificable` (`modificable_usuario`);

--
-- Indices de la tabla `curso`
--
ALTER TABLE `curso`
  ADD PRIMARY KEY (`id_curso`),
  ADD KEY `idx_curso_activo` (`activo`),
  ADD KEY `idx_curso_categoria` (`categoria`),
  ADD KEY `idx_curso_nivel` (`nivel_dificultad`),
  ADD KEY `idx_curso_creador` (`id_creador`),
  ADD KEY `idx_curso_categoria_activo` (`categoria`,`activo`);
ALTER TABLE `curso` ADD FULLTEXT KEY `idx_curso_busqueda` (`titulo`,`descripcion`);

--
-- Indices de la tabla `curso_institucion`
--
ALTER TABLE `curso_institucion`
  ADD PRIMARY KEY (`id_asignacion`),
  ADD UNIQUE KEY `uk_curso_institucion` (`id_curso`,`id_institucion`),
  ADD KEY `idx_asignacion_curso` (`id_curso`),
  ADD KEY `idx_asignacion_institucion` (`id_institucion`),
  ADD KEY `idx_asignacion_activo` (`activo`),
  ADD KEY `idx_asignacion_vencimiento` (`fecha_vencimiento`);

--
-- Indices de la tabla `evaluacion`
--
ALTER TABLE `evaluacion`
  ADD PRIMARY KEY (`id_evaluacion`),
  ADD KEY `idx_evaluacion_curso` (`id_curso`),
  ADD KEY `idx_evaluacion_modulo` (`id_modulo`),
  ADD KEY `idx_evaluacion_tipo` (`tipo_evaluacion`),
  ADD KEY `idx_evaluacion_activa` (`activa`);

--
-- Indices de la tabla `inscripcion_curso`
--
ALTER TABLE `inscripcion_curso`
  ADD PRIMARY KEY (`id_inscripcion`),
  ADD UNIQUE KEY `uk_inscripcion_usuario_curso` (`id_usuario`,`id_curso`),
  ADD KEY `idx_inscripcion_usuario` (`id_usuario`),
  ADD KEY `idx_inscripcion_curso` (`id_curso`),
  ADD KEY `idx_inscripcion_estado` (`estado_inscripcion`),
  ADD KEY `idx_inscripcion_fecha` (`fecha_inscripcion`),
  ADD KEY `idx_inscripcion_estado_progreso` (`estado_inscripcion`,`progreso_porcentaje`);

--
-- Indices de la tabla `institucion`
--
ALTER TABLE `institucion`
  ADD PRIMARY KEY (`id_institucion`),
  ADD UNIQUE KEY `nit` (`nit`),
  ADD UNIQUE KEY `email_institucional` (`email_institucional`),
  ADD KEY `idx_institucion_activo` (`activo`),
  ADD KEY `idx_institucion_ciudad` (`ciudad`),
  ADD KEY `idx_institucion_departamento` (`departamento`);

--
-- Indices de la tabla `intento_evaluacion`
--
ALTER TABLE `intento_evaluacion`
  ADD PRIMARY KEY (`id_intento`),
  ADD UNIQUE KEY `uk_intento_inscripcion_evaluacion_numero` (`id_inscripcion`,`id_evaluacion`,`numero_intento`),
  ADD KEY `idx_intento_inscripcion` (`id_inscripcion`),
  ADD KEY `idx_intento_evaluacion` (`id_evaluacion`),
  ADD KEY `idx_intento_estado` (`estado_intento`),
  ADD KEY `idx_intento_aprobado` (`aprobado`),
  ADD KEY `idx_intento_fecha_estado` (`fecha_envio`,`estado_intento`);

--
-- Indices de la tabla `leccion`
--
ALTER TABLE `leccion`
  ADD PRIMARY KEY (`id_leccion`),
  ADD UNIQUE KEY `uk_leccion_orden` (`id_modulo`,`orden_leccion`),
  ADD KEY `idx_leccion_modulo` (`id_modulo`),
  ADD KEY `idx_leccion_tipo` (`tipo_contenido`),
  ADD KEY `idx_leccion_activa` (`activa`);

--
-- Indices de la tabla `modulo`
--
ALTER TABLE `modulo`
  ADD PRIMARY KEY (`id_modulo`),
  ADD UNIQUE KEY `uk_modulo_orden` (`id_curso`,`orden_modulo`),
  ADD KEY `idx_modulo_curso` (`id_curso`),
  ADD KEY `idx_modulo_activo` (`activo`);

--
-- Indices de la tabla `notificacion`
--
ALTER TABLE `notificacion`
  ADD PRIMARY KEY (`id_notificacion`),
  ADD KEY `idx_notificacion_usuario` (`id_usuario_destinatario`),
  ADD KEY `idx_notificacion_leida` (`leida`),
  ADD KEY `idx_notificacion_tipo` (`tipo_notificacion`),
  ADD KEY `idx_notificacion_fecha` (`fecha_creacion`),
  ADD KEY `idx_notificacion_prioridad` (`prioridad`),
  ADD KEY `idx_notificacion_usuario_leida` (`id_usuario_destinatario`,`leida`);

--
-- Indices de la tabla `opcion_respuesta`
--
ALTER TABLE `opcion_respuesta`
  ADD PRIMARY KEY (`id_opcion`),
  ADD UNIQUE KEY `uk_opcion_orden` (`id_pregunta`,`orden_opcion`),
  ADD KEY `idx_opcion_pregunta` (`id_pregunta`),
  ADD KEY `idx_opcion_correcta` (`es_correcta`);

--
-- Indices de la tabla `pregunta`
--
ALTER TABLE `pregunta`
  ADD PRIMARY KEY (`id_pregunta`),
  ADD UNIQUE KEY `uk_pregunta_orden` (`id_evaluacion`,`orden_pregunta`),
  ADD KEY `idx_pregunta_evaluacion` (`id_evaluacion`),
  ADD KEY `idx_pregunta_tipo` (`tipo_pregunta`),
  ADD KEY `idx_pregunta_activa` (`activa`);

--
-- Indices de la tabla `progreso_leccion`
--
ALTER TABLE `progreso_leccion`
  ADD PRIMARY KEY (`id_progreso`),
  ADD UNIQUE KEY `uk_progreso_inscripcion_leccion` (`id_inscripcion`,`id_leccion`),
  ADD KEY `idx_progreso_inscripcion` (`id_inscripcion`),
  ADD KEY `idx_progreso_leccion` (`id_leccion`),
  ADD KEY `idx_progreso_completada` (`completada`),
  ADD KEY `idx_progreso_completada_fecha` (`completada`,`fecha_completado`);

--
-- Indices de la tabla `reporte_institucional`
--
ALTER TABLE `reporte_institucional`
  ADD PRIMARY KEY (`id_reporte`),
  ADD KEY `idx_reporte_institucion` (`id_institucion`),
  ADD KEY `idx_reporte_solicitante` (`id_usuario_solicitante`),
  ADD KEY `idx_reporte_tipo` (`tipo_reporte`),
  ADD KEY `idx_reporte_fecha` (`fecha_generacion`),
  ADD KEY `idx_reporte_estado` (`estado_reporte`);

--
-- Indices de la tabla `respuesta_estudiante`
--
ALTER TABLE `respuesta_estudiante`
  ADD PRIMARY KEY (`id_respuesta`),
  ADD UNIQUE KEY `uk_respuesta_intento_pregunta` (`id_intento`,`id_pregunta`),
  ADD KEY `id_opcion_seleccionada` (`id_opcion_seleccionada`),
  ADD KEY `idx_respuesta_intento` (`id_intento`),
  ADD KEY `idx_respuesta_pregunta` (`id_pregunta`),
  ADD KEY `idx_respuesta_correcta` (`es_correcta`);

--
-- Indices de la tabla `sesion_usuario`
--
ALTER TABLE `sesion_usuario`
  ADD PRIMARY KEY (`id_sesion`),
  ADD UNIQUE KEY `token_sesion` (`token_sesion`),
  ADD KEY `idx_sesion_usuario` (`id_usuario`),
  ADD KEY `idx_sesion_token` (`token_sesion`),
  ADD KEY `idx_sesion_activa` (`activa`),
  ADD KEY `idx_sesion_ultimo_acceso` (`fecha_ultimo_acceso`);

--
-- Indices de la tabla `soporte_ticket`
--
ALTER TABLE `soporte_ticket`
  ADD PRIMARY KEY (`id_ticket`),
  ADD KEY `idx_ticket_usuario` (`id_usuario`),
  ADD KEY `idx_ticket_categoria` (`categoria`),
  ADD KEY `idx_ticket_prioridad` (`prioridad`),
  ADD KEY `idx_ticket_estado` (`estado`),
  ADD KEY `idx_ticket_fecha` (`fecha_creacion`),
  ADD KEY `idx_ticket_asignado` (`id_usuario_asignado`);

--
-- Indices de la tabla `usuario`
--
ALTER TABLE `usuario`
  ADD PRIMARY KEY (`id_usuario`),
  ADD UNIQUE KEY `email` (`email`),
  ADD UNIQUE KEY `documento_identidad` (`documento_identidad`),
  ADD KEY `idx_usuario_email` (`email`),
  ADD KEY `idx_usuario_tipo` (`tipo_usuario`),
  ADD KEY `idx_usuario_institucion` (`id_institucion`),
  ADD KEY `idx_usuario_activo` (`activo`),
  ADD KEY `idx_usuario_token` (`token_recuperacion`),
  ADD KEY `idx_usuario_tipo_activo` (`tipo_usuario`,`activo`);

--
-- AUTO_INCREMENT de las tablas volcadas
--

--
-- AUTO_INCREMENT de la tabla `auditoria`
--
ALTER TABLE `auditoria`
  MODIFY `id_auditoria` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=125;

--
-- AUTO_INCREMENT de la tabla `certificado`
--
ALTER TABLE `certificado`
  MODIFY `id_certificado` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `configuracion_sistema`
--
ALTER TABLE `configuracion_sistema`
  MODIFY `id_configuracion` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=11;

--
-- AUTO_INCREMENT de la tabla `curso`
--
ALTER TABLE `curso`
  MODIFY `id_curso` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=13;

--
-- AUTO_INCREMENT de la tabla `curso_institucion`
--
ALTER TABLE `curso_institucion`
  MODIFY `id_asignacion` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `evaluacion`
--
ALTER TABLE `evaluacion`
  MODIFY `id_evaluacion` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `inscripcion_curso`
--
ALTER TABLE `inscripcion_curso`
  MODIFY `id_inscripcion` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT de la tabla `institucion`
--
ALTER TABLE `institucion`
  MODIFY `id_institucion` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT de la tabla `intento_evaluacion`
--
ALTER TABLE `intento_evaluacion`
  MODIFY `id_intento` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `leccion`
--
ALTER TABLE `leccion`
  MODIFY `id_leccion` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `modulo`
--
ALTER TABLE `modulo`
  MODIFY `id_modulo` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `notificacion`
--
ALTER TABLE `notificacion`
  MODIFY `id_notificacion` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `opcion_respuesta`
--
ALTER TABLE `opcion_respuesta`
  MODIFY `id_opcion` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `pregunta`
--
ALTER TABLE `pregunta`
  MODIFY `id_pregunta` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `progreso_leccion`
--
ALTER TABLE `progreso_leccion`
  MODIFY `id_progreso` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `reporte_institucional`
--
ALTER TABLE `reporte_institucional`
  MODIFY `id_reporte` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `respuesta_estudiante`
--
ALTER TABLE `respuesta_estudiante`
  MODIFY `id_respuesta` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `sesion_usuario`
--
ALTER TABLE `sesion_usuario`
  MODIFY `id_sesion` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `soporte_ticket`
--
ALTER TABLE `soporte_ticket`
  MODIFY `id_ticket` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `usuario`
--
ALTER TABLE `usuario`
  MODIFY `id_usuario` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=12;

--
-- Restricciones para tablas volcadas
--

--
-- Filtros para la tabla `auditoria`
--
ALTER TABLE `auditoria`
  ADD CONSTRAINT `auditoria_ibfk_1` FOREIGN KEY (`id_usuario`) REFERENCES `usuario` (`id_usuario`) ON DELETE SET NULL;

--
-- Filtros para la tabla `certificado`
--
ALTER TABLE `certificado`
  ADD CONSTRAINT `certificado_ibfk_1` FOREIGN KEY (`id_inscripcion`) REFERENCES `inscripcion_curso` (`id_inscripcion`) ON DELETE CASCADE;

--
-- Filtros para la tabla `configuracion_sistema`
--
ALTER TABLE `configuracion_sistema`
  ADD CONSTRAINT `configuracion_sistema_ibfk_1` FOREIGN KEY (`id_usuario_modificacion`) REFERENCES `usuario` (`id_usuario`) ON DELETE SET NULL;

--
-- Filtros para la tabla `curso`
--
ALTER TABLE `curso`
  ADD CONSTRAINT `curso_ibfk_1` FOREIGN KEY (`id_creador`) REFERENCES `usuario` (`id_usuario`) ON DELETE SET NULL;

--
-- Filtros para la tabla `curso_institucion`
--
ALTER TABLE `curso_institucion`
  ADD CONSTRAINT `curso_institucion_ibfk_1` FOREIGN KEY (`id_curso`) REFERENCES `curso` (`id_curso`) ON DELETE CASCADE,
  ADD CONSTRAINT `curso_institucion_ibfk_2` FOREIGN KEY (`id_institucion`) REFERENCES `institucion` (`id_institucion`) ON DELETE CASCADE;

--
-- Filtros para la tabla `evaluacion`
--
ALTER TABLE `evaluacion`
  ADD CONSTRAINT `evaluacion_ibfk_1` FOREIGN KEY (`id_curso`) REFERENCES `curso` (`id_curso`) ON DELETE CASCADE,
  ADD CONSTRAINT `evaluacion_ibfk_2` FOREIGN KEY (`id_modulo`) REFERENCES `modulo` (`id_modulo`) ON DELETE CASCADE;

--
-- Filtros para la tabla `inscripcion_curso`
--
ALTER TABLE `inscripcion_curso`
  ADD CONSTRAINT `inscripcion_curso_ibfk_1` FOREIGN KEY (`id_usuario`) REFERENCES `usuario` (`id_usuario`) ON DELETE CASCADE,
  ADD CONSTRAINT `inscripcion_curso_ibfk_2` FOREIGN KEY (`id_curso`) REFERENCES `curso` (`id_curso`) ON DELETE CASCADE;

--
-- Filtros para la tabla `intento_evaluacion`
--
ALTER TABLE `intento_evaluacion`
  ADD CONSTRAINT `intento_evaluacion_ibfk_1` FOREIGN KEY (`id_inscripcion`) REFERENCES `inscripcion_curso` (`id_inscripcion`) ON DELETE CASCADE,
  ADD CONSTRAINT `intento_evaluacion_ibfk_2` FOREIGN KEY (`id_evaluacion`) REFERENCES `evaluacion` (`id_evaluacion`) ON DELETE CASCADE;

--
-- Filtros para la tabla `leccion`
--
ALTER TABLE `leccion`
  ADD CONSTRAINT `leccion_ibfk_1` FOREIGN KEY (`id_modulo`) REFERENCES `modulo` (`id_modulo`) ON DELETE CASCADE;

--
-- Filtros para la tabla `modulo`
--
ALTER TABLE `modulo`
  ADD CONSTRAINT `modulo_ibfk_1` FOREIGN KEY (`id_curso`) REFERENCES `curso` (`id_curso`) ON DELETE CASCADE;

--
-- Filtros para la tabla `notificacion`
--
ALTER TABLE `notificacion`
  ADD CONSTRAINT `notificacion_ibfk_1` FOREIGN KEY (`id_usuario_destinatario`) REFERENCES `usuario` (`id_usuario`) ON DELETE CASCADE;

--
-- Filtros para la tabla `opcion_respuesta`
--
ALTER TABLE `opcion_respuesta`
  ADD CONSTRAINT `opcion_respuesta_ibfk_1` FOREIGN KEY (`id_pregunta`) REFERENCES `pregunta` (`id_pregunta`) ON DELETE CASCADE;

--
-- Filtros para la tabla `pregunta`
--
ALTER TABLE `pregunta`
  ADD CONSTRAINT `pregunta_ibfk_1` FOREIGN KEY (`id_evaluacion`) REFERENCES `evaluacion` (`id_evaluacion`) ON DELETE CASCADE;

--
-- Filtros para la tabla `progreso_leccion`
--
ALTER TABLE `progreso_leccion`
  ADD CONSTRAINT `progreso_leccion_ibfk_1` FOREIGN KEY (`id_inscripcion`) REFERENCES `inscripcion_curso` (`id_inscripcion`) ON DELETE CASCADE,
  ADD CONSTRAINT `progreso_leccion_ibfk_2` FOREIGN KEY (`id_leccion`) REFERENCES `leccion` (`id_leccion`) ON DELETE CASCADE;

--
-- Filtros para la tabla `reporte_institucional`
--
ALTER TABLE `reporte_institucional`
  ADD CONSTRAINT `reporte_institucional_ibfk_1` FOREIGN KEY (`id_institucion`) REFERENCES `institucion` (`id_institucion`) ON DELETE CASCADE,
  ADD CONSTRAINT `reporte_institucional_ibfk_2` FOREIGN KEY (`id_usuario_solicitante`) REFERENCES `usuario` (`id_usuario`) ON DELETE CASCADE;

--
-- Filtros para la tabla `respuesta_estudiante`
--
ALTER TABLE `respuesta_estudiante`
  ADD CONSTRAINT `respuesta_estudiante_ibfk_1` FOREIGN KEY (`id_intento`) REFERENCES `intento_evaluacion` (`id_intento`) ON DELETE CASCADE,
  ADD CONSTRAINT `respuesta_estudiante_ibfk_2` FOREIGN KEY (`id_pregunta`) REFERENCES `pregunta` (`id_pregunta`) ON DELETE CASCADE,
  ADD CONSTRAINT `respuesta_estudiante_ibfk_3` FOREIGN KEY (`id_opcion_seleccionada`) REFERENCES `opcion_respuesta` (`id_opcion`) ON DELETE SET NULL;

--
-- Filtros para la tabla `sesion_usuario`
--
ALTER TABLE `sesion_usuario`
  ADD CONSTRAINT `sesion_usuario_ibfk_1` FOREIGN KEY (`id_usuario`) REFERENCES `usuario` (`id_usuario`) ON DELETE CASCADE;

--
-- Filtros para la tabla `soporte_ticket`
--
ALTER TABLE `soporte_ticket`
  ADD CONSTRAINT `soporte_ticket_ibfk_1` FOREIGN KEY (`id_usuario`) REFERENCES `usuario` (`id_usuario`) ON DELETE CASCADE,
  ADD CONSTRAINT `soporte_ticket_ibfk_2` FOREIGN KEY (`id_usuario_asignado`) REFERENCES `usuario` (`id_usuario`) ON DELETE SET NULL;

--
-- Filtros para la tabla `usuario`
--
ALTER TABLE `usuario`
  ADD CONSTRAINT `usuario_ibfk_1` FOREIGN KEY (`id_institucion`) REFERENCES `institucion` (`id_institucion`) ON DELETE SET NULL;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
