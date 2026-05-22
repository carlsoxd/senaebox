# SenaeBox — Documento Base del Proyecto

> Contenedor seguro para el SENAE Browser en Linux  
> Estado: Fase de diseño arquitectónico — investigación completada  
> Última actualización: 15 de Mayo 2026

---

## 1. Contexto y Problema

### ¿Qué es el SENAE Browser?
El SENAE Browser es un navegador web personalizado desarrollado por la Aduana del Ecuador (SENAE) para acceder al portal **Ecuapass** (`portalinterno.aduana.gob.ec`). Es la puerta de entrada obligatoria para todos los trámites de importación, exportación y certificación aduanera del país.

### Base técnica del SENAE Browser
- **Nombre oficial:** SENAE Ecuaweb, Portable (AppID: `EcuawebPortable`)
- **Motor:** Firefox **41.0.2**, BuildID `20170629101550` (compilado junio 2017, motor de octubre 2015)
- **Tipo:** **PortableApp** empaquetada con el framework PortableApps.com — NO es un browser compilado desde cero
- **Ejecutable principal:** `SENAE_browser.exe` (503 KB)
- **Branding:** `SENAE_browser` / `Ecuaweb` — empresa: `aduana.gob.ec`
- **Sistema operativo objetivo:** Windows x86 (32-bit), probado en Windows 10 y Windows 7
- **Código fuente disponible:** Fork del repositorio Mozilla Release (`mozilla-release-es`)

> 🔑 **Descubrimiento clave:** Al ser una PortableApp con binarios `.exe` y `.dll` de Windows ya compilados, el enfoque correcto para Linux es ejecutar esos binarios mediante **Wine**, no compilar desde el código fuente. Esto simplifica enormemente la arquitectura.

### Dependencias críticas confirmadas
| Componente | Versión exacta | Archivo | Estado |
|---|---|---|---|
| Firefox | 41.0.2 | `SENAE_browser.exe` | EOL desde 2016 |
| Flash Player | **25.0.0.171** | `NPSWF32_25_0_0_171.dll` | EOL desde 2020, embebido en extensión `playflash@xpi` |
| Java Plugin | **JRE 7 Update 15** (10.15.2.3) | `npjp2.dll` en `C:\Program Files (x86)\Java\jre7` | EOL desde 2015 |
| Java Deploy | 7.0.150.3 | `npDeployJava1.dll` en `C:\WINDOWS\SysWOW64` | EOL |
| JRE instalador | **7.1.5** | `jre715.exe` (31MB, incluido en carpeta Installers) | EOL |
| XUL Runtime | 41.0.2 | `xul.dll` (35MB) | EOL |
| ICU (Unicode) | 52 | `icudt52.dll`, `icuin52.dll`, `icuuc52.dll` | Versión antigua |
| D3D Compiler | 43 / 47 | `D3DCompiler_43.dll`, `d3dcompiler_47.dll` | Solo relevante en Windows |
| NSS (crypto) | incluido | `nss3.dll`, `nssckbi.dll` | Versión antigua con CVEs conocidos |
| MSVC Runtime | 120 | `msvcp120.dll`, `msvcr120.dll` | Visual C++ 2013 |

### Configuración de plugins (hardcodeada en `firefox.js`)
```javascript
pref("plugin.state.flash", 2);          // Flash siempre activo, sin preguntar
pref("plugin.state.java", 2);           // Java siempre activo, sin preguntar
pref("plugin.state.npdeployjava", 2);   // Applet Ecuapass siempre activo
```

### Plugins adicionales detectados en entorno real (pluginreg.dat)
- **Microsoft SharePoint Plugin** (`NPSPWRAP.DLL`) — de Microsoft Office 16
- **Microsoft Lync Meeting Plugin** (`npMeetingJoinPluginOC.dll`) — de Office 16
- Estos son plugins del sistema Windows del usuario, no del SENAE Browser en sí

