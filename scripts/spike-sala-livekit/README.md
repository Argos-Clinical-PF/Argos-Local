# Spike de la sala virtual (WP0 · ADR-041)

Valida, sin la app, lo que la Sala ARGOS necesita del navegador del profesional:

- el token HS256 con el formato de LiveKit que va a firmar el backend;
- la grabación del audio **por canal** (paciente / profesional) en chunks de 4 s decodificables, igual que `GrabacionSesion`;
- un JPEG del video del paciente cada 4 s;
- la reconexión: el paciente sale y vuelve, y su canal se reabre.

Dos Chrome con cámara y micrófono simulados entran a la misma sala. El script sale con código 1 si falla algún criterio.

```bash
# desde Argos-Local, con el LiveKit local levantado
docker compose up -d livekit
cd scripts/spike-sala-livekit
npm install
npm run spike

# contra el servidor de la EC2 (WP9)
LIVEKIT_URL=wss://rtc.argosclinical.online LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=... npm run spike
```

Requiere Google Chrome instalado (usa `channel: 'chrome'`).

**Hallazgo del spike:** el audio remoto tiene que estar conectado a un `<audio>` que lo reproduzca (`track.attach()`) antes de grabarlo con `MediaRecorder`. Sin eso, Chrome entrega chunks vacíos. Para reproducir el problema, agregá `&sinAudio=1` a la URL de `sala.html`.
