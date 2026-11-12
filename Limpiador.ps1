#requires -Version 5.1
<#
    Limpiador de Windows
    https://github.com/vicvinue

    Herramienta gráfica para liberar espacio y optimizar Windows 10/11 sin romper nada:
      - Archivos basura: temporales, cachés, informes de errores, restos de actualizaciones...
      - Bloatware: desinstala apps preinstaladas prescindibles (lista cerrada y conservadora).
      - Optimizar: mantenimiento con herramientas oficiales de Windows y ajustes reversibles.
      - Espacio: analizador de las carpetas y archivos más grandes.

    Principios de seguridad:
      - Nunca toca documentos, programas instalados ni componentes del sistema.
      - No sigue enlaces simbólicos ni uniones (junctions).
      - Los archivos en uso se omiten.
      - Todo ajuste guarda su valor original y se puede deshacer.

    Uso:
        Limpiador.bat                                  Interfaz gráfica (pide permisos de administrador)
        powershell -ExecutionPolicy Bypass -File Limpiador.ps1 -Analizar
                                                       Solo muestra tamaños en consola, no borra nada

    Licencia MIT. Se distribuye "tal cual", sin garantías.
#>
param(
    [switch]$Analizar,
    # Parámetros internos: el proceso elevado sigue limpiando el perfil del usuario que abrió la app,
    # aunque el administrador sea otra cuenta.
    [string]$TargetSid,
    [string]$TargetProfile,
    [string]$TargetLocal,
    [string]$TargetRoaming,
    [string]$TargetTemp
)

$AppName    = 'Limpiador de Windows'
$AppVersion = '1.1.0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- Permisos ----
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:IsAdmin = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $TargetSid)     { $TargetSid     = $me.User.Value }
if (-not $TargetProfile) { $TargetProfile = $env:USERPROFILE }
if (-not $TargetLocal)   { $TargetLocal   = $env:LOCALAPPDATA }
if (-not $TargetRoaming) { $TargetRoaming = $env:APPDATA }
if (-not $TargetTemp)    { $TargetTemp    = $env:TEMP }

if (-not $script:IsAdmin -and -not $Analizar) {
    $q = { param($s) '"' + $s + '"' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (& $q $PSCommandPath),
            '-TargetSid', $TargetSid,
            '-TargetProfile', (& $q $TargetProfile),
            '-TargetLocal', (& $q $TargetLocal),
            '-TargetRoaming', (& $q $TargetRoaming),
            '-TargetTemp', (& $q $TargetTemp))
        exit
    } catch {
        # El usuario rechazó el UAC: seguimos con permisos limitados.
    }
}

$script:OtherUser = ($me.User.Value -ne $TargetSid)
$script:HKCU = "Registry::HKEY_USERS\$TargetSid"
$script:TargetName = $TargetSid
try { $script:TargetName = ([Security.Principal.SecurityIdentifier]$TargetSid).Translate([Security.Principal.NTAccount]).Value } catch { }

$script:DataDir = Join-Path $TargetLocal 'LimpiadorWindows'
try { New-Item -ItemType Directory -Force -Path $script:DataDir -ErrorAction Stop | Out-Null } catch { $script:DataDir = $env:TEMP }
$script:LogFile    = Join-Path $script:DataDir 'limpieza.log'
$script:BackupFile = Join-Path $script:DataDir 'ajustes-originales.json'

$script:LogBox   = $null
$script:Busy     = $false
$script:Internal = $false
$script:Cancel   = $false
$script:Tick     = 0

# Herramientas del sistema (evita la redirección de System32 si PowerShell fuera de 32 bits)
$script:Sys = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { "$env:SystemRoot\Sysnative" } else { "$env:SystemRoot\System32" }

# ------------------------------------------------------- Tipo de equipo -------
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$script:IsVM     = [bool]("$($cs.Manufacturer) $($cs.Model)" -match 'Virtual|VMware|Parallels|VirtualBox|innotek|KVM|QEMU|Xen|Hyper-V')
$script:IsLaptop = (-not $script:IsVM) -and [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$script:RamGB    = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB) } else { 0 }
$script:Machine  = if ($script:IsVM) { 'Máquina virtual' } elseif ($script:IsLaptop) { 'Portátil' } else { 'Sobremesa' }

# --------------------------------------------------------------- Utilidades ---
function Pump {
    $script:Tick++
    if ($script:Tick % 150 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
}

function Format-Size([long]$b) {
    if ($b -lt 0)   { return 'Desconocido' }
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return "$b B"
}

function Get-FreeSpace { (New-Object System.IO.DriveInfo $env:SystemDrive).AvailableFreeSpace }

function Write-Log([string]$msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    if ($script:LogBox) { $script:LogBox.AppendText($line + "`r`n") } else { Write-Host $line }
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Get-Cutoff([int]$days) {
    if ($days -le 0) { return [datetime]::MaxValue }
    return (Get-Date).AddDays(-$days)
}

function Wait-Proc($p) {
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }
}

function Invoke-Tool([string]$exe, [string[]]$argList) {
    $p = Start-Process -FilePath (Join-Path $script:Sys $exe) -ArgumentList $argList -WindowStyle Hidden -PassThru
    Wait-Proc $p
    return $p.ExitCode
}

# Un "objetivo" es una carpeta cuyo CONTENIDO se puede vaciar.
function T([string]$Path, [string]$Filter = '*', [int]$MinAgeDays = 0, [switch]$NoRecurse) {
    [pscustomobject]@{ Path = $Path; Filter = $Filter; MinAgeDays = $MinAgeDays; Recurse = (-not $NoRecurse) }
}

function Test-SafeRoot($path) {
    try { if (-not [IO.Directory]::Exists($path)) { return $false } } catch { return $false }
    $root = New-Object System.IO.DirectoryInfo $path
    # Nunca entrar en una carpeta que sea en sí misma un enlace/unión
    return (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
}

function Measure-Target($t) {
    if (-not (Test-SafeRoot $t.Path)) { return [long]0 }
    $cutoff = Get-Cutoff $t.MinAgeDays
    $total  = [long]0
    $stack  = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo $t.Path))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $entries = $null
        try { $entries = $d.GetFileSystemInfos() } catch { }
        if ($null -eq $entries) { continue }
        foreach ($e in $entries) {
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($e -is [System.IO.DirectoryInfo]) {
                if ($t.Recurse) { $stack.Push($e) }
            } elseif ($e.Name -like $t.Filter -and $e.LastWriteTime -lt $cutoff) {
                $total += $e.Length
            }
        }
        Pump
    }
    return $total
}

function Clear-Dir([System.IO.DirectoryInfo]$Dir, [string]$Filter, [datetime]$Cutoff, [bool]$Recurse, $Res) {
    $entries = $null
    try { $entries = $Dir.GetFileSystemInfos() } catch { $Res.Failed++; return }
    foreach ($e in $entries) {
        # Los enlaces simbólicos / uniones se ignoran: nunca se sigue ni se borra su destino.
        if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($Recurse) {
                Clear-Dir $e $Filter $Cutoff $Recurse $Res
                try {
                    if ($e.GetFileSystemInfos().Length -eq 0 -and $e.CreationTime -lt $Cutoff) {
                        $e.Attributes = [IO.FileAttributes]::Directory
                        $e.Delete()
                    }
                } catch { }
            }
        } elseif ($e.Name -like $Filter -and $e.LastWriteTime -lt $Cutoff) {
            $len = $e.Length
            try {
                if (($e.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $e.Attributes = [IO.FileAttributes]::Normal }
                $e.Delete()
                $Res.Freed += $len
                $Res.Files++
            } catch { $Res.Failed++ }
        }
    }
    Pump
}

function Clear-Target($t, $Res) {
    if (-not (Test-SafeRoot $t.Path)) { return }
    Clear-Dir (New-Object System.IO.DirectoryInfo $t.Path) $t.Filter (Get-Cutoff $t.MinAgeDays) $t.Recurse $Res
}