### Homepage configurada
```
http://portalinterno.aduana.gob.ec
https://www.aduana.gob.ec/
```

### El problema de seguridad
El SENAE Browser acumula aproximadamente **11 años de vulnerabilidades sin parchear**, incluyendo:
- Cientos de CVEs conocidos en Firefox 41
- Flash Player con historial masivo de vulnerabilidades críticas
- TLS sin restricciones (acepta TLS 1.0, SSL 3.0)
- Java NPAPI con ejecución irrestricta
- Sin sandbox moderno de procesos

**Impacto potencial:** Un ataque exitoso podría comprometer sesiones autenticadas de funcionarios del SENAE, permitiendo firmar documentos fraudulentamente, manipular trámites de importación/exportación y acceder a datos sensibles de empresas que operan con el Ecuapass. Sistemas regulatorios como el ARCSA también podrían verse afectados.

> ⚠️ **Contexto de amenaza actual (Mayo 2026):** El grupo TeamPCP está llevando ataques masivos de supply chain contra ecosistemas de desarrollo. La combinación de un browser con 9 años de CVEs sin parchear + Flash EOL + Java 7 EOL representa un vector de ataque de alta prioridad para actores maliciosos con capacidades crecientes.

### ¿Por qué no existe en Linux?
El SENAE Browser solo tiene instalador para Windows (`.exe` via NSIS). No existe versión oficial para Linux ni macOS. Los usuarios que necesitan operar el Ecuapass en Linux actualmente no tienen solución oficial.

---

## 2. Objetivo del Proyecto

Crear **SenaeBox**: una capa de compatibilidad y seguridad que permita:

1. **Ejecutar el SENAE Browser en Linux** de forma nativa
2. **Mitigar las vulnerabilidades** del stack tecnológico obsoleto mediante aislamiento y traducción de protocolos
3. **Distribuir la solución** como proyecto comunitario abierto para cualquier usuario Linux de Ecuador

> Analogía de diseño: Lo que Proton hace para juegos de Windows en Linux (capa de compatibilidad + traducción transparente), SenaeBox lo hace para el SENAE Browser (aislamiento + modernización de protocolos).

---

## 3. Arquitectura

### Visión general

```
[Usuario Linux]
      │
      ▼
[SenaeBox Launcher (script bash)]
      │
      ├──► [Capa 1: Wine + Bubblewrap]
      │         ├── SENAE_browser.exe (Firefox 41 portable)
      │         ├── NPSWF32_25_0_0_171.dll (Flash 25 via Wine)
      │         ├── npjp2.dll + JRE 7u15 (Java via Wine)
      │         └── JARs PKI mapeados a rutas Wine correctas
      │
      ├──► [Capa 2: Proxy TLS Local]
      │         └── Intercepta TLS 1.0 → reencamina como TLS 1.3
      │
      ├──► [Capa 3: Filtro Syscalls (seccomp-bpf)]
      │         └── Lista blanca de operaciones permitidas
      │
      └──► [Capa 4: Puente JAR / Firma Electrónica]
                └── JARs PKI mapeados al AppData de Wine
```

---

### Capa 1 — Wine + Contenedor (Bubblewrap)

