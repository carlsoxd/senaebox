// SenaeBox — Preferencias de compatibilidad con Wine (TEMPLATE)
//
// Este archivo se copia a <profile>/user.js durante setup_first_run.sh si el
// usuario no tiene ya un user.js. Firefox lee esto en cada arranque y fuerza
// las preferencias, incluso si fueron cambiadas en about:config.
//
// NO incluye las prefs `browser.download.*` — esas las añade setup_first_run.sh
// dinámicamente porque el path depende del nombre de usuario del sistema.
//
// Causa del problema base: Firefox 41 usa un compositor DXGI para renderizar.
// Wine no implementa dxgi_resource_GetSharedHandle, lo que provoca que el
// thread compositor (xul.dll:0185AD7E) crashee con STATUS_BREAKPOINT.
// Desactivar la aceleración de GPU fuerza el uso del compositor básico (CPU).

// Desactiva el compositor de GPU (causa directa del crash bajo Wine)
user_pref("layers.acceleration.disabled", true);
user_pref("layers.acceleration.force-disabled", true);

// Desactiva Direct2D (evita el path D2D que también usa DXGI internamente)
user_pref("gfx.direct2d.disabled", true);

// Desactiva D3D11 WARP (el rasterizador software de D3D11 que sigue usando DXGI)
user_pref("layers.d3d11.disable-warp", true);

// Desactiva la composición fuera del thread principal (el thread que crasheaba)
user_pref("layers.offmainthreadcomposition.enabled", false);

// --- Mitigación de "interfaces negras" del compositor básico ---
//
// Con todo el GPU compositing desactivado, Firefox usa el compositor básico
// single-threaded. Este compositor tiene problemas conocidos en Wine:
//   - Popups/dropdowns aparecen negros al primer despliegue
//   - Toolbars/tabs quedan negras tras minimizar/restaurar
//   - El screen no se actualiza si el main thread está procesando JS pesado
//
// Estas prefs reducen los síntomas forzando paints más agresivos:

// Sin demora antes del primer paint (default: 250 ms — causa flash negro inicial).
user_pref("nglayout.initialpaint.delay", 0);

// Sin canvas acelerado por GPU (azure es el backend de canvas — debe ir por CPU
// como el resto del compositor, si no causa inconsistencias de pintado).
user_pref("gfx.canvas.azure.accelerated", false);

// No descartar imágenes decodificadas de memoria. Sin esto, las imágenes del
// chrome (iconos de toolbar, favicons) se redibujan negras al primer paint
// tras estar fuera de viewport o tras un cambio de focus.
user_pref("image.mem.discardable", false);

// Sin animaciones de tabs — las transiciones animadas con compositor básico
// dejan trails y áreas sin repintar al terminar la animación.
user_pref("browser.tabs.animate", false);
user_pref("browser.fullscreen.animate", false);

// --- Mitigación adicional de WM_NCPAINT / WM_ERASEBKGND drops ---
//
// Cuando aparece un modal (diálogo nativo de Flash, popup, etc.) o cambia el
// tamaño de la ventana, Wine intenta empaquetar WM_NCPAINT y WM_ERASEBKGND
// para IPC entre hilos vía `pack_message`. `pack_message` no soporta esos
// mensajes → los drops dejan el chrome negro hasta que el cursor pasa por
// encima e invalida la región localmente. Estas prefs reducen la frecuencia
// de los mensajes problemáticos:

// Textura "deprecated" — pipeline GDI directo en vez de damage regions
// complejas del path nuevo. Más simple = menos paint events = menos IPC.
user_pref("layers.use-deprecated-textures", true);

// Component alpha (subpixel transparency para texto antialiasing) requiere
// dos buffers separados y un readback. Desactivar elimina ese roundtrip.
user_pref("layers.componentalpha.enabled", false);

