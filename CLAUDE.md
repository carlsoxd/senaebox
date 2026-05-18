# CLAUDE.md — Instrucciones para Claude Code

## ¿Qué es este proyecto?

**SenaeBox** es una capa de compatibilidad y seguridad para ejecutar el SENAE Browser (navegador oficial de la Aduana del Ecuador) en Linux. El SENAE Browser es una PortableApp basada en Firefox 41.0.2 (2015) con Flash 25 y Java 7, que solo existe para Windows. Este proyecto lo hace funcionar en Linux dentro de un sandbox seguro.

Lee el `README.md` para el contexto técnico completo antes de hacer cualquier cosa.

---

## Stack tecnológico

- **Wine 32-bit** (`WINEARCH=win32`) para ejecutar los binarios Windows del browser
- **Bubblewrap** para sandboxing del proceso Wine
- **mitmproxy** para proxy TLS en desarrollo (Go custom en producción)
- **seccomp-bpf** para filtrado de syscalls
- **Bash + Python** para scripts de setup y automatización
- **Fedora Linux** como plataforma de desarrollo y testing primaria

## Reglas críticas de desarrollo

1. **WINEARCH=win32 siempre.** El WINEPREFIX debe ser de 32 bits estricto. Nunca uses WoW64 ni prefijos de 64 bits. Los plugins NPAPI (Flash, Java) son de 32 bits y se rompen en prefijos de 64 bits.

2. **El WINEPREFIX va en** `~/.local/share/senaebox/wine` — nunca en `~/.wine` para no contaminar el Wine del sistema.

3. **Los JARs PKI deben copiarse a múltiples rutas.** El applet de firma del Ecuapass busca los archivos en `%AppData%\LocalLow\sg\openews\_[dominio]_[puerto]\`. Ver `README.md` sección Capa 1 para la lista completa de dominios.

4. **Verificación SHA-256 antes de instalar.** Cualquier script que instale `jre715.exe` o los binarios del SENAE Browser debe verificar el hash SHA-256 primero. Mitigación contra ataques de supply chain.

5. **No modificar los binarios del SENAE Browser.** SenaeBox trabaja alrededor del browser, no dentro de él. Nada de parchear `.exe` ni `.dll`.

6. **Bubblewrap con `--unshare-net`.** El proceso Wine nunca accede a la red directamente. Todo el tráfico pasa por el proxy TLS local.

---

## Estructura del repositorio

```
senaebox/
├── CLAUDE.md              ← este archivo
├── README.md              ← documento base del proyecto (arquitectura completa)
├── setup.sh               ← script de instalación principal
├── launch.sh              ← script de lanzamiento del browser
├── scripts/
│   ├── create_wineprefix.sh    ← crea y configura el WINEPREFIX de 32 bits
│   ├── install_java.sh         ← instala JRE 7u15 en el prefijo Wine
│   ├── setup_pki.sh            ← copia JARs PKI a todas las rutas correctas
│   └── verify_hashes.sh        ← verifica SHA-256 de instaladores
├── proxy/
│   └── tls_proxy.py            ← proxy TLS con mitmproxy (desarrollo)
├── sandbox/
│   └── bwrap_launch.sh         ← configuración de Bubblewrap
└── pki/
    ├── sgapplet.jar
    ├── ewscommon.jar
    ├── xmlsecurity_client_api-1.0.jar
    └── xmlsecurity_applet_file-1.0.jar