function Get-ChromiumTargets([string]$UserData) {
    $out = @()
    if (-not (Test-SafeRoot $UserData)) { return $out }
    $profiles = @(Get-ChildItem -LiteralPath $UserData -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' })
    foreach ($p in $profiles) {
        foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') {
            $out += T (Join-Path $p.FullName $c)
        }
    }
    foreach ($c in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache') { $out += T (Join-Path $UserData $c) }
    return $out
}

# ===================================================== 1. ARCHIVOS BASURA =====
$L  = $TargetLocal
$R  = $TargetRoaming
$UP = $TargetProfile
$W  = $env:SystemRoot
$PD = $env:ProgramData
$SD = $env:SystemDrive

function New-Cat {
    param([string]$Id, [string]$Group, [string]$Name, [string]$Note, [string]$Desc, [scriptblock]$Targets,
          [switch]$Admin, [switch]$Off, [switch]$Optional, [string[]]$Procs = @(),
          [scriptblock]$Size, [scriptblock]$Action)
    [pscustomobject]@{
        Id = $Id; Group = $Group; Name = $Name; Note = $Note; Desc = $Desc; Targets = $Targets
        Admin = [bool]$Admin; Default = (-not $Off); Optional = [bool]$Optional; Procs = $Procs
        Size = $Size; Action = $Action; Bytes = [long]-1
    }
}

function Get-Targets($cat) { if ($cat.Targets) { @(& $cat.Targets) } }

function Measure-Cat($cat) {
    if ($cat.Size) { return [long](& $cat.Size) }
    $ts = Get-Targets $cat
    if (-not $ts) { return [long]-1 }
    $sum = [long]0
    foreach ($t in $ts) { $sum += Measure-Target $t }
    return $sum
}

function Test-AnyTarget($cat) {
    foreach ($t in (Get-Targets $cat)) { try { if ([IO.Directory]::Exists($t.Path)) { return $true } } catch { } }
    return $false
}

$Categories = @(
    # ---------------- Sistema ----------------
    New-Cat -Id tempuser -Group 'Sistema' -Name 'Archivos temporales del usuario' `
        -Note 'Seguro. Se omiten los archivos en uso y los de menos de 24 h.' `
        -Desc 'Carpeta %TEMP%. Los programas dejan aquí archivos de instalación y trabajo que nunca borran.' `
        -Targets { T $TargetTemp -MinAgeDays 1 }

    New-Cat -Id tempwin -Group 'Sistema' -Name 'Archivos temporales de Windows' -Admin `
        -Note 'Seguro. Se omiten los archivos en uso y los de menos de 24 h.' `
        -Desc 'Carpeta C:\Windows\Temp, usada por el sistema y los instaladores.' `
        -Targets { T "$W\Temp" -MinAgeDays 1 }

    New-Cat -Id wupdate -Group 'Sistema' -Name 'Descargas de Windows Update' -Admin `
        -Note 'Seguro. Son instaladores ya aplicados; se detiene el servicio un momento.' `
        -Desc 'C:\Windows\SoftwareDistribution\Download. Windows vuelve a descargar lo que necesite.' `
        -Targets { T "$W\SoftwareDistribution\Download" } `
        -Action {
            param($cat, $res)
            $svcs = @('wuauserv', 'bits') | ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } |
                Where-Object { $_.Status -eq 'Running' }
            foreach ($s in $svcs) { try { Stop-Service -Name $s.Name -Force -ErrorAction Stop } catch { } }
            foreach ($t in (Get-Targets $cat)) { Clear-Target $t $res }
            foreach ($s in $svcs) { try { Start-Service -Name $s.Name -ErrorAction Stop } catch { } }
        }

    New-Cat -Id deliveryopt -Group 'Sistema' -Name 'Caché de Optimización de distribución' -Admin `
        -Note 'Seguro. Copias de actualizaciones compartidas con otros PCs.' `
        -Desc 'Caché que Windows usa para compartir actualizaciones en la red. Se borra con la herramienta oficial.' `
        -Targets { T "$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" } `
        -Action {
            param($cat, $res)
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; return } catch { }
            }
            foreach ($t in (Get-Targets $cat)) { Clear-Target $t $res }
        }

    New-Cat -Id wer -Group 'Sistema' -Name 'Informes de errores de Windows' -Admin `
        -Note 'Seguro. Informes de fallos antiguos.' `
        -Desc 'Informes que Windows genera cuando un programa se cuelga o falla.' `
        -Targets {
            T "$PD\Microsoft\Windows\WER\ReportArchive"
            T "$PD\Microsoft\Windows\WER\ReportQueue"
            T "$PD\Microsoft\Windows\WER\Temp"
            T "$L\Microsoft\Windows\WER"
        }

    New-Cat -Id dumps -Group 'Sistema' -Name 'Volcados de memoria por fallos' -Admin `
        -Note 'Seguro. Solo sirven para diagnosticar pantallazos azules.' `
        -Desc 'Archivos .dmp de pantallazos azules y programas cerrados inesperadamente. Pueden ocupar varios GB.' `
        -Targets {
            T "$L\CrashDumps"
            T "$W\Minidump"
            T $W -Filter 'MEMORY.DMP' -NoRecurse
            T "$W\LiveKernelReports" -Filter '*.dmp'
        }

    New-Cat -Id thumbs -Group 'Sistema' -Name 'Caché de miniaturas' `
        -Note 'Seguro. Se regeneran solas; parte puede estar en uso.' `
        -Desc 'Vistas previas de imágenes y vídeos del Explorador. Se vuelven a crear al abrir las carpetas.' `
        -Targets { T "$L\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -NoRecurse }

    New-Cat -Id inetcache -Group 'Sistema' -Name 'Caché de Internet de Windows' `
        -Note 'Seguro.' `
        -Desc 'Caché web usada por componentes de Windows, Office y aplicaciones antiguas.' `
        -Targets { T "$L\Microsoft\Windows\INetCache" }

    New-Cat -Id logs -Group 'Sistema' -Name 'Registros (logs) antiguos de Windows' -Admin `
        -Note 'Seguro. Solo archivos de más de 7 días.' `
        -Desc 'Archivos de registro de C:\Windows\Logs (instalaciones, CBS, DISM...).' `
        -Targets { T "$W\Logs" -MinAgeDays 7 }

    New-Cat -Id shaders -Group 'Sistema' -Name 'Caché de sombreadores (DirectX / GPU)' `
        -Note 'Seguro. Los juegos pueden tardar algo más la primera vez.' `
        -Desc 'Cachés de DirectX, NVIDIA, AMD e Intel. Se regeneran automáticamente.' `
        -Targets {
            T "$L\D3DSCache"
            T "$L\NVIDIA\DXCache"
            T "$L\NVIDIA\GLCache"
            T "$PD\NVIDIA Corporation\NV_Cache"
            T "$L\AMD\DxCache"
            T "$L\AMD\DxcCache"
            T "$L\AMD\GLCache"
            T "$L\AMD\VkCache"
            T "$UP\AppData\LocalLow\Intel\ShaderCache"
        }

    New-Cat -Id recycle -Group 'Sistema' -Name 'Papelera de reciclaje' -Off `
        -Note 'Revisa antes que no haya nada que quieras recuperar.' `
        -Desc 'Vacía la papelera de todas las unidades. Lo borrado ya no se podrá recuperar.' `
        -Targets {
            foreach ($d in [IO.DriveInfo]::GetDrives()) {
                if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { T (Join-Path $d.RootDirectory.FullName ('$Recycle.Bin\' + $TargetSid)) }
            }
        } `
        -Action {
            param($cat, $res)
            if ($script:OtherUser) { foreach ($t in (Get-Targets $cat)) { Clear-Target $t $res } }
            else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        }

    New-Cat -Id dism -Group 'Sistema' -Name 'Limpieza del almacén de componentes (WinSxS)' -Admin -Off `
        -Note 'Seguro (herramienta oficial DISM). Lento: 5-20 minutos.' `
        -Desc 'Ejecuta "DISM /Online /Cleanup-Image /StartComponentCleanup" para quitar versiones antiguas de componentes reemplazados por actualizaciones.' `
        -Size { -1 } `
        -Action {
            param($cat, $res)
            $c = Invoke-Tool 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
            if ($c -ne 0) { Write-Log "  DISM terminó con código $c." }
        }

    New-Cat -Id winold -Group 'Sistema' -Name 'Instalación anterior de Windows (Windows.old)' -Admin -Off -Optional `
        -Note 'No rompe nada, pero ya no podrás volver a la versión anterior.' `
        -Desc 'Restos de una actualización de Windows (Windows.old, $Windows.~BT, $Windows.~WS). Se borra con el Liberador de espacio oficial.' `
        -Targets {
            T "$SD\Windows.old"
            T ($SD + '\$Windows.~BT')
            T ($SD + '\$Windows.~WS')
        } `
        -Action {
            param($cat, $res)
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            $flag = 'StateFlags0777'
            $set  = @()
            foreach ($h in 'Previous Installations', 'Temporary Setup Files', 'Windows Upgrade Log Files', 'Setup Log Files') {
                $k = Join-Path $base $h
                if (Test-Path $k) {
                    New-ItemProperty -Path $k -Name $flag -Value 2 -PropertyType DWord -Force | Out-Null
                    $set += $k
                }
            }
            Invoke-Tool 'cleanmgr.exe' @('/sagerun:777') | Out-Null
            foreach ($k in $set) { Remove-ItemProperty -Path $k -Name $flag -ErrorAction SilentlyContinue }
        }

    # ---------------- Navegadores (solo caché: no toca historial, contraseñas ni cookies) ----------------
    New-Cat -Id chrome -Group 'Navegadores (solo caché)' -Name 'Google Chrome' -Optional -Procs 'chrome' `
        -Note 'Seguro. No borra historial, contraseñas ni sesiones.' `
        -Desc 'Caché de páginas, código y GPU de todos los perfiles de Chrome. Cierra Chrome para limpiar todo.' `
        -Targets { Get-ChromiumTargets "$L\Google\Chrome\User Data" }

    New-Cat -Id edge -Group 'Navegadores (solo caché)' -Name 'Microsoft Edge' -Optional -Procs 'msedge' `
        -Note 'Seguro. No borra historial, contraseñas ni sesiones.' `
        -Desc 'Caché de páginas, código y GPU de todos los perfiles de Edge. Cierra Edge para limpiar todo.' `
        -Targets { Get-ChromiumTargets "$L\Microsoft\Edge\User Data" }

    New-Cat -Id brave -Group 'Navegadores (solo caché)' -Name 'Brave' -Optional -Procs 'brave' `
        -Note 'Seguro. No borra historial, contraseñas ni sesiones.' `
        -Desc 'Caché de todos los perfiles de Brave.' `
        -Targets { Get-ChromiumTargets "$L\BraveSoftware\Brave-Browser\User Data" }

    New-Cat -Id vivaldi -Group 'Navegadores (solo caché)' -Name 'Vivaldi' -Optional -Procs 'vivaldi' `
        -Note 'Seguro. No borra historial, contraseñas ni sesiones.' `
        -Desc 'Caché de todos los perfiles de Vivaldi.' `
        -Targets { Get-ChromiumTargets "$L\Vivaldi\User Data" }

    New-Cat -Id opera -Group 'Navegadores (solo caché)' -Name 'Opera' -Optional -Procs 'opera' `
        -Note 'Seguro. No borra historial, contraseñas ni sesiones.' `
        -Desc 'Caché de Opera y Opera GX.' `
        -Targets {
            T "$L\Opera Software\Opera Stable\Cache"
            T "$L\Opera Software\Opera GX Stable\Cache"
        }

    New-Cat -Id firefox -Group 'Navegadores (solo caché)' -Name 'Mozilla Firefox' -Optional -Procs 'firefox' `
        -Note 'Seguro. No borra historial, contraseñas ni sesiones.' `
        -Desc 'Caché de todos los perfiles de Firefox.' `
        -Targets {
            Get-ChildItem -LiteralPath "$L\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                T (Join-Path $_.FullName 'cache2')
                T (Join-Path $_.FullName 'startupCache')
            }
        }

    # ---------------- Aplicaciones ----------------
    New-Cat -Id discord -Group 'Aplicaciones (solo caché)' -Name 'Discord' -Optional -Procs 'Discord' `
        -Note 'Seguro. No cierra tu sesión.' -Desc 'Caché de imágenes y código de Discord.' `
        -Targets { T "$R\discord\Cache"; T "$R\discord\Code Cache"; T "$R\discord\GPUCache" }

    New-Cat -Id teams -Group 'Aplicaciones (solo caché)' -Name 'Microsoft Teams (clásico)' -Optional -Procs 'Teams' `
        -Note 'Seguro.' -Desc 'Caché de Teams clásico.' `
        -Targets {
            foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'tmp') { T "$R\Microsoft\Teams\$c" }
        }

    New-Cat -Id vscode -Group 'Aplicaciones (solo caché)' -Name 'Visual Studio Code' -Optional -Procs 'Code' `
        -Note 'Seguro. No toca extensiones ni ajustes.' -Desc 'Cachés y logs de VS Code.' `
        -Targets {
            foreach ($c in 'Cache', 'CachedData', 'Code Cache', 'GPUCache', 'CachedExtensionVSIXs', 'logs') { T "$R\Code\$c" }
        }

    New-Cat -Id steam -Group 'Aplicaciones (solo caché)' -Name 'Steam (navegador interno)' -Optional -Procs 'steam', 'steamwebhelper' `
        -Note 'Seguro. No toca juegos.' -Desc 'Caché web de la tienda/comunidad de Steam.' `
        -Targets { T "$L\Steam\htmlcache" }

    # ---------------- Desarrollo ----------------
    New-Cat -Id npm -Group 'Desarrollo (cachés de paquetes)' -Name 'Caché de npm' -Optional -Off `
        -Note 'Seguro. Los paquetes se vuelven a descargar si hacen falta.' -Desc '%LOCALAPPDATA%\npm-cache' `
        -Targets { T "$L\npm-cache" }

    New-Cat -Id pip -Group 'Desarrollo (cachés de paquetes)' -Name 'Caché de pip (Python)' -Optional -Off `
        -Note 'Seguro. Los paquetes se vuelven a descargar si hacen falta.' -Desc '%LOCALAPPDATA%\pip\Cache' `
        -Targets { T "$L\pip\Cache" }

    New-Cat -Id nuget -Group 'Desarrollo (cachés de paquetes)' -Name 'Caché HTTP de NuGet' -Optional -Off `
        -Note 'Seguro.' -Desc '%LOCALAPPDATA%\NuGet\v3-cache' `
        -Targets { T "$L\NuGet\v3-cache" }

    New-Cat -Id yarn -Group 'Desarrollo (cachés de paquetes)' -Name 'Caché de Yarn' -Optional -Off `
        -Note 'Seguro.' -Desc '%LOCALAPPDATA%\Yarn\Cache' `
        -Targets { T "$L\Yarn\Cache" }
)

