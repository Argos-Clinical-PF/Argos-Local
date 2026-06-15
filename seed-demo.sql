-- ============================================================================
-- ARGOS — Datos de demo
-- Carga 3 pacientes con sesiones finalizadas y notas (firmadas / borrador / sin
-- nota) para el PRIMER profesional registrado, para que la demo se vea como un
-- producto real. Idempotente: si ya están, no hace nada.
--
-- Uso (con el stack local levantado):
--   docker exec -i argos-postgres psql -U argos_app -d argos_clinical < Argos-Local/seed-demo.sql
-- ============================================================================
DO $$
DECLARE
    prof         UUID := (SELECT id FROM profesionales ORDER BY creado_en LIMIT 1);
    prof_nombre  TEXT := COALESCE((SELECT nombre_completo FROM profesionales ORDER BY creado_en LIMIT 1), 'Profesional');
    p_girasol    UUID := gen_random_uuid();
    p_rio        UUID := gen_random_uuid();
    p_roble      UUID := gen_random_uuid();
    s1 UUID := gen_random_uuid();  -- Girasol · firmada
    s2 UUID := gen_random_uuid();  -- Girasol · borrador
    s3 UUID := gen_random_uuid();  -- Río · firmada
    s4 UUID := gen_random_uuid();  -- Río · sin nota
    s5 UUID := gen_random_uuid();  -- Roble · sin nota
    s6 UUID := gen_random_uuid();  -- Roble · agendada (próxima)
BEGIN
    IF prof IS NULL THEN
        RAISE NOTICE 'No hay ningún profesional. Registrate e iniciá sesión antes de correr el seed.';
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM pacientes WHERE alias IN ('Girasol', 'Río', 'Roble') AND profesional_id = prof) THEN
        RAISE NOTICE 'Los datos de demo ya están cargados. Nada que hacer.';
        RETURN;
    END IF;

    -- Pacientes
    INSERT INTO pacientes (id, profesional_id, alias, fecha_inicio, motivo_inicial, estado, total_sesiones, creado_en, actualizado_en) VALUES
        (p_girasol, prof, 'Girasol', CURRENT_DATE - 90, 'Ansiedad ante exámenes y dificultad para dormir.', 'ACTIVO', 2, now(), now()),
        (p_rio,     prof, 'Río',     CURRENT_DATE - 60, 'Duelo por pérdida familiar reciente.',            'ACTIVO', 2, now(), now()),
        (p_roble,   prof, 'Roble',   CURRENT_DATE - 30, 'Estrés laboral y conflictos de pareja.',          'ACTIVO', 2, now(), now());

    -- Sesiones finalizadas (+ 1 agendada próxima)
    INSERT INTO sesiones (id, profesional_id, paciente_id, fecha, hora_inicio, hora_fin, tipo, estado, consentimiento_en, finalizada_en, creado_en, actualizado_en) VALUES
        (s1, prof, p_girasol, CURRENT_DATE - 7, '10:00', '10:50', 'PRESENCIAL', 'FINALIZADA', now(), now(), now(), now()),
        (s2, prof, p_girasol, CURRENT_DATE - 1, '11:00', '11:50', 'VIRTUAL',    'FINALIZADA', now(), now(), now(), now()),
        (s3, prof, p_rio,     CURRENT_DATE - 5, '15:00', '15:50', 'PRESENCIAL', 'FINALIZADA', now(), now(), now(), now()),
        (s4, prof, p_rio,     CURRENT_DATE - 2, '16:00', '16:50', 'VIRTUAL',    'FINALIZADA', now(), now(), now(), now()),
        (s5, prof, p_roble,   CURRENT_DATE - 3, '09:00', '09:50', 'PRESENCIAL', 'FINALIZADA', now(), now(), now(), now());
    INSERT INTO sesiones (id, profesional_id, paciente_id, fecha, hora_inicio, hora_fin, tipo, estado, creado_en, actualizado_en) VALUES
        (s6, prof, p_roble,   CURRENT_DATE + 1, '17:00', '17:50', 'VIRTUAL',    'AGENDADA',   now(), now());

    -- Notas: s1 y s3 firmadas, s2 borrador (s4, s5 sin nota → documentación pendiente)
    INSERT INTO notas_clinicas (id, sesion_id, contenido_cifrado, template, firmada, firmada_en, profesional_nombre_snapshot, version, creado_en, actualizado_en) VALUES
        (gen_random_uuid(), s1,
         '{"motivo":"Seguimiento de cuadro de ansiedad.","desarrollo":"Se trabajaron técnicas de respiración y reestructuración cognitiva ante pensamientos anticipatorios.","observaciones":"Afecto angustiado al inicio, con mejor regulación hacia el cierre.","plan":"Practicar respiración diafragmática; registro de pensamientos automáticos."}',
         'ARGOS_4_SECCIONES', true, now(), prof_nombre, 1, now(), now()),
        (gen_random_uuid(), s3,
         '{"motivo":"Proceso de duelo.","desarrollo":"Se habilitó espacio para la expresión emocional y se validaron los sentimientos de pérdida.","observaciones":"Llanto sostenido; buena alianza terapéutica.","plan":"Continuar elaboración del duelo; explorar redes de apoyo."}',
         'ARGOS_4_SECCIONES', true, now(), prof_nombre, 1, now(), now());
    INSERT INTO notas_clinicas (id, sesion_id, contenido_cifrado, template, firmada, version, creado_en, actualizado_en) VALUES
        (gen_random_uuid(), s2,
         '{"motivo":"Dificultades de sueño.","desarrollo":"Borrador generado a partir de la transcripción; pendiente de revisión del profesional.","observaciones":"","plan":""}',
         'ARGOS_4_SECCIONES', false, 1, now(), now());

    RAISE NOTICE 'Datos de demo cargados para el profesional %.', prof_nombre;
END $$;
