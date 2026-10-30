# Servidor de Alento Reservas (Supabase)

La versión instalable (`pwa/`) usa Supabase cuando existe `servidor/config.json`. La demo (Artifact y plantilla multisector) sigue funcionando sin servidor, y con `?demo` al final de la dirección se abre la demo aunque haya servidor.

## Puesta en marcha (una vez por centro)

1. En supabase.com, crea un proyecto en una región de la UE.
2. **SQL Editor → New query**: pega entero `supabase.sql` y pulsa Run.
3. **Authentication → Sign In / Providers → Email**: desactiva «Confirm email» mientras se prueba. El correo que incluye Supabase gratis solo admite unos pocos emails por hora; para usarlo con clientes reales, configura un SMTP propio (Authentication → Emails → SMTP; Resend o Brevo tienen plan gratuito) y vuelve a activar la confirmación.
4. **Authentication → URL Configuration → Site URL**: `https://savaservicios2026.github.io/Alento-app/`.
5. Copia la Project URL y la anon/publishable key en `servidor/config.json`:
   ```json
   { "url": "https://xxxx.supabase.co", "key": "eyJ… o sb_publishable_…", "center": "alento" }
   ```
   Son públicas por diseño. Nunca pongas aquí la service_role/secret key.
6. `python3 build.py`, copia `pwa/` al repositorio de GitHub Pages, sube la versión de caché de `sw.js` y haz push.
7. Regístrate en la app y, en el SQL Editor, ejecuta la última línea de `supabase.sql` con tu email para pasar a ser recepción. Al entrar como recepción por primera vez se crean las clases de los próximos 14 días a partir del horario de ejemplo.

## Actualizaciones

Cuando cambie `supabase.sql`, vuelve a pegarlo entero en el SQL Editor y pulsa Run: no borra datos. La versión de la app que llama a funciones nuevas (por ejemplo `buy_plan` con código o `check_code`) necesita el SQL actualizado.

## Cómo está hecho

- Tablas con RLS activado y sin políticas: nadie las lee ni escribe directamente. Todo pasa por funciones `security definer` que comprueban quién llama (`hydrate`, `book_class`, `cancel_booking`, `buy_plan`, `push` y las `admin_*`).
- Reservas, lista de espera, devoluciones al bono y promoción automática se deciden en el servidor con la clase bloqueada (`for update`), así que dos personas no pueden coger la última plaza a la vez.
- Los socios no ven quién más está apuntado, solo cuántas plazas quedan.
- Multicentro: cada fila lleva `center_id`; el centro de cada app se fija en `config.json`.
- `centers.test_payments = true`: los pagos de la app son de prueba y suman clases. Ponlo a `false` cuando se conecte una pasarela real; mientras, recepción suma clases con «Añadir clases» en la ficha.
- La app consulta cambios cada 20 s y al volver a abrirla.
- En `cfg` se guardan también los Ajustes de Recepción: equipo (`staff`), bonos (`plans`, con `until` y `limit` para preventa), códigos (`codes`, ocultos a los socios), clases de prueba al registrarse (`trial`) y fecha de apertura (`open`, el horario empieza ese día).

## Pendiente

- Archivos adjuntos: de momento se guarda solo el nombre (falta Supabase Storage).
- Notificaciones push y recordatorios por email.
- Firma del QR en el servidor (ahora la clave va en la app).