# Ocultar programas que no están instalados
$Categories = @($Categories | Where-Object { -not $_.Optional -or (Test-AnyTarget $_) })

# ============================================================ 2. BLOATWARE ====
# Solo se muestran apps de ESTA lista. Nada que no esté aquí se puede desinstalar
# desde la aplicación (Store, Edge, componentes del sistema, controladores... quedan fuera).
# Todas se pueden reinstalar desde Microsoft Store.
$G1 = 'Recomendado quitar'
$G2 = 'Opcional: quítala solo si no la usas'
$G3 = 'Juegos y Xbox'
function B($G, $P, $N, $D, $Note) { [pscustomobject]@{ G = $G; P = $P; N = $N; D = [bool]$D; Note = $Note } }

$BloatCatalog = @(
    B $G1 'Microsoft.BingNews'                  'Microsoft Noticias'            1 'App de noticias con publicidad.'
    B $G1 'Microsoft.BingSearch'                'Microsoft Bing'                1 'App de búsqueda de Bing. La búsqueda de Windows sigue funcionando.'
    B $G1 'Microsoft.News'                      'Noticias (antigua)'            1 'App de noticias.'
    B $G1 'Microsoft.GetHelp'                   'Obtener ayuda'                 1 'Asistente de soporte online.'
    B $G1 'Microsoft.Getstarted'                'Sugerencias'                   1 'Consejos y promociones de Windows.'
    B $G1 'Microsoft.MicrosoftOfficeHub'        'Microsoft 365 (lanzador)'      1 'NO desinstala Office: solo la app promocional de Microsoft 365.'
    B $G1 'Microsoft.M365Companions'            'Microsoft 365 Companions'      1 'Mini apps auxiliares de Microsoft 365. No afecta a Office.'
    B $G1 'Microsoft.People'                    'Contactos (People)'            1 'App de contactos obsoleta.'
    B $G1 'Microsoft.PowerAutomateDesktop'      'Power Automate'                1 'Automatización para empresas; casi nadie la usa en casa.'
    B $G1 'Microsoft.WindowsFeedbackHub'        'Centro de opiniones'           1 'Para enviar comentarios a Microsoft.'
    B $G1 'Microsoft.WindowsMaps'               'Mapas'                         1 'App de mapas sin mantenimiento.'
    B $G1 'Microsoft.ZuneVideo'                 'Películas y TV'                1 'Tienda de vídeo de Microsoft (abandonada).'
    B $G1 'Microsoft.549981C3F5F10'             'Cortana'                       1 'Asistente retirado por Microsoft.'
    B $G1 'Microsoft.SkypeApp'                  'Skype'                         1 'Servicio cerrado por Microsoft en 2025.'
    B $G1 'Microsoft.MixedReality.Portal'       'Portal de realidad mixta'      1 'Solo útil con gafas de realidad mixta.'
    B $G1 'Microsoft.Microsoft3DViewer'         'Visor 3D'                      1 'Visor de modelos 3D.'
    B $G1 'Microsoft.Print3D'                   'Print 3D'                      1 'Impresión 3D.'
    B $G1 'Microsoft.Windows.DevHome'           'Dev Home'                      1 'Herramienta para desarrolladores retirada por Microsoft.'
    B $G1 'Microsoft.Wallet'                    'Microsoft Pay'                 1 'Servicio retirado.'
    B $G1 'Microsoft.Messaging'                 'Mensajes'                      1 'App obsoleta.'
    B $G1 'Microsoft.OneConnect'                'Planes móviles'                1 'App de operadoras móviles.'
    B $G1 'Microsoft.Office.Sway'               'Sway'                          1 'App de presentaciones web.'
    B $G1 'MicrosoftCorporationII.MicrosoftFamily' 'Microsoft Family'           1 'Control parental online (se gestiona igual desde la web).'
    B $G1 'Clipchamp.Clipchamp'                 'Clipchamp'                     1 'Editor de vídeo online preinstalado.'
    B $G1 '*CandyCrush*'                        'Candy Crush'                   1 'Juego promocional preinstalado.'
    B $G1 '*BubbleWitch*'                       'Bubble Witch'                  1 'Juego promocional preinstalado.'
    B $G1 'king.com.*'                          'Juegos de King'                1 'Juego promocional preinstalado.'
    B $G1 '*MarchofEmpires*'                    'March of Empires'              1 'Juego promocional preinstalado.'
    B $G1 '*HiddenCity*'                        'Hidden City'                   1 'Juego promocional preinstalado.'
    B $G1 '*RoyalRevolt*'                       'Royal Revolt'                  1 'Juego promocional preinstalado.'
    B $G1 '*FarmVille*'                         'FarmVille'                     1 'Juego promocional preinstalado.'
    B $G1 '*Facebook*'                          'Facebook'                      1 'Acceso directo promocional.'
    B $G1 '*Instagram*'                         'Instagram'                     1 'Acceso directo promocional.'
    B $G1 '*TikTok*'                            'TikTok'                        1 'Acceso directo promocional.'
    B $G1 '*Twitter*'                           'Twitter / X'                   1 'Acceso directo promocional.'
    B $G1 '*LinkedIn*'                          'LinkedIn'                      1 'Acceso directo promocional.'
    B $G1 '*McAfee*'                            'McAfee (prueba)'               1 'Antivirus de prueba; Windows ya incluye Microsoft Defender.'
    B $G1 '*Duolingo*'                          'Duolingo'                      1 'Acceso directo promocional.'
    B $G1 '*PicsArt*'                           'PicsArt'                       1 'Acceso directo promocional.'

    B $G2 'Microsoft.BingWeather'               'El Tiempo'                     0 'App del tiempo.'
    B $G2 'Microsoft.MicrosoftSolitaireCollection' 'Microsoft Solitaire'        0 'Solitario con anuncios.'
    B $G2 'Microsoft.Todos'                     'Microsoft To Do'               0 'Lista de tareas.'
    B $G2 'MicrosoftTeams'                      'Microsoft Teams (personal)'    0 'Versión gratuita/personal. No es el Teams del trabajo (MSTeams), que no se toca.'
    B $G2 'MicrosoftWindows.Client.WebExperience' 'Widgets'                     0 'Panel de widgets (tiempo, noticias) de la barra de tareas.'
    B $G2 'Microsoft.Copilot'                   'Copilot'                       0 'Asistente de IA de Microsoft.'
    B $G2 'Microsoft.MicrosoftPCManager'        'Microsoft PC Manager'          0 'Optimizador de Microsoft (esta app ya hace lo mismo).'
    B $G2 'Microsoft.OutlookForWindows'         'Outlook (nuevo)'               0 'Cliente de correo. No afecta a Outlook de Office.'
    B $G2 'microsoft.windowscommunicationsapps' 'Correo y Calendario'           0 'Apps antiguas de correo.'
    B $G2 'Microsoft.YourPhone'                 'Enlace móvil'                  0 'Conecta tu móvil con el PC.'
    B $G2 'Microsoft.ZuneMusic'                 'Reproductor multimedia'        0 'Reproductor de música y vídeo de Windows.'
    B $G2 'Microsoft.WindowsSoundRecorder'      'Grabadora de sonido'           0 'Grabadora de audio.'
    B $G2 'Microsoft.WindowsAlarms'             'Reloj / Alarmas'               0 'Alarmas, temporizador y sesiones de concentración.'
    B $G2 'Microsoft.WindowsCamera'             'Cámara'                        0 'App de cámara.'
    B $G2 'Microsoft.MicrosoftStickyNotes'      'Notas rápidas'                 0 'Notas adhesivas.'
    B $G2 'Microsoft.Office.OneNote'            'OneNote para Windows 10'       0 'Versión antigua de OneNote.'
    B $G2 'Microsoft.MicrosoftJournal'          'Microsoft Journal'             0 'Notas a mano alzada.'
    B $G2 'MicrosoftCorporationII.QuickAssist'  'Asistencia rápida'             0 'Soporte remoto entre PCs.'
    B $G2 'SpotifyAB.SpotifyMusic'              'Spotify'                       0 'Quítala solo si no la usas.'
    B $G2 '*Netflix*'                           'Netflix'                       0 'Quítala solo si no la usas.'
    B $G2 'Disney.*'                            'Disney+'                       0 'Quítala solo si no la usas.'
    B $G2 'AmazonVideo.PrimeVideo'              'Prime Video'                   0 'Quítala solo si no la usas.'
    B $G2 '5319275A.WhatsAppDesktop'            'WhatsApp'                      0 'Quítala solo si no la usas.'

    B $G3 'Microsoft.GamingApp'                 'Xbox'                          0 'App de Xbox / Game Pass. Déjala si juegas en PC.'
    B $G3 'Microsoft.XboxApp'                   'Xbox (antigua)'                0 'Versión antigua de la app de Xbox.'
    B $G3 'Microsoft.XboxGamingOverlay'         'Xbox Game Bar'                 0 'Barra Win+G (también graba la pantalla). Déjala si juegas.'
    B $G3 'Microsoft.XboxGameOverlay'           'Xbox Game Overlay'             0 'Superposición de juegos.'
    B $G3 'Microsoft.XboxSpeechToTextOverlay'   'Xbox voz a texto'              0 'Chat de voz en juegos.'
    B $G3 'Microsoft.Edge.GameAssist'           'Edge Game Assist'              1 'Navegador superpuesto para juegos.'
)

function Get-UserAppx([string]$Name) {
    $p = @{ ErrorAction = 'SilentlyContinue' }
    if ($Name) { $p.Name = $Name }
    if ($script:OtherUser) { $p.User = $TargetSid }
    Get-AppxPackage @p
}