```

---

## Fase actual: Fase 2 — Prueba de concepto Wine

### Objetivo de esta fase

Lograr que `SENAE_browser.exe` arranque dentro de Wine 32-bit en Fedora, con Flash y Java funcionando, y los JARs PKI en las rutas correctas.

### Tareas de esta fase en orden

1. Crear script `scripts/create_wineprefix.sh` que:
   - Verifique que Wine está instalado con soporte 32-bit (`wine --version`)
   - Cree el WINEPREFIX con `WINEARCH=win32`
   - Configure Wine para Windows 7 (`winetricks win7`)
   - Instale dependencias básicas via winetricks: `vcrun2013` (MSVC 2013 runtime)

2. Crear script `scripts/install_java.sh` que:
   - Verifique el SHA-256 de `jre715.exe` antes de instalarlo
   - Lo instale silenciosamente dentro del WINEPREFIX: `wine jre715.exe /s`
   - Verifique que `npjp2.dll` quedó registrado en el prefijo

3. Crear script `scripts/setup_pki.sh` que:
   - Cree todas las rutas `AppData\LocalLow\sg\openews\_[dominio]_[puerto]\`
   - Copie los 4 JARs a cada ruta
   - Lista completa de dominios en README.md sección Capa 1

4. Crear script `launch.sh` que:
   - Verifique que el WINEPREFIX existe y está configurado
   - Lance `SENAE_browser.exe` dentro de Wine (sin Bubblewrap aún en esta fase)
   - Capture stderr de Wine a un archivo de log para debugging

### Qué NO hacer en esta fase
- No implementar Bubblewrap todavía (eso es Fase 3)
- No implementar el proxy TLS todavía (eso es Fase 4)
- No implementar seccomp-bpf todavía (eso es Fase 5)

---

## Contexto sobre el usuario (Luis)

- **OS:** Fedora Linux
- **Hardware:** HP EliteBook 840 G8, Intel Core i7 11th gen, 16GB RAM
- **Rol en el proyecto:** Tester e informante — ejecuta los scripts y reporta resultados
- **No es desarrollador** — los scripts deben ser lo más simples y con comentarios claros
- **Acceso real al Ecuapass** — puede probar el flujo completo de firma en producción

---

## Notas de auditoría (Gemini, 15/05/2026)

- Arquitectura Wine aprobada ✅
- WINEARCH=win32 obligatorio confirmado ✅
- Estrategia proxy: mitmproxy en desarrollo, Go en producción ✅
- Verificación SHA-256 requerida antes de instalar binarios ✅
- Si en pruebas aparece token USB físico: añadir pcscd socket al sandbox

---

## Threat model — riesgos aceptados (auditoría Senior, 18/05/2026)

El sandbox de SenaeBox usa bubblewrap con namespace de red aislado y un proxy
TLS que intercepta todo el tráfico. Las siguientes superficies de ataque son
**riesgos aceptados** por restricciones técnicas de la pila, no descuidos. Si
en el futuro se ataca alguna, considerar las mitigaciones listadas.

### Riesgo aceptado #1 — Acceso al socket X11 del host

**Qué**: el sandbox monta `$X11_SOCKET` (típicamente `/tmp/.X11-unix/X0`) como
read-only para que Wine pueda renderizar ventanas en el escritorio del host.

**Implicación**: cualquier código dentro del sandbox (exploit de Flash, Java,
Firefox 41) tiene acceso al X server del usuario y puede:
- Keylogging (`XGrabKeyboard` / `XQueryKeymap`) — todas las teclas del host
- Screen capture (`XGetImage`) de cualquier ventana
- Input injection (`XTestFakeKeyEvent`) — inyectar en cualquier app del host
- Clipboard exfiltration vía X11 selections

**Por qué se acepta**: Wine no soporta Wayland nativo de forma estable en la
versión 8.0-staging que usamos. Las alternativas (Xpra/xpra-ng/Xephyr) añaden
latencia y complejidad, y rompen aspectos del rendering de Flash. El modelo
de amenaza realista: si Ecuapass (servidor de gobierno) sirve un SWF malicioso
firmado por su propia CA, ya tenemos un problema mayor que cualquier sandbox
puede mitigar.

**Mitigación futura si se requiere**: investigar Xephyr corriendo dentro del
sandbox; Wine se conecta solo a ese X server anidado. Costo: ~50ms latencia
de input y posibles bugs de redraw bajo nuestro compositor básico.

### Riesgo aceptado #2 — IPC namespace compartido con el host

**Qué**: el sandbox **no** usa `--unshare-ipc`. El namespace System V IPC se
comparte con el resto de procesos del usuario.

**Implicación**: código dentro del sandbox puede:
- Enumerar segmentos shmem del host (`ipcs -m`)
- Adjuntarse a segmentos con permisos liberales (mode 0666)
- Inyectar mensajes en colas SysV
- Bloquear semáforos sistémicos (DoS local)

**Por qué se acepta**: Wine's `winex11.drv` usa MIT-SHM (`XShmPutImage`) para
renderizado rápido. Crea segmentos shmget() que el X server (en el namespace
IPC del host) tiene que adjuntar via `XShmAttach`. Con `--unshare-ipc`, esos
adjuntamientos fallan con BadAccess y el error handler de Wine en Firefox 41
no lo recupera → plugin-container crashea con `mozglue+0x25be int $3`.

GNOME moderno usa principalmente POSIX IPC y DBus, no SysV. La mayoría de
apps del host no exponen IPC SysV de forma explotable.

**Mitigación futura si se requiere**: investigar XShm con sockets Unix
(extensión MIT-SHM-FD) si Wine la implementa en versiones futuras. Mientras
tanto, documentar el riesgo y monitorear apps del host que usen SysV IPC.

---

## Decisiones de diseño documentadas (no cambiar sin razón)

- **`browser.zoom.full = true` + userContent.css `@-moz-document`**: zoom por
  sitio para dominios Ecuapass. Los SWF de Flash no se ven afectados por CSS
  zoom (NPAPI windowed plugin renderiza en XWindow propia, fuera del pipeline
  de Firefox). Ver [memoria](.claude/projects/-home-luis-senaebox/memory/project_flash_zoom_limitation.md).

- **`LogPixels` = `Xft.dpi` del sistema** (espejo, sin cálculo): Wine refleja
  exactamente el DPI que XWayland reporta. Cualquier compensación matemática
  rompe a alguna escala.

- **`xulstore.json` auto-parche en cada launch**: Wine devuelve MINMAXINFO
  defectuoso a Mutter; Firefox guarda tamaños tiny tras restaurar. Único fix
  estable: forzar `width≥1280`, `height≥720`, `sizemode=normal` antes de cada
  arranque.

- **`startupCache` invalidación condicional**: Firefox 41 cachea todo
  `chrome/` y solo lo invalida en cambio de BuildID. `launch.sh` borra el
  cache si algún archivo en `chrome/` es más nuevo, para que userChrome.css
  y userContent.css surtan efecto cuando se editan.
