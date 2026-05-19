# Packaging — AppImage de SenaeBox

Configuración para empaquetar SenaeBox como un AppImage distribuible. Usa
[appimage-builder](https://appimage-builder.readthedocs.io/) corriendo en un
contenedor Ubuntu 22.04 (LTS, glibc 2.35) para máxima compatibilidad de glibc
con sistemas destino (Fedora 36+, Ubuntu 22.04+, RHEL/Alma 9+).

## Archivos

| Archivo | Propósito |
|---------|-----------|
| `AppImageBuilder.yml` | Receta principal de appimage-builder |
| `AppRun` | Entry point del AppImage (se invoca al ejecutarlo) |
| `senaebox.desktop` | Desktop entry (categorías, icono, exec) |
| `senaebox.svg` | Icono (placeholder editable) |
| `build_appimage.sh` | Build script que orquesta podman + builder |
| `README.md` | Este archivo |

## Pre-requisitos en el sistema builder

1. **podman** instalado (para correr container Ubuntu)
2. **~10 GB libres** en `~/.cache/senaebox-appimage-build/` durante el build
3. **Wine-ge runner** extraído en `~/.local/share/senaebox/wine-runner/`
   - Si no lo tienes: descarga de [wine-ge releases](https://github.com/GloriousEggroll/wine-ge-custom/releases)
   - Extrae a `~/.local/share/senaebox/wine-runner/` (el binario queda en `bin/wine`)
4. **SENAE Browser portable** en `~/Documentos/SENAE browser/`
   - Obtenido de la distribución oficial de SENAE Aduana del Ecuador
   - El build excluye automáticamente la carpeta `Data/` (perfil del builder)

## Build

```bash
cd ~/senaebox
bash packaging/build_appimage.sh 1.0.0
```

Tarda 30-60 minutos la primera vez (descarga imagen Ubuntu + dependencias apt).
Subsiguientes builds del mismo container son más rápidos (~15 min).

El resultado:
```
packaging/out/SenaeBox-1.0.0-x86_64.AppImage   (~350-500 MB)
```

### Variables configurables

```bash
SENAEBOX_VERSION=2.0.0 \
SOURCE_REPO=/path/to/senaebox \
SOURCE_WINE_RUNNER=/path/to/wine-runner \
SOURCE_SENAE_BROWSER=/path/to/SENAE\ browser \
BUILD_DIR=/path/to/build \
OUTPUT_DIR=/path/to/out \
bash packaging/build_appimage.sh
```

## Privacidad — garantías del build

El build aplica **tres capas** de filtrado para evitar incluir datos personales:

1. **Whitelist explícita en `AppImageBuilder.yml`**: el `script` solo copia
   archivos específicos del repo (launch.sh, scripts/*, sandbox/*, proxy/*,
   pki/*, assets/profile-templates/*). NUNCA hace `cp -r` del repo entero,
   por lo que `.git/`, `.claude/`, `assets/senaebox-ca/`, archivos sueltos
   nunca entran al AppImage.

2. **rsync con excludes para SENAE Browser**: la copia del SENAE Browser
   portable usa `--exclude='Data/'` para descartar profile + cookies + cert8.db
   + downloads del builder.

3. **Auditoría final en el `script`**: antes de empaquetar, el script busca
   patrones sospechosos en el AppDir (`*.log`, `*.bak*`, `cookies.sqlite`,
   `*key*.pem`, `.setup_complete`, etc.) y **aborta el build** si encuentra
   alguno.

4. **Excludes finales en `AppDir.files.exclude`**: red de seguridad adicional
   para descartar lo que pueda haber entrado por dependencias apt.

### Pre-flight scan

`build_appimage.sh` también valida ANTES del build:
- Que `$SOURCE_WINE_RUNNER` no traiga un `drive_c/` (wineprefix interno → datos
  del builder). Si lo encuentra, **aborta**.
- Que `$SOURCE_REPO` no tenga archivos `*.log`, `*.csv`, claves privadas,
  markers de setup. Si los encuentra, **advierte** (el YAML los excluirá, pero
  conviene limpiar).
- Que `$SOURCE_SENAE_BROWSER/Data/` exista → solo aviso (el YAML lo excluye).

### Qué nunca va al AppImage

- `~/.local/share/senaebox/` (estado del usuario builder)
- `~/.mitmproxy/` (CA personal del builder)
- Cualquier wineprefix (`drive_c/users/...`)
- `Data/` del SENAE Browser portable
- `*.log`, `*.bak*`, `*.csv`, `*.mitm`
- Claves privadas (`*key*.pem`, `*.p12`, `*.pkcs12`)
- Markers de setup (`.setup_complete`, `.ca_fingerprint`, etc.)
- `.git/`, `.claude/`, `.vscode/`, IDE configs

## Comportamiento del AppImage en el usuario final

Cuando el usuario ejecuta el `.AppImage`:

1. **Self-mount**: el AppImage se monta como squashfs en `/tmp/.mount_SenaeXXX`
2. **AppRun valida deps del host**: bubblewrap (requerido), zenity (bundled), etc.
3. **Env vars apuntan a binarios bundled**:
   - `SENAEBOX_WINE` → wine-runner del AppImage
   - `PATH` incluye `mitm-venv/bin/` y `usr/bin/` del AppImage
4. **Siembra SENAE Browser portable** en `~/.local/share/senaebox/wine/.../Documents/SENAE browser/`
   si no existe (primera vez)
5. **Exec `launch.sh`**: el resto del flujo es idéntico al modo desarrollo
   - Primer arranque → `setup_first_run.sh` (genera CA local, parchea cert8.db con
     podman temporal vía pkexec si el usuario no tiene podman)
   - Arranques siguientes → directo al proxy + sandbox + browser

## Dependencias del HOST (que el AppImage NO bundlea)

- `bubblewrap` — debe estar instalado (SUID root, no se puede bundlear)
- `pkexec` — opcional, requerido solo si setup necesita instalar podman
- `podman` — opcional, instalado/desinstalado por setup vía pkexec si falta

## Tamaño esperado

| Componente | Tamaño aproximado |
|------------|-------------------|
| Wine-ge runner | ~940 MB |
| SENAE Browser portable (sin Data/) | ~185 MB |
| mitmproxy venv + deps Python | ~80 MB |
| Libs apt i386 (Wine deps) + Mesa | ~150 MB |
| Scripts y configs SenaeBox | ~5 MB |
| **Total descomprimido** | **~1.4 GB** |
| **AppImage final (zstd)** | **~400-500 MB** |

## Verificación de integridad

Tras el build, `build_appimage.sh` imprime el SHA-256 del AppImage. Publicar
junto al binario para que los usuarios verifiquen:

```bash
sha256sum -c SenaeBox-1.0.0-x86_64.AppImage.sha256
```

## Distribución sugerida

1. Subir `.AppImage` y `.AppImage.sha256` a GitHub Releases o servidor SENAE
2. Documentar en README del repo cómo descargar + verificar + ejecutar
3. Para updates: nuevo release con `--update-information` (omitido en este
   build inicial)

## Limitaciones conocidas

- **No bundlea Java JRE 7u15**: el usuario debe colocarlo en `~/Documentos/SENAE browser/Installers/jre715.exe` antes del primer arranque, y `setup_first_run.sh` verifica SHA-256 antes de instalar.
- **No firma el AppImage**: para firmar, configurar `sign-key` en `AppImageBuilder.yml` con una key GPG y publicar la pública.
- **No soporta auto-update**: distribución manual. Para AppImageUpdate compatibility, configurar `update-information` (zsync/gh-releases).