function Get-BloatItems {
    $out  = @()
    $pkgs = @(Get-UserAppx | Where-Object { -not $_.NonRemovable -and -not $_.IsFramework })
    $seen = @{}
    foreach ($b in $BloatCatalog) {
        foreach ($p in @($pkgs | Where-Object { $_.Name -like $b.P })) {
            if ($seen.ContainsKey($p.Name)) { continue }
            $seen[$p.Name] = $true
            $out += [pscustomobject]@{ Kind = 'appx'; Group = $b.G; Name = $b.N; Id = $p.Name; Default = $b.D; Note = $b.Note; Uninstall = $null }
        }
    }
    # OneDrive (programa clásico, por usuario). Si se eleva con otra cuenta no se ofrece:
    # su desinstalador actuaría sobre la cuenta del administrador.
    if (-not $script:OtherUser) {
        foreach ($k in "$script:HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe",
                       'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                       'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') {
            $od = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
            if ($od -and $od.UninstallString) {
                $out += [pscustomobject]@{ Kind = 'onedrive'; Group = $G2; Name = 'Microsoft OneDrive'; Id = 'OneDrive'; Default = $false
                    Note = 'Deja de sincronizar. Tus archivos siguen en la nube y los ya descargados se quedan en el PC.'; Uninstall = $od.UninstallString }
                break
            }
        }
    }
    return $out
}

function Remove-BloatItem($b, $provList) {
    if ($b.Kind -eq 'onedrive') {
        Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $s = $b.Uninstall.Trim()
        if ($s.StartsWith('"')) {
            $end = $s.IndexOf('"', 1); $exe = $s.Substring(1, $end - 1); $argStr = $s.Substring($end + 1).Trim()
        } else {
            $i = $s.IndexOf(' /')
            if ($i -gt 0) { $exe = $s.Substring(0, $i); $argStr = $s.Substring($i + 1).Trim() } else { $exe = $s; $argStr = '' }
        }
        if ($argStr -notmatch '/uninstall') { $argStr = ($argStr + ' /uninstall').Trim() }
        $p = Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden -PassThru
        Wait-Proc $p
        if ($p.ExitCode -ne 0) { throw "El desinstalador devolvió el código $($p.ExitCode)." }
        return
    }
    foreach ($x in @(Get-UserAppx -Name $b.Id)) {
        if ($script:OtherUser) { Remove-AppxPackage -Package $x.PackageFullName -User $TargetSid -ErrorAction Stop }
        else { Remove-AppxPackage -Package $x.PackageFullName -ErrorAction Stop }
        [System.Windows.Forms.Application]::DoEvents()
    }
    # Evitar que Windows la vuelva a instalar (para usuarios nuevos / tras actualizaciones grandes)
    foreach ($pp in @($provList | Where-Object { $_.DisplayName -eq $b.Id })) {
        Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
}

# ============================================================ 3. OPTIMIZAR ====
# Ajustes de registro reversibles: antes de cambiar nada se guarda el valor original
# en %LOCALAPPDATA%\LimpiadorWindows\ajustes-originales.json
function RegVal($Root, $Path, $Name, $Value, $Type) { [pscustomobject]@{ Root = $Root; Path = $Path; Name = $Name; Value = $Value; Type = $Type } }
function Get-RegFull($rv) { if ($rv.Root -eq 'HKCU') { "$script:HKCU\$($rv.Path)" } else { "Registry::HKEY_LOCAL_MACHINE\$($rv.Path)" } }
function Get-RegKeyId($rv) { "$($rv.Root)\$($rv.Path)\$($rv.Name)" }
function Get-RegValue($rv) {
    try { (Get-ItemProperty -LiteralPath (Get-RegFull $rv) -Name $rv.Name -ErrorAction Stop).($rv.Name) } catch { $null }
}
function Set-RegValue($rv, $value) {
    $p = Get-RegFull $rv
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -LiteralPath $p -Name $rv.Name -Value $value -PropertyType $rv.Type -Force | Out-Null
}
function Remove-RegValue($rv) { Remove-ItemProperty -LiteralPath (Get-RegFull $rv) -Name $rv.Name -ErrorAction SilentlyContinue }

function Get-Backup {
    $h = @{}
    if (Test-Path -LiteralPath $script:BackupFile) {
        try {
            $o = Get-Content -Raw -LiteralPath $script:BackupFile | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { }
    }
    return $h
}
function Save-Backup($h) {
    try { $h | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8 } catch { Write-Log "  Aviso: no se pudo guardar la copia de seguridad: $($_.Exception.Message)" }
}

function Test-RegToggle($o) {
    foreach ($rv in $o.Values) {
        if ((@(Get-RegValue $rv) -join ',') -ne (@($rv.Value) -join ',')) { return $false }
    }
    return $true
}
function Set-RegToggle($o) {
    $bk = Get-Backup
    foreach ($rv in $o.Values) {
        $key = Get-RegKeyId $rv
        if (-not $bk.ContainsKey($key)) {
            $cur = Get-RegValue $rv
            $bk[$key] = [pscustomobject]@{ Exists = ($null -ne $cur); Value = $cur }
        }
        Set-RegValue $rv $rv.Value
    }
    Save-Backup $bk
    Write-Log '  Aplicado. Valores originales guardados para poder deshacerlo.'
}
function Undo-RegToggle($o) {
    $bk = Get-Backup; $n = 0
    foreach ($rv in $o.Values) {
        $key = Get-RegKeyId $rv
        if ($bk.ContainsKey($key)) {
            $b = $bk[$key]
            if ($b.Exists) {
                $v = $b.Value
                if ($rv.Type -eq 'Binary') { $v = [byte[]]@($v) }
                Set-RegValue $rv $v
            } else { Remove-RegValue $rv }
            $bk.Remove($key); $n++
        }
    }
    Save-Backup $bk
    return $n
}
function Test-HasBackup($o) {
    $bk = Get-Backup
    if ($o.Id -eq 'hibernate') { return $bk.ContainsKey('powercfg:hibernate') }
    foreach ($rv in $o.Values) { if ($bk.ContainsKey((Get-RegKeyId $rv))) { return $true } }
    return $false
}

function Get-DiskSummary {
    try {
        $t = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            switch ("$($_.MediaType)") { 'SSD' { 'SSD' } 'HDD' { 'HDD' } default { 'virtual/otro' } }
        } | Select-Object -Unique)
        return ($t -join ', ')
    } catch { return 'desconocido' }
}

function Get-HiberFile { $f = New-Object System.IO.FileInfo "$SD\hiberfil.sys"; try { if ($f.Exists) { return $f } } catch { }; return $null }

function New-Opt {
    param([string]$Id, [string]$Group, [string]$Name, [string]$Note, [string]$Desc, [switch]$Admin, [bool]$Default = $false,
          [scriptblock]$Status, [scriptblock]$Run, [object[]]$Values, [scriptblock]$Apply, [scriptblock]$Undo)
    [pscustomobject]@{ Id = $Id; Group = $Group; Name = $Name; Note = $Note; Desc = $Desc; Admin = [bool]$Admin; Default = $Default
                       Status = $Status; Run = $Run; Values = $Values; Apply = $Apply; Undo = $Undo }
}

$OG1 = 'Mantenimiento (herramientas oficiales de Windows)'
$OG2 = 'Ajustes reversibles'

$vmHint = ''
if ($script:IsVM) { $vmHint = ' En una máquina virtual, después usa la opción de compactar / liberar espacio de tu software (Parallels, VMware, Hyper-V, VirtualBox) para que el anfitrión recupere el espacio.' }

$hiberNote = if ($script:IsLaptop) { 'En portátiles protege tu trabajo si se agota la batería: desactívala solo si no la usas.' }
             else { 'Libera tanto espacio como indica el estado. También desactiva el Inicio rápido.' }

$Optimizations = @(
    New-Opt -Id defrag -Group $OG1 -Name 'Optimizar unidades (TRIM / desfragmentar)' -Admin -Default $true `
        -Note $(if ($script:IsVM) { 'Seguro. En máquinas virtuales ayuda a devolver espacio al anfitrión.' } else { 'Seguro. Windows elige TRIM (SSD) o desfragmentación (HDD).' }) `
        -Desc ('Ejecuta la optimización oficial de Windows (defrag /C /O) en todas las unidades: TRIM en SSD y desfragmentación en discos mecánicos. No toca tus datos.' + $vmHint) `
        -Status { 'Discos: ' + (Get-DiskSummary) } `
        -Run {
            $c = Invoke-Tool 'defrag.exe' @('/C', '/O', '/H')
            if ($c -eq 0) { Write-Log '  Unidades optimizadas.' } else { Write-Log "  defrag terminó con código $c." }
            if ($script:IsVM) { Write-Log '  Consejo: ahora compacta el disco virtual desde tu software de virtualización.' }
        }

    New-Opt -Id dismrestore -Group $OG1 -Name 'Reparar imagen de Windows (DISM)' -Admin `
        -Note 'Seguro. Requiere Internet. 10-30 minutos.' `
        -Desc 'Ejecuta "DISM /Online /Cleanup-Image /RestoreHealth": comprueba y repara el almacén de componentes de Windows usando Windows Update. Conviene ejecutarlo antes de SFC.' `
        -Run {
            $c = Invoke-Tool 'dism.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth')
            if ($c -eq 0) { Write-Log '  Imagen de Windows correcta o reparada.' } else { Write-Log "  DISM terminó con código $c (detalles en $W\Logs\DISM\dism.log)." }
        }

    New-Opt -Id sfc -Group $OG1 -Name 'Comprobar archivos del sistema (SFC)' -Admin `
        -Note 'Seguro. Repara archivos de Windows dañados. 10-20 minutos.' `
        -Desc 'Ejecuta "sfc /scannow": verifica todos los archivos protegidos de Windows y repara los que estén dañados.' `
        -Run {
            $c = Invoke-Tool 'sfc.exe' @('/scannow')
            Write-Log "  SFC terminado (código $c). Detalles en $W\Logs\CBS\CBS.log"
        }

    New-Opt -Id chkdsk -Group $OG1 -Name 'Comprobar el disco del sistema (CHKDSK)' -Admin `
        -Note 'Seguro. Análisis en línea, no reinicia el equipo.' `
        -Desc "Ejecuta `"chkdsk $SD /scan`": busca errores en el sistema de archivos sin desmontar la unidad." `
        -Run {
            $c = Invoke-Tool 'chkdsk.exe' @($SD, '/scan')
            switch ($c) {
                0       { Write-Log '  No se encontraron errores.' }
                1       { Write-Log '  Se encontraron y corrigieron errores.' }
                2       { Write-Log '  Sin errores; se hizo limpieza de mantenimiento.' }
                default { Write-Log "  Hay errores que no se pudieron corregir en línea (código $c). Reinicia y ejecuta 'chkdsk $SD /f' desde una consola de administrador." }
            }
        }

    New-Opt -Id visual -Group $OG2 -Name 'Efectos visuales en modo rendimiento' `
        -Default ($script:IsVM -or ($script:RamGB -gt 0 -and $script:RamGB -lt 8)) `
        -Note 'Reversible. Quita animaciones, sombras y transparencias. Se aplica del todo al cerrar sesión.' `
        -Desc 'Desactiva animaciones de ventanas y barra de tareas, sombras, transparencias y Aero Peek. Mantiene el suavizado de fuentes. Útil en equipos modestos y máquinas virtuales.' `
        -Values @(
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3 'DWord'
            RegVal 'HKCU' 'Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
            RegVal 'HKCU' 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 'DWord'
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0 'DWord'
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 'DWord'
            RegVal 'HKCU' 'Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 'DWord'
        )

    New-Opt -Id hibernate -Group $OG2 -Name 'Desactivar la hibernación' -Admin `
        -Default ([bool](Get-HiberFile) -and -not $script:IsLaptop) `
        -Note ('Reversible. ' + $hiberNote) `
        -Desc 'Ejecuta "powercfg /hibernate off" y elimina hiberfil.sys, que suele ocupar el 40 % de la RAM. Se puede volver a activar con "Deshacer ajustes".' `
        -Status { $f = Get-HiberFile; if ($f) { 'Activa · ' + (Format-Size $f.Length) } else { 'Desactivada' } } `
        -Apply {
            if (-not (Get-HiberFile)) { Write-Log '  La hibernación ya estaba desactivada.'; return }
            $bk = Get-Backup; $bk['powercfg:hibernate'] = 'on'; Save-Backup $bk
            $c = Invoke-Tool 'powercfg.exe' @('/hibernate', 'off')
            if ($c -eq 0) { Write-Log '  Hibernación desactivada.' } else { Write-Log "  powercfg terminó con código $c." }
        } `
        -Undo {
            Invoke-Tool 'powercfg.exe' @('/hibernate', 'on') | Out-Null
            $bk = Get-Backup; $bk.Remove('powercfg:hibernate'); Save-Backup $bk
            Write-Log '  Hibernación reactivada.'
        }
)