**Herramientas:** [Wine](https://www.winehq.org/) + [Bubblewrap](https://github.com/containers/bubblewrap)  
**Propósito:** Ejecutar los binarios Windows del SENAE Browser en Linux de forma aislada.

**¿Por qué Wine y no compilar desde código fuente?**

El SENAE Browser es una **PortableApp**: un paquete de binarios `.exe` y `.dll` de Windows ya compilados. No hay necesidad ni ventaja en recompilar. Wine ejecuta esos binarios directamente en Linux, que es exactamente lo que Proton hace con los juegos de Windows.

**¿Por qué Bubblewrap además de Wine?**

Wine por sí solo da acceso al sistema de archivos del usuario. Bubblewrap envuelve Wine dentro de un sandbox, limitando qué puede ver y hacer el proceso.

**Estructura de archivos dentro del prefijo Wine:**

```
~/.local/share/senaebox/wine/        ← WINEPREFIX de SenaeBox
  └── drive_c/
        ├── Users/senaebox/
        │     ├── Documents/
        │     │     ├── SENAE browser/     ← carpeta PortableApp completa
        │     │     └── pki/               ← JARs de firma electrónica
        │     └── AppData/LocalLow/sg/openews/
        │           ├── _portalinterno.aduana.gob.ec_80_/   ← JARs copiados aquí
        │           ├── _portalinterno.aduana.gob.ec_443_/  ← JARs copiados aquí
        │           └── ... (resto de dominios del .bat)
        └── Program Files (x86)/Java/jre7/  ← JRE 7u15
```

**JARs de firma electrónica (carpeta `pki/`):**

Estos 4 archivos son el sistema de firma del Ecuapass. Deben copiarse a múltiples rutas dentro del AppData de Wine, exactamente como lo hace `copy_pki_dev_7_ecuapass_portal.bat`:

| Archivo JAR | Propósito |
|---|---|
| `sgapplet.jar` | Applet principal de firma electrónica |
| `ewscommon.jar` | Librería común del sistema |
| `xmlsecurity_client_api-1.0.jar` | API de seguridad XML para firma |
| `xmlsecurity_applet_file-1.0.jar` | Manejo de archivos firmados |

**Dominios a los que se deben copiar los JARs** (extraído del `.bat` oficial):
```
_portalinterno.aduana.gob.ec_80_
_portalinterno.aduana.gob.ec_443_
_portal.aduana.gob.ec_80_
_portal.aduana.gob.ec_443_
_ecuapass.aduana.gob.ec_80_
_ecuapass.aduana.gob.ec_443_
_portaltest.aduana.gob.ec_80_ / _443_
_ecuapasstest.aduana.gob.ec_80_ / _443_
... (y variantes _dev, _int)
```

**⚠️ WINEPREFIX obligatoriamente de 32 bits:**

Fedora crea prefijos Wine de 64 bits por defecto (WoW64), lo cual rompe los plugins NPAPI de 32 bits como `npjp2.dll`. El prefijo **debe** crearse como 32 bits estricto:

```bash
WINEARCH=win32 WINEPREFIX=~/.local/share/senaebox/wine winecfg
```

Esto debe ejecutarse una sola vez al configurar el entorno. Si el prefijo se crea como 64 bits primero, hay que eliminarlo y recrearlo — no hay forma de convertirlo después.

**Lanzamiento básico:**
```bash
WINEARCH=win32 WINEPREFIX=~/.local/share/senaebox/wine \
bwrap \
  --bind ~/.local/share/senaebox/wine /home/senaebox/.wine \
  --ro-bind /usr /usr \
  --proc /proc \
  --dev /dev \
  --unshare-net \        # Sin acceso directo a red (pasa por proxy TLS)
  wine "C:\\Users\\senaebox\\Documents\\SENAE browser\\SENAE_browser.exe"
```

---

### Capa 2 — Proxy TLS

**Herramienta:** mitmproxy o proxy custom en Go/Python  
**Propósito:** Modernizar las conexiones de red sin modificar el browser.

**Problema que resuelve:**
Firefox 41 ofrece TLS 1.0 a los servidores. Muchos servidores modernos rechazan esto o lo consideran inseguro. Además, las implementaciones TLS de 2015 tienen vulnerabilidades conocidas.

**Cómo funciona:**
```
Firefox 41 → [TLS 1.0] → Proxy local → [TLS 1.3] → portalinterno.aduana.gob.ec
```

El proxy genera un certificado local auto-firmado que Firefox 41 acepta, termina la conexión insegura internamente, y abre una nueva conexión moderna hacia el servidor real. Transparente para el usuario.

**Consideración importante:** Los certificados del portal de Aduana deben ser aceptados correctamente. Hay que investigar si usan certificados del Estado ecuatoriano con cadena de confianza propia.

---

### Capa 3 — Filtro de Syscalls (seccomp-bpf)

**Herramienta:** libseccomp  
**Propósito:** Limitar qué puede hacer el proceso en el kernel, incluso si es explotado.

**Lista blanca básica (a refinar):**

| Syscall | Permitida | Motivo |
|---|---|---|
| read, write | ✅ | Operación básica |
| open, close | ✅ | Acceso a archivos del sandbox |
| connect, send, recv | ✅ | Red (solo hacia proxy local) |
| execve | ❌ | No puede lanzar otros procesos |
| ptrace | ❌ | No puede inspeccionar otros procesos |
| mount | ❌ | No puede montar sistemas de archivos |
| setuid | ❌ | No puede escalar privilegios |

---

### Capa 4 — Puente de Firma Electrónica (JARs PKI)

**Propósito:** Garantizar que los JARs de firma del Ecuapass estén disponibles en las rutas correctas dentro del prefijo Wine.

**Cómo funciona la firma en el SENAE Browser:**

El applet de firma NO usa token USB físico (al menos no como mecanismo principal). Usa **applets Java** cargados desde archivos `.jar` que deben estar presentes en rutas específicas del `AppData` de Windows. El browser los busca en:

```
%AppData%\LocalLow\sg\openews\_[dominio]_[puerto]\
```

En Wine esto se traduce a:
```
~/.local/share/senaebox/wine/drive_c/users/senaebox/AppData/LocalLow/sg/openews/
```

**Script de setup PKI** (equivalente Linux del `copy_pki_dev_7_ecuapass_portal.bat`):

SenaeBox incluirá un script que al primer arranque copia automáticamente los JARs a todas las rutas necesarias dentro del prefijo Wine, eliminando el paso manual que actualmente hacen los usuarios Windows.

> ⚠️ **PENDIENTE:** Confirmar si adicionalmente se usa token USB físico (smartcard) para algún tipo de firma. De ser así, se necesitaría exponer el socket pcscd al contenedor Wine.

---

## 4. Stack Tecnológico

| Componente | Tecnología | Estado |
|---|---|---|
| Compatibilidad Windows | **Wine** (32-bit prefix) | Por implementar |
| Contenedor / Sandbox | **Bubblewrap** | Por implementar |
| Proxy TLS | mitmproxy / Go custom | Por decidir |
| Filtro syscalls | seccomp-bpf / libseccomp | Por implementar |
| Setup PKI (JARs) | Script bash de primer arranque | Por implementar |
| Empaquetado | Flatpak o AppImage | Fase final |
| Plataforma primaria | Linux (Fedora, Ubuntu, Debian) | Target inicial |
| Lenguaje de scripts | Bash + Python | Por confirmar |

---

## 5. Pendientes Críticos

### Información recopilada ✅

- [x] **Tipo de instalación:** PortableApp con binarios Windows pre-compilados → usar Wine
- [x] **Archivos en Documents:** Confirmados directamente desde la carpeta Documents de Windows de Luis. Contiene: carpeta `pki/` con 4 JARs de firma + carpeta `SENAE browser/` con la app portable completa
- [x] **Versión exacta de Flash:** `NPSWF32_25_0_0_171.dll` v25.0.0.171 — embebido en la extensión `playflash@xpi` dentro del perfil del browser
- [x] **Versión de JRE:** JRE 7 Update 15 (10.15.2.3) — confirmado en `pluginreg.dat`. Instalador `jre715.exe` incluido en la carpeta `Installers/`
- [x] **Rutas AppData para JARs:** Completamente documentadas en `copy_pki_dev_7_ecuapass_portal.bat` incluido en la carpeta `pki/`
- [x] **Plugins activos:** Confirmados via `pluginreg.dat` — Flash 25, Java 7u15 (`npjp2.dll`), npDeployJava 7.0.150.3

### Información pendiente

- [ ] **Tipo de firma:** ¿Solo JARs vía applet Java, o también token USB físico (smartcard) para algún trámite específico?
- [ ] **Certificados del portal:** ¿El portal de Aduana usa certificados de CA ecuatoriana propia o CA pública estándar?
- [ ] **Compatibilidad Wine con JRE 7:** Verificar en práctica si Wine ejecuta correctamente los applets Java de la firma

### Decisiones de arquitectura pendientes

- [x] **Wine 32-bit puro vs WoW64:** Resuelto → WINEARCH=win32 obligatorio (WoW64 rompe plugins NPAPI de 32 bits)
- [x] **Proxy TLS:** Resuelto → mitmproxy para desarrollo/pruebas, micro-proxy en Go para producción (binario estático, sin dependencias, ideal para empaquetar)
- [ ] ¿Distribuir como Flatpak, AppImage, o script de instalación simple?
- [ ] ¿Incluir JRE 7 dentro del paquete o requerir instalación separada?
- [ ] **Verificación SHA-256:** El script de setup debe verificar hashes de `jre715.exe` y del SENAE Browser antes de instalarlos en el prefijo Wine (mitigación supply chain)

---

## 6. Flujo de Trabajo del Proyecto

```
Fase 1: Investigación (COMPLETADA ✅)
  ✅ Identificar tipo de instalación (PortableApp → Wine)
  ✅ Confirmar versiones exactas de Flash y Java
  ✅ Documentar archivos PKI y rutas AppData requeridas
  ⏳ Confirmar si se usa token USB físico

Fase 2: Prueba de concepto Wine
  └── Instalar Wine 32-bit en Fedora
  └── Crear WINEPREFIX limpio para SenaeBox
  └── Ejecutar SENAE_browser.exe dentro de Wine
  └── Verificar que Flash y Java arrancan
  └── Copiar JARs PKI y verificar que la firma funciona

Fase 3: Sandbox con Bubblewrap
  └── Envolver Wine dentro de Bubblewrap
  └── Definir lista blanca de rutas accesibles
  └── Verificar que el browser sigue funcionando dentro del sandbox

Fase 4: Proxy TLS
  └── Interceptar y modernizar conexiones de red
  └── Manejar certificados del portal Aduana

Fase 5: Seguridad (seccomp-bpf)
  └── Implementar filtro de syscalls
  └── Probar que exploits conocidos quedan contenidos

Fase 6: Script de setup automático
  └── Detección de primer arranque
  └── Copia automática de JARs PKI a rutas correctas
  └── Configuración del proxy TLS transparente

Fase 7: Empaquetado y distribución
  └── Flatpak o AppImage
  └── Documentación para usuarios finales
  └── Repositorio público en GitHub
```

---

## 7. Participantes

| Rol | Descripción |
|---|---|
| Usuario | Desarrollador principal, acceso a hardware real, usuario del Ecuapass, coordinador entre herramientas, tester |
| Claude (Anthropic) | Diseño de arquitectura, implementación de código, análisis del código fuente |
| Gemini (Google) | Auditoría técnica de arquitectura ✅ — arquitectura Wine aprobada en revisión del 15/05/2026 |

---

## 8. Repositorio

> ⚠️ Pendiente: Crear repositorio público en GitHub  
> Nombre sugerido: `senaebox` o `ecuabox`  
> Licencia sugerida: MIT o GPL v3

---

## 9. Notas Técnicas Adicionales

### Sobre el ecosistema npm y seguridad (contexto Mayo 2026)
Durante el desarrollo de este proyecto se identificó que el ecosistema npm ha sufrido ataques masivos de supply chain (TeamPCP, TanStack, node-ipc). Aunque el SENAE Browser no usa npm en producción, estas vulnerabilidades son relevantes para el entorno de desarrollo. Se recomienda usar `--ignore-scripts` en cualquier `npm install` durante el desarrollo de SenaeBox.
