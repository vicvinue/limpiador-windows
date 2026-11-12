# Limpiador de Windows

Herramienta gráfica, gratuita y de código abierto para **liberar espacio y optimizar Windows 10/11 sin romper nada**.

Es un único script de PowerShell con interfaz gráfica: no hay que instalar nada, no tiene dependencias y puedes leer todo lo que hace antes de ejecutarlo.

> *English summary:* a single-file, dependency-free PowerShell GUI tool to safely clean junk files, remove preinstalled bloatware, run official Windows maintenance tools and find large files. Every change is conservative and reversible. UI is in Spanish.

---

## Qué hace

### 🧹 Archivos basura
Analiza y muestra el tamaño de cada categoría antes de borrar nada:

| Sistema | Navegadores (solo caché) | Aplicaciones (solo caché) |
|---|---|---|
| Temporales del usuario y de Windows | Chrome, Edge, Brave, Vivaldi, Opera, Firefox | Discord, Teams clásico, VS Code, Steam |
| Descargas de Windows Update ya instaladas | *No toca historial, contraseñas, cookies ni sesiones* | Cachés de npm, pip, NuGet y Yarn (opcional) |
| Caché de Optimización de distribución | | |
| Informes de errores y volcados de memoria | | |
| Miniaturas, caché de Internet, sombreadores de GPU | | |
| Logs de Windows de más de 7 días | | |
| Papelera, WinSxS (DISM) y Windows.old *(opcionales)* | | |

Las categorías de programas que no tienes instalados no aparecen.

### 📦 Bloatware
Desinstala apps preinstaladas prescindibles: Noticias, Sugerencias, Candy Crush, accesos directos promocionales, Cortana, Películas y TV...
- Solo se muestran apps de una **lista cerrada y conservadora**. La Store, Edge, los componentes del sistema y los controladores nunca aparecen.
- Las apps se agrupan en *Recomendado quitar*, *Opcional* y *Juegos y Xbox*. Solo el primer grupo viene marcado por defecto.
- Crea un **punto de restauración** antes de desinstalar, y puede evitar que Windows reinstale esas apps.
- Todas se pueden reinstalar desde Microsoft Store.

### ⚙️ Optimizar
Detecta el tipo de equipo (sobremesa, portátil o máquina virtual), el tipo de disco (SSD o HDD) y la RAM, y adapta las recomendaciones:
- **Optimizar unidades**: TRIM en SSD o desfragmentación en HDD, con la herramienta oficial `defrag`.
- **Reparar Windows**: `DISM /RestoreHealth` y `sfc /scannow`.
- **Comprobar el disco**: `chkdsk /scan`, en línea y sin reiniciar.
- **Efectos visuales en modo rendimiento**: reversible.
- **Desactivar la hibernación**: libera varios GB; es reversible.

Todo ajuste guarda su valor original y se puede revertir con **Deshacer ajustes**.

### 📊 Espacio
Analizador de las carpetas y los archivos más grandes de tu perfil, de Descargas, de una unidad o de cualquier carpeta.
- Doble clic para entrar en una carpeta, y opción para abrir su ubicación en el Explorador.
- **Enviar a la papelera** en lugar de borrar, para poder recuperarlo. Las carpetas de Windows y de los programas están protegidas.

---

## Principios de seguridad

- **Nunca** toca documentos, programas instalados, controladores ni componentes del sistema.
- **No** limpia el registro (los "limpiadores de registro" no aceleran nada y pueden romper programas).
- **No** desactiva Windows Defender, Windows Update ni servicios del sistema.
- **No** sigue enlaces simbólicos ni uniones (junctions): nunca puede borrar fuera de la carpeta que limpia.
- Los archivos en uso se omiten; en las carpetas temporales tampoco se borra nada de las últimas 24 horas.
- Para lo delicado usa las herramientas oficiales de Windows: DISM, SFC, defrag, el Liberador de espacio y `Delete-DeliveryOptimizationCache`.
- Siempre muestra qué va a hacer y pide confirmación.

---

## Requisitos

- Windows 10 (1809 o posterior) o Windows 11.
- Windows PowerShell 5.1, que ya viene incluido en Windows.
- Permisos de administrador para las opciones del sistema. Sin ellos, la herramienta funciona con las opciones del usuario.

## Uso

1. Descarga el repositorio (**Code → Download ZIP**) y descomprímelo.
2. Haz doble clic en **`Limpiador.bat`**.
3. Acepta el aviso de permisos de Windows (UAC).

> **Aviso de SmartScreen / archivo bloqueado:** los archivos descargados de Internet vienen marcados por Windows. Si no se abre, haz clic derecho en `Limpiador.ps1` → *Propiedades* → marca **Desbloquear**, o ejecuta en PowerShell:
> ```powershell
> Get-ChildItem -Path .\LimpiadorWindows -Recurse | Unblock-File
> ```

### Modo análisis (solo lectura)
Muestra en la consola lo que se podría limpiar, el bloatware detectado y el estado de las optimizaciones, **sin cambiar nada**:
```powershell
powershell -ExecutionPolicy Bypass -File .\Limpiador.ps1 -Analizar
```

## Registro y copia de seguridad

| Archivo | Contenido |
|---|---|
| `%LOCALAPPDATA%\LimpiadorWindows\limpieza.log` | Registro de todo lo que hace la herramienta |
| `%LOCALAPPDATA%\LimpiadorWindows\ajustes-originales.json` | Valores originales de los ajustes, usados por *Deshacer ajustes* |

## Cómo deshacer cambios

| Acción | Cómo revertirla |
|---|---|
| Ajustes de la pestaña Optimizar | Botón **Deshacer ajustes** |
| Apps desinstaladas | Reinstalarlas desde Microsoft Store, o usar el punto de restauración creado antes de desinstalar |
| Archivos enviados a la papelera | Restaurarlos desde la Papelera de reciclaje |
| Archivos basura | No hace falta: son cachés y temporales que se regeneran solos |

## Contribuir

Las categorías de limpieza (`$Categories`), el catálogo de bloatware (`$BloatCatalog`) y las optimizaciones (`$Optimizations`) son listas declarativas al principio de `Limpiador.ps1`. Para proponer una nueva entrada, abre un *issue* o *pull request* explicando:
- qué es y por qué se puede quitar sin riesgo;
- en qué versiones de Windows aparece.

Criterio para aceptar cambios: si hay dudas razonables de que pueda romper algo, no se incluye, o se incluye **desmarcado** con una advertencia clara.

## Licencia

[MIT](LICENSE). Se distribuye "tal cual", sin garantías de ningún tipo. Úsalo bajo tu responsabilidad.