function Get-OptStatus($o) {
    if ($o.Status) { return [string](& $o.Status) }
    if ($o.Values) { if (Test-RegToggle $o) { return 'Aplicado' } else { return 'No aplicado' } }
    return ''
}

# ============================================================== 4. ESPACIO ====
$script:BigMin = 20MB
$script:ProtectedRoots = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
    "$SD\Recovery", "$SD\System Volume Information", ($SD + '\$Recycle.Bin')) | Where-Object { $_ }

function Test-Protected([string]$p) {
    if ([IO.Path]::GetFileName($p) -in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'DumpStack.log.tmp') { return $true }
    foreach ($r in $script:ProtectedRoots) {
        if ($p.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Measure-Tree([string]$path, $big) {
    $total = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo $path))
    while ($stack.Count -gt 0 -and -not $script:Cancel) {
        $d = $stack.Pop()
        $entries = $null
        try { $entries = $d.GetFileSystemInfos() } catch { }
        if ($null -eq $entries) { continue }
        foreach ($e in $entries) {
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e) }
            else {
                $total += $e.Length
                if ($e.Length -ge $script:BigMin) { $big.Add($e) }
            }
        }
        Pump
    }
    return $total
}

function Get-DownloadsPath {
    try {
        $k = Get-Item -LiteralPath "$script:HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop
        $v = $k.GetValue('{374DE290-123F-4565-9164-39C4925E467B}', $null, 'DoNotExpandEnvironmentNames')
        if ($v) {
            $v = $v -replace '%USERPROFILE%', $TargetProfile.Replace('$', '$$')
            $v = [Environment]::ExpandEnvironmentVariables($v)
            if ([IO.Directory]::Exists($v)) { return $v }
        }
    } catch { }
    return (Join-Path $TargetProfile 'Downloads')
}

# ------------------------------------------------------- Modo solo consola ----
if ($Analizar) {
    Write-Host "$AppName $AppVersion - análisis (no se borra nada)"
    Write-Host "Equipo: $script:Machine · RAM: $script:RamGB GB · Discos: $(Get-DiskSummary) · Administrador: $script:IsAdmin`n"
    $total = [long]0
    foreach ($c in $Categories) {
        $b = Measure-Cat $c
        if ($b -gt 0) { $total += $b }
        '{0,-50} {1,12}' -f $c.Name, (Format-Size $b) | Write-Host
    }
    Write-Host ("`n{0,-50} {1,12}" -f 'TOTAL', (Format-Size $total))
    Write-Host "`nBloatware detectado:"
    foreach ($b in (Get-BloatItems)) {
        $mark = if ($b.Default) { '[x]' } else { '[ ]' }
        '  {0} {1,-32} {2}' -f $mark, $b.Name, $b.Id | Write-Host
    }
    Write-Host "`nOptimizaciones:"
    foreach ($o in $Optimizations) {
        $mark = if ($o.Default) { '[x]' } else { '[ ]' }
        '  {0} {1,-48} {2}' -f $mark, $o.Name, (Get-OptStatus $o) | Write-Host
    }
    return
}

# ===================================================================== UI =====
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class LimpiadorDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[void][LimpiadorDpi]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = $g.DpiX / 96.0
$g.Dispose()
function S([double]$v) { [int]($v * $script:Scale) }

$Accent  = [System.Drawing.Color]::FromArgb(0, 103, 192)
$Danger  = [System.Drawing.Color]::FromArgb(196, 43, 28)
$BgColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$White   = [System.Drawing.Color]::White

# ---------- Helpers de UI
function Add-AutoLastColumn($lv) {
    $lv.Add_Resize({
        param($s, $e)
        $sum = 0
        for ($i = 0; $i -lt $s.Columns.Count - 1; $i++) { $sum += $s.Columns[$i].Width }
        $w = $s.ClientSize.Width - $sum - 4
        if ($w -gt (S 120)) { $s.Columns[$s.Columns.Count - 1].Width = $w }
    })
}

function New-LV([object[]]$cols, [bool]$checks) {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'
    $lv.View = 'Details'
    $lv.CheckBoxes = $checks
    $lv.FullRowSelect = $true
    $lv.ShowGroups = $true
    $lv.HideSelection = $false
    $lv.HeaderStyle = 'Nonclickable'
    $lv.BorderStyle = 'None'
    $lv.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    foreach ($c in $cols) {
        $align = 'Left'; if ($c.Count -gt 2) { $align = $c[2] }
        [void]$lv.Columns.Add($c[0], (S $c[1]), $align)
    }
    Add-AutoLastColumn $lv
    return $lv
}

# Evita cambios de casillas mientras la app trabaja y en opciones que requieren administrador
function Add-CheckGuard($lv) {
    $lv.Add_ItemCheck({
        param($s, $e)
        if ($script:Busy -and -not $script:Internal) { $e.NewValue = $e.CurrentValue; return }
        $tag = $s.Items[$e.Index].Tag
        if ($tag.Admin -and -not $script:IsAdmin) { $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked }
    })
    $lv.Add_ItemChecked({ Update-Selection })
}

function Add-LVItem($lv, $groups, [string]$group, [string]$text, [string[]]$subs, $tag, [bool]$checked, [bool]$enabled) {
    if (-not $groups.Contains($group)) {
        $grp = New-Object System.Windows.Forms.ListViewGroup($group, $group)
        [void]$lv.Groups.Add($grp)
        $groups[$group] = $grp
    }
    $it = New-Object System.Windows.Forms.ListViewItem($text)
    foreach ($s in $subs) { [void]$it.SubItems.Add($s) }
    if (-not $enabled) { $it.ForeColor = [System.Drawing.Color]::Gray }
    $it.Group = $groups[$group]
    $it.Tag = $tag
    $it.Checked = $checked -and $enabled
    $script:Internal = $true
    [void]$lv.Items.Add($it)
    $script:Internal = $false
}

function New-Btn([string]$text, [bool]$primary, $color = $null) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.Height = S 38
    $b.Padding = New-Object System.Windows.Forms.Padding((S 10), (S 2), (S 10), (S 2))
    $b.Margin = New-Object System.Windows.Forms.Padding((S 6), 0, 0, 0)
    $b.FlatStyle = 'Flat'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($primary) {
        $b.BackColor = if ($color) { $color } else { $Accent }
        $b.ForeColor = $White
        $b.FlatAppearance.BorderSize = 0
        $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    } else {
        $b.BackColor = $White
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    }
    return $b
}

function New-Tab([string]$key, [string]$text) {
    $t = New-Object System.Windows.Forms.TabPage
    $t.Name = $key
    $t.Text = $text
    $t.BackColor = $White
    return $t
}

function New-OptionsBar {
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.Dock = 'Top'
    $f.Height = S 44
    $f.Padding = New-Object System.Windows.Forms.Padding((S 8), (S 8), (S 8), 0)
    $f.BackColor = $White
    $f.WrapContents = $false
    return $f
}

function New-Hint([string]$text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.ForeColor = [System.Drawing.Color]::Gray
    $l.Margin = New-Object System.Windows.Forms.Padding((S 16), (S 6), 0, 0)
    return $l
}

# ---------- Ventana
$form = New-Object System.Windows.Forms.Form
$form.Text = "$AppName $AppVersion"
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new((S 1100), (S 800))
$form.MinimumSize = [System.Drawing.Size]::new((S 860), (S 580))
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.BackColor = $BgColor

# ---------- Pestaña 1: Archivos basura
$list = New-LV @(@('Elemento', 380), @('Tamaño', 110, 'Right'), @('Nota', 500)) $true
$cg = @{}
foreach ($c in $Categories) {
    $allowed = (-not $c.Admin) -or $script:IsAdmin
    $note = if ($allowed) { $c.Note } else { '[Requiere administrador] ' + $c.Note }
    Add-LVItem $list $cg $c.Group $c.Name @('...', $note) $c $c.Default $allowed
}
$tabClean = New-Tab 'clean' 'Archivos basura'
$tabClean.Controls.Add($list)

# ---------- Pestaña 2: Bloatware
$bloatList = New-LV @(@('Aplicación', 260), @('Paquete', 300), @('Nota', 450)) $true
$bloatOpts = New-OptionsBar
$chkRestore = New-Object System.Windows.Forms.CheckBox
$chkRestore.Text = 'Crear punto de restauración antes'
$chkRestore.AutoSize = $true
$chkRestore.Checked = $script:IsAdmin
$chkRestore.Enabled = $script:IsAdmin
$chkProv = New-Object System.Windows.Forms.CheckBox
$chkProv.Text = 'Evitar que Windows las reinstale'
$chkProv.AutoSize = $true
$chkProv.Checked = $script:IsAdmin
$chkProv.Enabled = $script:IsAdmin
$chkProv.Margin = New-Object System.Windows.Forms.Padding((S 20), 0, 0, 0)
$bloatOpts.Controls.AddRange(@($chkRestore, $chkProv, (New-Hint 'Todas se pueden volver a instalar desde Microsoft Store.')))
$tabBloat = New-Tab 'bloat' 'Bloatware'
$tabBloat.Controls.Add($bloatList)
$tabBloat.Controls.Add($bloatOpts)