// e10s (multi-proceso) sería catastrófico: cada paint pasa por IPC entre
// proceso main y content, todos los mensajes pasan por `pack_message`. En
// Firefox 41 e10s está OFF por defecto pero lo forzamos por seguridad.
user_pref("browser.tabs.remote.autostart",   false);
user_pref("browser.tabs.remote.autostart.2", false);

// Smooth scroll dispara N paints por scroll (animación). Cada paint puede
// fallar y dejar trails. Scroll discreto = 1 paint = limpio.
user_pref("general.smoothScroll", false);

// --- Tamaño de ventana al des-maximizar ---
//
// Cuando el usuario presiona el botón de maximizar mientras la ventana ya
// está maximizada, Mutter dispara SC_RESTORE. Firefox lee el tamaño anterior
// de xulstore.json. Si ese archivo se corrompió con valores tiny (porque Wine
// devolvió MINMAXINFO defectuoso en algún unmaximize previo), la ventana
// queda como una franja de botones.
//
// Estas prefs son el "default mínimo" que Firefox usa si xulstore.json no
// tiene un main-window válido. Funciona como segundo nivel de defensa al
// reparar xulstore.json directamente (ver _fix_xulstore_window_size en
// launch.sh).
user_pref("browser.window.width",  1280);
user_pref("browser.window.height", 720);

// --- HTML5 Fullscreen API desactivada ---
//
// Esto desactiva element.requestFullscreen() que invocan páginas web. NO
// desactiva el botón "Pantalla completa" del menú ni F11 (esos llaman a
// BrowserFullScreen() de XUL, que es código del chrome y no consulta esta
// pref). El bloqueo del fullscreen del chrome se hace vía userChrome.css
// en chrome/userChrome.css del perfil.
//
// El fullscreen de Flash (Stage.displayState="fullScreen") también es
// independiente — plugin-container.exe crea su propia ventana X11.
user_pref("full-screen-api.enabled", false);

// --- Sesión y crash recovery ---
// Firefox 41 guarda la sesión en recovery.js y la restaura si detecta un crash.
// Dentro del sandbox, la sesión siempre termina de forma "sucia" (el proceso Wine
// es terminado por bwrap, no por un cierre limpio de Firefox). Sin estas prefs,
// Firefox muestra "Bueno, esto es embarazoso" en cada arranque y reintenta
// restaurar las pestañas anteriores — incluyendo las que tenían Java/Flash,
// lo que dispara plugin-container y puede causar un segundo crash que cierra el browser.

// No mostrar la página de crash recovery. Arrancar siempre con sesión nueva.
user_pref("browser.sessionstore.resume_from_crash", false);

// Cero reintentos de restauración automática antes de mostrar el crash page.
user_pref("browser.sessionstore.max_resumed_crashes", 0);

// --- Escalado DPI: gestionado fuera de user.js ---
//
// El escalado se hace VÍA WINE LogPixels (registro, espejando el Xft.dpi del
// sistema — ver scripts/fix_wine_registry.sh). Firefox lee Wine LogPixels vía
// GetDeviceCaps(LOGPIXELSY) y escala chrome+content proporcionalmente.
//
// Estas prefs se mantienen en valores neutrales ("usar sistema") para evitar
// duplicar la escala — si pusiéramos devPixelsPerPx=1.25 aquí, se sumaría al
// scaling de Wine, dando 1.5625x o más.
user_pref("layout.css.devPixelsPerPx", "-1.0");   // -1.0 = leer del sistema (LogPixels de Wine)
user_pref("layout.css.dpi",            -1);       // -1  = leer del sistema
user_pref("ui.textScaleFactor",        100);      // 100 = sin override (chrome usa LogPixels)

