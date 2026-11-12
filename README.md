# RamBar

Indicador de RAM para la barra de menús de macOS. Un archivo de Swift, cero dependencias, sin telemetría.

```
9.8/16 GB
```

## Inicio rápido

Necesitas macOS 13 o posterior y las Command Line Tools de Xcode. Si no las tienes:

```bash
xcode-select --install
```

No hace falta Xcode completo, ni un proyecto, ni gestor de paquetes. Después:

```bash
git clone https://github.com/HectorADiaz/rambar.git
cd rambar
chmod +x build.sh package.sh
./build.sh
cp -R RamBar.app /Applications/
open /Applications/RamBar.app
```

El indicador aparece en la barra de menús de inmediato. Dos pasos más que conviene dar enseguida:

1. **Si no ves el icono**, macOS 26 exige autorizar cada app para la barra de menús: abre **Ajustes del Sistema → Barra de menús** y activa **RamBar**.
2. **Para que arranque solo** con la sesión, abre el menú de RamBar y activa **Abrir al iniciar sesión**.

Por qué `cp -R` a Aplicaciones y no ejecutarla desde la carpeta del proyecto: el arranque automático registra la ruta desde donde se activó, y esa ruta tiene que ser estable. Si recompilas, vuelve a copiar.

**Para desinstalar:** sal desde el menú de la app y borra `/Applications/RamBar.app`. Si habías activado el arranque automático, quítalo antes desde el mismo menú.

## Qué muestra

**En la barra:** un icono de chip de memoria, la memoria usada y el total. El color de ambos lo decide la presión de memoria, no el porcentaje (ver abajo).

El icono es un símbolo SF del sistema (`memorychip`), no un archivo de imagen: no hay assets que empaquetar y se adapta solo a la barra clara y a la oscura.

**Al hacer clic:**

| Fila | Qué es |
| --- | --- |
| `9.8 GB de 16.0 GB · 61%` | Memoria usada y porcentaje |
| `Conectada · Comprimida · Caché` | En qué se reparte |
| `Presión normal · Sin swap en uso` | Si el sistema va apretado |
| Procesos | Los cinco que más memoria consumen, agrupados por nombre |

Y un acceso para abrir el Monitor de Actividad cuando quieres el detalle completo.

### Por qué el color no depende del porcentaje

Un 85% de memoria usada en macOS normalmente **no** es un problema. El sistema llena la RAM libre con caché de archivos a propósito, porque RAM vacía es RAM desperdiciada, y esa caché se libera al instante en cuanto una app la necesita.

Lo que sí indica que la máquina está sufriendo es la **presión de memoria**: el mismo indicador que grafica el Monitor de Actividad. Puedes estar al 90% con presión normal y todo bien, o al 70% con presión alta y la máquina arrastrándose. Por eso el indicador se pinta según la presión:

| Presión | Color |
| --- | --- |
| normal | el que use la barra: se adapta solo a fondo claro u oscuro |
| alta | naranja |
| crítica | rojo |

El `warningFraction` de la configuración es solo un respaldo: entra en acción únicamente si no se puede leer la presión del sistema.

La otra señal es el **swap**. Si aparece swap en uso y creciendo, el Mac ya está escribiendo memoria al SSD porque no le alcanza, y es cuando lo sientes.

### Qué cuenta como "memoria usada"

El mismo criterio del Monitor de Actividad: **memoria de apps + conectada (wired) + comprimida**. La caché de archivos no cuenta como usada, justo por lo explicado arriba.

Debería coincidir muy de cerca con lo que ves en el Monitor de Actividad. "Muy de cerca" y no "exacto" porque Apple no documenta su fórmula al detalle: para la parte de apps, ellos agregan el *phys_footprint* de cada proceso y aquí se usa el contador global de páginas internas menos las purgables. La diferencia es de décimas de GB.

## Instalación sin compilar

Si prefieres saltarte el compilador, descarga el `.dmg` de la última [release](../../releases) —cuando haya alguna publicada—, ábrelo y arrastra `RamBar.app` a Aplicaciones.

Binario universal (Apple Silicon e Intel), ~1 MB, sin icono en el Dock.

### Si macOS dice que no puede verificar la app

Pasa con cualquier app que no esté notarizada por Apple. A partir de macOS Sequoia (15) ya no sirve hacer clic derecho → Abrir; hay que autorizarla una sola vez desde Ajustes:

1. Intenta abrir la app y cierra el aviso.
2. Abre **Ajustes del Sistema → Privacidad y seguridad**.
3. Baja a la sección **Seguridad**: verás "RamBar fue bloqueada para proteger tu Mac".
4. Haz clic en **Abrir de todos modos** y confirma con tu contraseña.