# ---------- Pestaña 3: Optimizar
$optList = New-LV @(@('Acción / ajuste', 360), @('Estado', 170), @('Nota', 480)) $true
$og = @{}
foreach ($o in $Optimizations) {
    $allowed = (-not $o.Admin) -or $script:IsAdmin
    $note = if ($allowed) { $o.Note } else { '[Requiere administrador] ' + $o.Note }
    Add-LVItem $optList $og $o.Group $o.Name @('...', $note) $o $o.Default $allowed
}
$optBar = New-OptionsBar
$optBar.Controls.Add((New-Hint "Equipo detectado: $script:Machine · RAM $script:RamGB GB · Discos: $(Get-DiskSummary). Las recomendaciones se adaptan a tu equipo."))
$tabOpt = New-Tab 'opt' 'Optimizar'
$tabOpt.Controls.Add($optList)
$tabOpt.Controls.Add($optBar)

# ---------- Pestaña 4: Espacio
$lvFolders = New-LV @(@('Tamaño', 95, 'Right'), @('%', 60, 'Right'), @('Carpeta', 260)) $false
$lvFolders.ShowGroups = $false
$lvFolders.MultiSelect = $false
$lvFiles = New-LV @(@('Archivo', 260), @('Tamaño', 100, 'Right'), @('Modificado', 100), @('Ubicación', 300)) $false
$lvFiles.ShowGroups = $false
$lvFiles.MultiSelect = $true

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Vertical'
$split.Panel1.Controls.Add($lvFolders)
$split.Panel2.Controls.Add($lvFiles)

$lblFoldersTitle = New-Object System.Windows.Forms.Label
$lblFoldersTitle.Text = '  Carpetas (doble clic para entrar)'
$lblFoldersTitle.Dock = 'Top'; $lblFoldersTitle.Height = S 24; $lblFoldersTitle.TextAlign = 'MiddleLeft'
$lblFoldersTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$split.Panel1.Controls.Add($lblFoldersTitle)
$lblFilesTitle = New-Object System.Windows.Forms.Label
$lblFilesTitle.Text = "  Archivos más grandes (más de $(Format-Size $script:BigMin))"
$lblFilesTitle.Dock = 'Top'; $lblFilesTitle.Height = S 24; $lblFilesTitle.TextAlign = 'MiddleLeft'
$lblFilesTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$split.Panel2.Controls.Add($lblFilesTitle)

$spaceBar = New-OptionsBar
$spaceBar.Height = S 52
$btnSpProfile   = New-Btn 'Mi perfil' $false
$btnSpDownloads = New-Btn 'Descargas' $false
$btnSpDrive     = New-Btn "Unidad $SD\" $false
$btnSpPick      = New-Btn 'Otra carpeta...' $false
$btnSpUp        = New-Btn 'Subir un nivel' $false
$spaceBar.Controls.AddRange(@($btnSpProfile, $btnSpDownloads, $btnSpDrive, $btnSpPick, $btnSpUp))
$lblSpPath = New-Object System.Windows.Forms.Label
$lblSpPath.Dock = 'Top'
$lblSpPath.Height = S 26
$lblSpPath.Padding = New-Object System.Windows.Forms.Padding((S 10), 0, 0, 0)
$lblSpPath.TextAlign = 'MiddleLeft'
$lblSpPath.BackColor = $White
$lblSpPath.Text = 'Elige una carpeta para analizar.'

$tabSpace = New-Tab 'space' 'Espacio'
$tabSpace.Controls.Add($split)
$tabSpace.Controls.Add($lblSpPath)
$tabSpace.Controls.Add($spaceBar)

# ---------- Pestañas
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point((S 16), (S 6))
$tabs.TabPages.AddRange(@($tabClean, $tabBloat, $tabOpt, $tabSpace))

# ---------- Descripción
$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Dock = 'Bottom'
$lblDesc.Height = S 52
$lblDesc.Padding = New-Object System.Windows.Forms.Padding((S 14), (S 6), (S 14), (S 6))
$lblDesc.BackColor = $White
$lblDesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

$DescDefault = @{
    clean = 'Selecciona un elemento para ver qué se borra exactamente.'
    bloat = 'Selecciona una app para ver qué es. Solo se muestran apps de una lista segura: nunca componentes del sistema.'
    opt   = 'Selecciona una acción para ver qué hace. Los ajustes guardan su valor original y se pueden deshacer.'
    space = 'Solo muestra información. Si envías algo a la papelera, puedes recuperarlo desde ella. Las carpetas de Windows y de programas están protegidas.'
}
$lblDesc.Text = $DescDefault.clean

# ---------- Registro
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = 'Bottom'
$logBox.Height = S 140
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BorderStyle = 'None'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$script:LogBox = $logBox

# ---------- Barra inferior
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'
$bottom.Height = S 62
$bottom.Padding = New-Object System.Windows.Forms.Padding((S 14), (S 10), (S 14), (S 10))

$left = New-Object System.Windows.Forms.Panel
$left.Dock = 'Fill'
$left.Padding = New-Object System.Windows.Forms.Padding(0, 0, (S 16), 0)
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Fill'
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.AutoEllipsis = $true
$lblStatus.Text = 'Listo.'
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Bottom'
$progress.Height = S 6
$left.Controls.Add($lblStatus)
$left.Controls.Add($progress)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Right'
$flow.AutoSize = $true
$flow.AutoSizeMode = 'GrowAndShrink'
$flow.WrapContents = $false

$TabButtons = [ordered]@{
    clean = @((New-Btn 'Volver a analizar' $false), (New-Btn 'Recomendados' $false), (New-Btn 'Ninguno' $false), (New-Btn 'Limpiar seleccionados' $true))
    bloat = @((New-Btn 'Volver a buscar' $false), (New-Btn 'Recomendados' $false), (New-Btn 'Ninguno' $false), (New-Btn 'Desinstalar seleccionadas' $true $Danger))
    opt   = @((New-Btn 'Deshacer ajustes' $false), (New-Btn 'Recomendados' $false), (New-Btn 'Ninguno' $false), (New-Btn 'Aplicar seleccionadas' $true))
    space = @((New-Btn 'Volver a analizar' $false), (New-Btn 'Abrir ubicación' $false), (New-Btn 'Enviar a la papelera' $true $Danger))
}
$btnAnalyze, $btnRecom, $btnNone, $btnClean                       = $TabButtons.clean
$btnBloatReload, $btnBloatRecom, $btnBloatNone, $btnBloatRemove   = $TabButtons.bloat
$btnOptUndo, $btnOptRecom, $btnOptNone, $btnOptRun                = $TabButtons.opt
$btnSpRescan, $btnSpOpen, $btnSpTrash                             = $TabButtons.space
$btnCancel = New-Btn 'Cancelar' $false
$btnCancel.Visible = $false

$script:AllButtons = @()
foreach ($k in $TabButtons.Keys) { $script:AllButtons += $TabButtons[$k]; $flow.Controls.AddRange($TabButtons[$k]) }
$flow.Controls.Add($btnCancel)

$bottom.Controls.Add($left)
$bottom.Controls.Add($flow)

# ---------- Cabecera
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = S 78
$header.BackColor = $Accent
$header.Padding = New-Object System.Windows.Forms.Padding((S 16), (S 10), (S 16), (S 8))
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = $AppName
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$lblTitle.ForeColor = $White
$lblTitle.Dock = 'Top'
$lblTitle.AutoSize = $true
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(220, 235, 255)
$lblInfo.Dock = 'Bottom'
$lblInfo.AutoSize = $true
$header.Controls.Add($lblInfo)
$header.Controls.Add($lblTitle)

# Orden de acoplamiento: el control "Fill" se añade primero
$form.Controls.Add($tabs)
$form.Controls.Add($lblDesc)
$form.Controls.Add($logBox)
$form.Controls.Add($bottom)
$form.Controls.Add($header)

# ================================================================ Lógica =====
function Update-Info {
    $d = New-Object System.IO.DriveInfo $env:SystemDrive
    $adm = if ($script:IsAdmin) { 'Sí' } else { 'No (algunas opciones desactivadas)' }
    $txt = "Espacio libre en ${env:SystemDrive}: $(Format-Size $d.AvailableFreeSpace) de $(Format-Size $d.TotalSize)    ·    $script:Machine, $script:RamGB GB RAM    ·    Administrador: $adm"
    if ($script:OtherUser) { $txt += "    ·    Perfil: $script:TargetName" }
    $lblInfo.Text = $txt
}

function Get-CurrentTab { $tabs.SelectedTab.Name }

function Update-Selection {
    if ($script:Busy) { return }
    switch (Get-CurrentTab) {
        'clean' {
            $sum = [long]0; $n = 0
            foreach ($it in @($list.Items | Where-Object { $_.Checked })) { $n++; if ($it.Tag.Bytes -gt 0) { $sum += $it.Tag.Bytes } }
            $lblStatus.Text = "Seleccionado: $n elementos · aprox. $(Format-Size $sum) a liberar"
        }
        'bloat' {
            $n = @($bloatList.Items | Where-Object { $_.Checked }).Count
            $lblStatus.Text = "Seleccionadas: $n de $($bloatList.Items.Count) apps"
        }
        'opt' {
            $n = @($optList.Items | Where-Object { $_.Checked }).Count
            $lblStatus.Text = "Seleccionadas: $n acciones"
        }
        'space' {
            $lblStatus.Text = $script:SpaceSummary
        }
    }
}

function Show-TabButtons {
    $k = Get-CurrentTab
    foreach ($key in $TabButtons.Keys) { foreach ($b in $TabButtons[$key]) { $b.Visible = ($key -eq $k) } }
}

function Set-Busy([bool]$on) {
    $script:Busy = $on
    foreach ($b in $script:AllButtons) { $b.Enabled = -not $on }
    $bloatOpts.Enabled = -not $on
    $spaceBar.Enabled = -not $on
    $form.Cursor = if ($on) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    if (-not $on) { $progress.Value = 0 }
}

function Confirm-Action([string]$msg, [string]$title, [string]$icon = 'Question') {
    return ([System.Windows.Forms.MessageBox]::Show($msg, $title, 'YesNo', $icon) -eq 'Yes')
}
function Show-Info([string]$msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, $AppName, 'OK', 'Information') }

# ---------- 1. Archivos basura
function Set-ItemSize($it) {
    $b = $it.Tag.Bytes
    $it.SubItems[1].Text = if ($b -eq 0) { 'Vacío' } else { Format-Size $b }
}

function Invoke-Analyze {
    Set-Busy $true
    Write-Log 'Analizando archivos basura...'
    $n = $list.Items.Count; $i = 0
    foreach ($it in $list.Items) {
        $i++
        $lblStatus.Text = "Analizando: $($it.Tag.Name)..."
        $progress.Value = [int](100 * ($i - 1) / $n)
        $it.SubItems[1].Text = 'Analizando...'
        [System.Windows.Forms.Application]::DoEvents()
        try { $it.Tag.Bytes = Measure-Cat $it.Tag } catch { $it.Tag.Bytes = -1 }
        Set-ItemSize $it
    }
    $total = [long]0
    foreach ($it in $list.Items) { if ($it.Tag.Bytes -gt 0) { $total += $it.Tag.Bytes } }
    Write-Log "Análisis terminado. Total recuperable estimado: $(Format-Size $total)"
    Set-Busy $false
    Update-Info
    Update-Selection
}