// --- Hardening TLS ---
//
// Firefox 41 soporta hasta TLS 1.2. Los valores de security.tls.version.*
// son enums: 0=SSL3, 1=TLS1.0, 2=TLS1.1, 3=TLS1.2. (TLS 1.3 = 4 no existe
// en este Firefox.)
//
// min=3, max=3 → forzar exclusivamente TLS 1.2. Esto rechaza:
//   - SSLv3 (POODLE, CVE-2014-3566)
//   - TLS 1.0 (BEAST, CRIME, vulnerabilidades de RC4)
//   - TLS 1.1 (mismos problemas de hash MD5/SHA1 en signing)
//
// Riesgo aceptado: si Ecuapass o algún subdominio de aduana.gob.ec usa
// servidores con TLS antiguo (TLS 1.0/1.1), las conexiones fallarán con
// SSL_ERROR_NO_CYPHER_OVERLAP. Servidores de gobierno en 2026 deberían
// soportar TLS 1.2 — si no, reportar al equipo de SENAE para que actualicen.
user_pref("security.tls.version.min", 3);
user_pref("security.tls.version.max", 3);

// --- Proxy TLS (Fase 4) ---
// Con --unshare-net el sandbox no tiene red directa. Todo el tráfico HTTP/HTTPS
// pasa por socat (127.0.0.1:8080) → socket Unix → mitmproxy.
// network.proxy.type=1: proxy manual (no auto-detect, no PAC).
user_pref("network.proxy.type",      1);
user_pref("network.proxy.http",      "127.0.0.1");
user_pref("network.proxy.http_port", 8080);
user_pref("network.proxy.ssl",       "127.0.0.1");
user_pref("network.proxy.ssl_port",  8080);
// Sin excepciones: absolutamente todo pasa por el proxy (incluido localhost de Windows).
user_pref("network.proxy.no_proxies_on", "");

// --- Flash: "always activate" (2). Sin esto, prefs.js puede tener 0 (disabled) de runs
// anteriores de diagnóstico, y el browser muestra "instalar Adobe Flash" en Ecuapass.
user_pref("plugin.state.flash", 2);

// --- Watchdog IPC de plugins (causa del crash en ~60 s) ---
//
// Firefox 41 hace ping al IPC de plugin-container cada segundo.
// Si no hay respuesta en dom.ipc.plugins.timeoutSecs (default: 45 s), Firefox muestra
// el diálogo "Plugin no responde" y luego mata plugin-container.
//
// Por qué no responde: llvmpipe (renderizado por software, LIBGL_ALWAYS_SOFTWARE=1)
// bloquea el hilo principal de plugin-container durante renderizado pesado de Flash.
// El hilo IPC comparte el event loop con el hilo de renderizado en plugin-container.exe
// → durante el renderizado de un módulo BlazeDS+Flex, los pings IPC de Firefox
// quedan sin respuesta → Firefox dispara el watchdog a los 45 s → cierre limpio (código 0).
//
// -1 desactiva cada timer. Si plugin-container crashea de verdad (SIGSEGV),
// Firefox lo sigue detectando por la muerte del proceso — esto solo deshabilita
// el timeout por falta de respuesta al ping IPC.
user_pref("dom.ipc.plugins.timeoutSecs",       -1);
user_pref("dom.ipc.plugins.unloadTimeoutSecs", -1);
user_pref("dom.ipc.plugins.hangUITimeoutSecs", -1);

// Página de inicio: cargar la homepage en lugar de la página en blanco.
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "https://ecuapass.aduana.gob.ec");

// --- Zoom por sitio para Ecuapass ---
//
// Ecuapass tiene layout CSS de ancho fijo que no responde al DPI del sistema.
// Aunque Wine reporte LogPixels correcto, el contenido se ve chico. Solución:
// zoom por sitio del 125% para los dominios operativos.
//
// Estas prefs habilitan el mecanismo; los valores numéricos por dominio van en
// <profile>/chrome/userContent.css con @-moz-document (generado por
// scripts/configure_zoom.sh en cada launch).
user_pref("browser.zoom.siteSpecific", true);
user_pref("browser.zoom.full",         true);

// browser.download.* se añade dinámicamente por setup_first_run.sh
// (depende del nombre de usuario del sistema).