Solo se hace la primera vez. Si prefieres no pasar por ahí, compílala tú mismo: una app compilada localmente no entra en cuarentena.

### Si no aparece el icono en la barra

macOS 26 agregó un control de privacidad para la barra de menús: abre **Ajustes del Sistema → Barra de menús** y activa **RamBar**.

### Arrancar con la sesión

En el menú de RamBar, activa **Abrir al iniciar sesión**. Se registra con `SMAppService` —el mecanismo que macOS 13 dejó para esto, sin launch agents ni helpers a mano— y aparece en Ajustes del Sistema → General → Ítems de inicio como cualquier otra app.

Para que sea estable, la app tiene que vivir en `/Applications`:

```bash
cp -R RamBar.app /Applications/
```

El registro apunta a la ruta desde donde se activó, así que si lo haces desde la carpeta del proyecto se rompe en cuanto muevas o recompiles el bundle. Con firma ad-hoc, además, cada compilación cambia la firma. Si estás iterando sobre el código, registra solo la copia instalada en Aplicaciones.

## Compilar desde el código

Solo necesitas las Command Line Tools (`xcode-select --install`). No hay proyecto de Xcode ni gestor de paquetes.

```bash
git clone https://github.com/HectorADiaz/rambar.git
cd rambar
chmod +x build.sh package.sh
./build.sh && open RamBar.app
```

`build.sh` compila para la arquitectura de tu Mac y arma el bundle `.app` a mano: `swiftc` sobre un archivo, `Info.plist` copiado y firma ad-hoc.

## Empaquetar y distribuir

`package.sh` hace el build universal (`arm64` y `x86_64` unidos con `lipo`) y genera un `.dmg` con el alias a Aplicaciones.

```bash
# Firma ad-hoc, sin notarizar
./package.sh

# Firmado y notarizado
SIGN_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)" \
NOTARY_PROFILE="rambar-notary" \
VERSION=1.0.0 ./package.sh
```

Notarizar requiere una membresía del Apple Developer Program (99 USD al año). Sin ella la app funciona igual, pero quien la descargue pasa por el trámite de "Abrir de todos modos" descrito arriba.

El pipeline que ejecuta el script son los cuatro pasos obligatorios de Apple: firmar con el certificado Developer ID, empaquetar, notarizar con `notarytool` y hacer *staple* del ticket. Dos detalles que tumban la mayoría de los intentos y que el script ya cubre:

- El **hardened runtime** es obligatorio (`--options runtime`): el servicio de notarización rechaza cualquier app sin él.
- `altool` quedó fuera de servicio en noviembre de 2023. Todo script que siga llamándolo está roto.

El perfil de notarización se crea una sola vez:

```bash
xcrun notarytool store-credentials "rambar-notary" \
    --apple-id "tu@correo.com" --team-id TEAMID --password APP_SPECIFIC_PASSWORD
```

## Configuración

Las opciones están al inicio de `main.swift`, en `Config`:

| Opción | Por defecto | Qué hace |
| --- | --- | --- |
| `refreshInterval` | `3` | Segundos entre lecturas |
| `display` | `.gigabytes` | `.percent` (`61%`), `.gigabytes` (`9.8/16 GB`) o `.both` |
| `warningFraction` | `0.90` | Umbral de respaldo para el rojo, solo si no se puede leer la presión |
| `symbolName` | `"memorychip"` | Símbolo SF junto al número (`nil` lo quita) |
| `topProcessCount` | `5` | Procesos a listar en el menú (`0` quita la sección) |
| `fontSize` | `12` | Tamaño de la fuente del indicador |

## Cómo funciona

Todo sale de contadores que el kernel ya mantiene:

| Dato | De dónde |
| --- | --- |
| Páginas de memoria por categoría | `host_statistics64` con `HOST_VM_INFO64` |
| RAM total | `sysctl hw.memsize` |
| Presión de memoria | `sysctl kern.memorystatus_vm_pressure_level` |
| Swap | `sysctl vm.swapusage` |
| Procesos | `ps -axo rss=,comm=`, solo al abrir el menú |

La lista de procesos se agrupa por nombre de ejecutable porque los navegadores se reparten en decenas de helpers: sin agrupar, el top serían cinco filas de "Google Chrome Helper". Y se calcula solo cuando se despliega el menú, no en cada refresco, para no gastar CPU en algo que nadie está viendo.

## Privacidad

- Lee contadores del sistema y consulta `ps` al abrir el menú. No cierra ni modifica ningún proceso.
- No escribe archivos, no abre conexiones de red, no tiene telemetría ni analíticas.
- No pide permisos del sistema más allá de mostrarse en la barra de menús.

## Licencia

MIT.