function Invoke-Clean {
    $sel = @($list.Items | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { Show-Info 'No hay nada seleccionado.'; return }
    $est = [long]0
    foreach ($it in $sel) { if ($it.Tag.Bytes -gt 0) { $est += $it.Tag.Bytes } }
    $names = ($sel | ForEach-Object { '  • ' + $_.Tag.Name }) -join "`n"
    if (-not (Confirm-Action "Se van a limpiar $($sel.Count) elementos (aprox. $(Format-Size $est)):`n`n$names`n`nLos archivos en uso se omitirán. ¿Continuar?" 'Confirmar limpieza')) { return }

    Set-Busy $true
    $freeBefore = Get-FreeSpace
    $grand = [long]0
    $i = 0
    Write-Log '===== Inicio de la limpieza ====='
    foreach ($it in $sel) {
        $i++
        $cat = $it.Tag
        $progress.Value = [int](100 * ($i - 1) / $sel.Count)
        $lblStatus.Text = "Limpiando: $($cat.Name)..."
        $it.SubItems[1].Text = 'Limpiando...'
        [System.Windows.Forms.Application]::DoEvents()
        Write-Log "Limpiando: $($cat.Name)"

        if ($cat.Bytes -eq 0) { Write-Log '  Nada que limpiar.'; Set-ItemSize $it; continue }

        if ($cat.Procs.Count -gt 0) {
            $running = @(Get-Process -Name $cat.Procs -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) { Write-Log "  Aviso: $($cat.Name) está abierto; ciérralo para limpiar por completo." }
        }

        $res = @{ Freed = [long]0; Files = 0; Failed = 0 }
        try {
            if ($cat.Action) {
                $byDrive = -not $cat.Targets
                $before = if ($byDrive) { Get-FreeSpace } else { Measure-Cat $cat }
                & $cat.Action $cat $res
                $after  = if ($byDrive) { Get-FreeSpace } else { Measure-Cat $cat }
                $res.Freed = if ($byDrive) { [Math]::Max([long]0, $after - $before) } else { [Math]::Max([long]0, $before - $after) }
            } else {
                foreach ($t in (Get-Targets $cat)) { Clear-Target $t $res }
            }
        } catch {
            Write-Log "  Error: $($_.Exception.Message)"
        }
        $grand += $res.Freed
        $extra = if ($res.Failed -gt 0) { " ($($res.Failed) archivos en uso omitidos)" } else { '' }
        Write-Log "  Liberado: $(Format-Size $res.Freed)$extra"

        try { $cat.Bytes = Measure-Cat $cat } catch { }
        Set-ItemSize $it
        $script:Internal = $true; $it.Checked = $false; $script:Internal = $false
    }
    $freeAfter = Get-FreeSpace
    Write-Log "===== Fin. Total liberado: $(Format-Size $grand) ====="
    Set-Busy $false
    Update-Info
    Update-Selection
    $msg = "Limpieza completada.`n`nEspacio liberado: $(Format-Size $grand)`nEspacio libre en ${env:SystemDrive}: $(Format-Size $freeBefore)  →  $(Format-Size $freeAfter)"
    if ($script:IsVM) { $msg += "`n`nEs una máquina virtual: ejecuta 'Optimizar unidades' en la pestaña Optimizar y compacta el disco virtual para que el anfitrión recupere el espacio." }
    Show-Info $msg
}

# ---------- 2. Bloatware
function Update-BloatList {
    Set-Busy $true
    $lblStatus.Text = 'Buscando bloatware instalado...'
    [System.Windows.Forms.Application]::DoEvents()
    $bloatList.BeginUpdate()
    $bloatList.Items.Clear()
    $bloatList.Groups.Clear()
    $bg = [ordered]@{}
    foreach ($name in $G1, $G2, $G3) {
        $bg[$name] = New-Object System.Windows.Forms.ListViewGroup($name, $name)
        [void]$bloatList.Groups.Add($bg[$name])
    }
    $items = @(Get-BloatItems)
    foreach ($b in $items) { Add-LVItem $bloatList $bg $b.Group $b.Name @($b.Id, $b.Note) $b $b.Default $true }
    $bloatList.EndUpdate()
    $script:BloatLoaded = $true
    Write-Log "Bloatware: $($items.Count) apps prescindibles encontradas."
    Set-Busy $false
    Update-Selection
}

function Invoke-BloatRemove {
    $sel = @($bloatList.Items | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { Show-Info 'No hay ninguna app seleccionada.'; return }
    $names = ($sel | ForEach-Object { '  • ' + $_.Tag.Name }) -join "`n"
    if (-not (Confirm-Action "Se van a desinstalar $($sel.Count) apps:`n`n$names`n`nSe pueden volver a instalar desde Microsoft Store. ¿Continuar?" 'Confirmar desinstalación' 'Warning')) { return }

    Set-Busy $true
    Write-Log '===== Desinstalación de bloatware ====='

    if ($chkRestore.Checked -and $script:IsAdmin) {
        $lblStatus.Text = 'Creando punto de restauración (puede tardar un minuto)...'
        Write-Log 'Creando punto de restauración...'
        $cmd = "try { Checkpoint-Computer -Description 'Limpiador de Windows: antes de quitar bloatware' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; exit 0 } catch { exit 1 }"
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', $cmd -WindowStyle Hidden -PassThru
        Wait-Proc $p
        if ($p.ExitCode -eq 0) {
            Write-Log '  Punto de restauración creado (o ya existía uno de las últimas 24 h).'
        } else {
            Write-Log '  No se pudo crear el punto de restauración (¿Protección del sistema desactivada?).'
            if (-not (Confirm-Action "No se pudo crear el punto de restauración.`nProbablemente la Protección del sistema está desactivada.`n`n¿Continuar de todas formas?" 'Punto de restauración' 'Warning')) {
                Write-Log 'Cancelado.'; Set-Busy $false; Update-Selection; return
            }
        }
    }

    $provList = @()
    if ($chkProv.Checked -and $script:IsAdmin) {
        $lblStatus.Text = 'Leyendo apps preinstaladas de Windows...'
        [System.Windows.Forms.Application]::DoEvents()
        try { $provList = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { Write-Log "  Aviso: $($_.Exception.Message)" }
    }

    $ok = 0; $fail = 0; $i = 0
    foreach ($it in $sel) {
        $i++
        $b = $it.Tag
        $progress.Value = [int](100 * ($i - 1) / $sel.Count)
        $lblStatus.Text = "Desinstalando: $($b.Name)..."
        [System.Windows.Forms.Application]::DoEvents()
        Write-Log "Desinstalando: $($b.Name) ($($b.Id))"
        try {
            Remove-BloatItem $b $provList
            Write-Log '  OK'
            $bloatList.Items.Remove($it)
            $ok++
        } catch {
            Write-Log "  Error: $($_.Exception.Message)"
            $it.ForeColor = [System.Drawing.Color]::Firebrick
            $fail++
        }
    }
    Write-Log "===== Fin. Desinstaladas: $ok · Con error: $fail ====="
    Set-Busy $false
    Update-Info
    Update-Selection
    $extra = if ($fail -gt 0) { "`nCon error: $fail (detalles en el registro inferior)" } else { '' }
    Show-Info "Desinstalación completada.`n`nDesinstaladas: $ok$extra"
}

# ---------- 3. Optimizar
function Update-OptList {
    foreach ($it in $optList.Items) {
        try { $it.SubItems[1].Text = Get-OptStatus $it.Tag } catch { $it.SubItems[1].Text = '?' }
    }
}

function Invoke-OptRun {
    $sel = @($optList.Items | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { Show-Info 'No hay ninguna acción seleccionada.'; return }
    $names = ($sel | ForEach-Object { '  • ' + $_.Tag.Name }) -join "`n"
    if (-not (Confirm-Action "Se va a ejecutar:`n`n$names`n`nAlgunas tareas pueden tardar varios minutos. No cierres la ventana mientras tanto. ¿Continuar?" 'Confirmar optimización')) { return }

    Set-Busy $true
    Write-Log '===== Optimización ====='
    $i = 0
    foreach ($it in $sel) {
        $i++
        $o = $it.Tag
        $progress.Value = [int](100 * ($i - 1) / $sel.Count)
        $lblStatus.Text = "Ejecutando: $($o.Name)... (puede tardar)"
        $it.SubItems[1].Text = 'En curso...'
        [System.Windows.Forms.Application]::DoEvents()
        Write-Log "Ejecutando: $($o.Name)"
        try {
            if ($o.Run) { & $o.Run }
            elseif ($o.Apply) { & $o.Apply }
            elseif ($o.Values) { Set-RegToggle $o }
        } catch {
            Write-Log "  Error: $($_.Exception.Message)"
        }
        $script:Internal = $true; $it.Checked = $false; $script:Internal = $false
        try { $it.SubItems[1].Text = Get-OptStatus $o } catch { }
    }
    Write-Log '===== Fin de la optimización ====='
    Set-Busy $false
    Update-Info
    Update-Selection
    Show-Info 'Optimización terminada. Revisa el registro inferior para ver los resultados.'
}

function Invoke-OptUndo {
    $undoable = @($Optimizations | Where-Object { ($_.Values -or $_.Undo) -and (Test-HasBackup $_) })
    if ($undoable.Count -eq 0) { Show-Info 'No hay ajustes aplicados por esta herramienta que deshacer.'; return }
    $names = ($undoable | ForEach-Object { '  • ' + $_.Name }) -join "`n"
    if (-not (Confirm-Action "Se restaurarán los valores originales de:`n`n$names`n`n¿Continuar?" 'Deshacer ajustes')) { return }
    Set-Busy $true
    Write-Log '===== Deshacer ajustes ====='
    foreach ($o in $undoable) {
        Write-Log "Restaurando: $($o.Name)"
        try {
            if ($o.Undo) { & $o.Undo }
            else { $n = Undo-RegToggle $o; Write-Log "  $n valores restaurados." }
        } catch { Write-Log "  Error: $($_.Exception.Message)" }
    }
    Update-OptList
    Set-Busy $false
    Update-Info
    Update-Selection
    Show-Info 'Ajustes restaurados. Algunos cambios visuales se aplican del todo al cerrar sesión.'
}

# ---------- 4. Espacio
$script:SpaceRoot = $null
$script:SpaceSummary = 'Elige una carpeta para analizar.'

function Invoke-SpaceScan([string]$root) {
    if (-not $root -or -not (Test-SafeRoot $root)) { Show-Info "No se puede analizar: $root"; return }
    $script:SpaceRoot = $root
    $lblSpPath.Text = "Carpeta: $root"
    $script:Cancel = $false
    Set-Busy $true
    $btnCancel.Visible = $true
    $btnCancel.Enabled = $true
    $lvFolders.Items.Clear()
    $lvFiles.Items.Clear()

    $big  = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $rows = @()
    $rootFiles = [long]0
    $entries = @()
    try { $entries = (New-Object System.IO.DirectoryInfo $root).GetFileSystemInfos() } catch { }
    $dirs = @($entries | Where-Object { $_ -is [System.IO.DirectoryInfo] -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 })
    foreach ($f in @($entries | Where-Object { $_ -is [System.IO.FileInfo] })) {
        $rootFiles += $f.Length
        if ($f.Length -ge $script:BigMin) { $big.Add($f) }
    }
    $i = 0
    foreach ($d in $dirs) {
        if ($script:Cancel) { break }
        $i++
        $progress.Value = [int](100 * ($i - 1) / [math]::Max(1, $dirs.Count))
        $lblStatus.Text = "Analizando: $($d.FullName)"
        [System.Windows.Forms.Application]::DoEvents()
        $rows += [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Size = (Measure-Tree $d.FullName $big) }
    }
    if ($rootFiles -gt 0) { $rows += [pscustomobject]@{ Name = '(archivos sueltos en esta carpeta)'; Path = $null; Size = $rootFiles } }

    $total = [long]0
    foreach ($r in $rows) { $total += $r.Size }

    $lvFolders.BeginUpdate()
    foreach ($r in ($rows | Sort-Object Size -Descending)) {
        $it = New-Object System.Windows.Forms.ListViewItem((Format-Size $r.Size))
        $pct = if ($total -gt 0) { '{0:N1} %' -f (100.0 * $r.Size / $total) } else { '' }
        [void]$it.SubItems.Add($pct)
        [void]$it.SubItems.Add($r.Name)
        $it.Tag = $r.Path
        [void]$lvFolders.Items.Add($it)
    }
    $lvFolders.EndUpdate()

    $lvFiles.BeginUpdate()
    foreach ($f in ($big | Sort-Object Length -Descending | Select-Object -First 200)) {
        $it = New-Object System.Windows.Forms.ListViewItem($f.Name)
        [void]$it.SubItems.Add((Format-Size $f.Length))
        [void]$it.SubItems.Add($f.LastWriteTime.ToString('yyyy-MM-dd'))
        [void]$it.SubItems.Add($f.DirectoryName)
        $it.Tag = $f.FullName
        if (Test-Protected $f.FullName) { $it.ForeColor = [System.Drawing.Color]::Gray }
        [void]$lvFiles.Items.Add($it)
    }
    $lvFiles.EndUpdate()

    $script:SpaceSummary = "$root · $(Format-Size $total)"
    if ($script:Cancel) { $script:SpaceSummary += ' (análisis cancelado: resultados parciales)' }
    Write-Log "Espacio: $script:SpaceSummary"
    $btnCancel.Visible = $false
    Set-Busy $false
    Update-Selection
}

function Open-Location([string]$path) {
    if (-not $path) { return }
    if ([IO.File]::Exists($path)) { Start-Process explorer.exe -ArgumentList "/select,`"$path`"" }
    elseif ([IO.Directory]::Exists($path)) { Start-Process explorer.exe -ArgumentList "`"$path`"" }
}

function Invoke-SpaceTrash {
    $sel = @($lvFiles.SelectedItems | ForEach-Object { $_ })
    if ($sel.Count -eq 0) { Show-Info 'Selecciona uno o varios archivos en la lista de la derecha.'; return }
    $prot = @($sel | Where-Object { Test-Protected $_.Tag })
    $sel  = @($sel | Where-Object { -not (Test-Protected $_.Tag) })
    if ($prot.Count -gt 0) { Write-Log "Se omiten $($prot.Count) archivos protegidos del sistema." }
    if ($sel.Count -eq 0) { Show-Info 'Los archivos seleccionados pertenecen a Windows o a programas instalados y están protegidos.'; return }
    $names = ($sel | Select-Object -First 15 | ForEach-Object { '  • ' + $_.Text + '  (' + $_.SubItems[1].Text + ')' }) -join "`n"
    if ($sel.Count -gt 15) { $names += "`n  ... y $($sel.Count - 15) más" }
    if (-not (Confirm-Action "Se enviarán a la papelera $($sel.Count) archivos:`n`n$names`n`nPodrás recuperarlos desde la papelera. ¿Continuar?" 'Enviar a la papelera' 'Warning')) { return }
    Set-Busy $true
    $ok = 0
    foreach ($it in $sel) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($it.Tag, 'OnlyErrorDialogs', 'SendToRecycleBin')
            Write-Log "Enviado a la papelera: $($it.Tag)"
            $lvFiles.Items.Remove($it)
            $ok++
        } catch {
            Write-Log "  Error con $($it.Tag): $($_.Exception.Message)"
        }
    }
    Set-Busy $false
    Update-Info
    Update-Selection
    Show-Info "$ok archivos enviados a la papelera.`nRecuerda vaciar la papelera para liberar el espacio."
}

# ================================================================ Eventos =====
$script:BloatLoaded = $false
$script:SpaceLoaded = $false

foreach ($lv in $list, $bloatList, $optList) { Add-CheckGuard $lv }

$tabs.Add_Selecting({ param($s, $e) if ($script:Busy) { $e.Cancel = $true } })
$tabs.Add_SelectedIndexChanged({
    $k = Get-CurrentTab
    Show-TabButtons
    $lblDesc.Text = $DescDefault[$k]
    if ($k -eq 'bloat' -and -not $script:BloatLoaded) { Update-BloatList; return }
    if ($k -eq 'space' -and -not $script:SpaceLoaded) {
        $script:SpaceLoaded = $true
        try { $split.SplitterDistance = [int]($split.ClientSize.Width * 0.42) } catch { }
        Invoke-SpaceScan $TargetProfile
        return
    }
    if ($k -eq 'opt') { Update-OptList }
    Update-Selection
})

# Descripciones
$list.Add_ItemSelectionChanged({ param($s, $e) if ($e.IsSelected) { $lblDesc.Text = "$($e.Item.Tag.Name): $($e.Item.Tag.Desc)" } })
$bloatList.Add_ItemSelectionChanged({ param($s, $e) if ($e.IsSelected) { $lblDesc.Text = "$($e.Item.Tag.Name): $($e.Item.Tag.Note)" } })
$optList.Add_ItemSelectionChanged({ param($s, $e) if ($e.IsSelected) { $lblDesc.Text = "$($e.Item.Tag.Name): $($e.Item.Tag.Desc)" } })
$lvFiles.Add_ItemSelectionChanged({
    param($s, $e)
    if ($e.IsSelected) {
        $p = $e.Item.Tag
        $txt = "$p  ·  $($e.Item.SubItems[1].Text)  ·  modificado $($e.Item.SubItems[2].Text)"
        if (Test-Protected $p) { $txt += '  ·  PROTEGIDO (archivo del sistema o de programas)' }
        $lblDesc.Text = $txt
    }
})

# Archivos basura
$btnAnalyze.Add_Click({ Invoke-Analyze })
$btnClean.Add_Click({ Invoke-Clean })
$btnNone.Add_Click({ foreach ($it in $list.Items) { $it.Checked = $false } })
$btnRecom.Add_Click({
    foreach ($it in $list.Items) {
        $c = $it.Tag
        $it.Checked = $c.Default -and ((-not $c.Admin) -or $script:IsAdmin) -and ($c.Bytes -ne 0)
    }
})

# Bloatware
$btnBloatReload.Add_Click({ Update-BloatList })
$btnBloatRemove.Add_Click({ Invoke-BloatRemove })
$btnBloatNone.Add_Click({ foreach ($it in $bloatList.Items) { $it.Checked = $false } })
$btnBloatRecom.Add_Click({ foreach ($it in $bloatList.Items) { $it.Checked = $it.Tag.Default } })

# Optimizar
$btnOptRun.Add_Click({ Invoke-OptRun })
$btnOptUndo.Add_Click({ Invoke-OptUndo })
$btnOptNone.Add_Click({ foreach ($it in $optList.Items) { $it.Checked = $false } })
$btnOptRecom.Add_Click({ foreach ($it in $optList.Items) { $it.Checked = $it.Tag.Default -and ((-not $it.Tag.Admin) -or $script:IsAdmin) } })

# Espacio
$btnSpProfile.Add_Click({ Invoke-SpaceScan $TargetProfile })
$btnSpDownloads.Add_Click({ Invoke-SpaceScan (Get-DownloadsPath) })
$btnSpDrive.Add_Click({ Invoke-SpaceScan ($SD + '\') })
$btnSpPick.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Elige la carpeta que quieres analizar'
    if ($script:SpaceRoot) { $dlg.SelectedPath = $script:SpaceRoot }
    if ($dlg.ShowDialog($form) -eq 'OK') { Invoke-SpaceScan $dlg.SelectedPath }
})
$btnSpUp.Add_Click({
    if ($script:SpaceRoot) {
        $parent = [IO.Path]::GetDirectoryName($script:SpaceRoot.TrimEnd('\'))
        if ($parent) { Invoke-SpaceScan $parent } else { Invoke-SpaceScan ([IO.Path]::GetPathRoot($script:SpaceRoot)) }
    }
})
$btnSpRescan.Add_Click({ if ($script:SpaceRoot) { Invoke-SpaceScan $script:SpaceRoot } })
$btnSpOpen.Add_Click({
    if ($lvFiles.SelectedItems.Count -gt 0) { Open-Location $lvFiles.SelectedItems[0].Tag }
    elseif ($lvFolders.SelectedItems.Count -gt 0) { Open-Location $lvFolders.SelectedItems[0].Tag }
    else { Open-Location $script:SpaceRoot }
})
$btnSpTrash.Add_Click({ Invoke-SpaceTrash })
$lvFolders.Add_DoubleClick({ if (-not $script:Busy -and $lvFolders.SelectedItems.Count -gt 0 -and $lvFolders.SelectedItems[0].Tag) { Invoke-SpaceScan $lvFolders.SelectedItems[0].Tag } })
$lvFiles.Add_DoubleClick({ if ($lvFiles.SelectedItems.Count -gt 0) { Open-Location $lvFiles.SelectedItems[0].Tag } })
$btnCancel.Add_Click({ $script:Cancel = $true; $btnCancel.Enabled = $false; $lblStatus.Text = 'Cancelando...' })

$form.Add_Shown({
    $form.Activate()
    Show-TabButtons
    Update-Info
    Write-Log "$AppName $AppVersion · $script:Machine · $script:RamGB GB RAM · Discos: $(Get-DiskSummary)"
    if (-not $script:IsAdmin) { Write-Log 'Sin permisos de administrador: las opciones del sistema están desactivadas.' }
    if ($script:OtherUser) { Write-Log "Ejecutando como administrador con otra cuenta: se limpia el perfil de $script:TargetName." }
    Update-OptList
    Invoke-Analyze
})

[void]$form.ShowDialog()
