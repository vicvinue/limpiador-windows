#requires -Version 5.1
<#
    Limpiador de Windows / Windows Cleaner
    https://github.com/vicvinue/limpiador-windows

    Herramienta gráfica para liberar espacio y optimizar Windows 10/11 sin romper nada.
    Graphical tool to free up space and optimize Windows 10/11 without breaking anything.

      - Archivos basura / Junk files
      - Bloatware
      - Optimizar / Optimize
      - Espacio / Disk space

    Idioma / Language:
      Automático según el idioma de Windows (español si Windows está en español, inglés en otro caso).
      Se puede cambiar desde la ventana o con -Idioma es|en.
      Automatic from the Windows display language (Spanish if Windows is in Spanish, English otherwise).
      Can be changed from the window or with -Idioma es|en (alias -Lang).

    Uso / Usage:
        Limpiador.bat
        powershell -ExecutionPolicy Bypass -File Limpiador.ps1 -Analizar [-Idioma en]

    Licencia MIT / MIT License. Se distribuye "tal cual", sin garantías / Provided "as is", without warranty.
#>
param(
    [switch]$Analizar,
    [Alias('Lang')][string]$Idioma = '',
    # Parámetros internos: el proceso elevado sigue limpiando el perfil del usuario que abrió la app,
    # aunque el administrador sea otra cuenta.
    [string]$TargetSid,
    [string]$TargetProfile,
    [string]$TargetLocal,
    [string]$TargetRoaming,
    [string]$TargetTemp
)

$AppVersion = '1.2.0'

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
$Idioma = "$Idioma".Trim().ToLower()
if ($Idioma -notin '', 'auto', 'es', 'en') { $Idioma = '' }

function Get-LaunchArgs([switch]$NoLang) {
    $q = { param($s) '"' + $s + '"' }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (& $q $PSCommandPath),
        '-TargetSid', $TargetSid,
        '-TargetProfile', (& $q $TargetProfile),
        '-TargetLocal', (& $q $TargetLocal),
        '-TargetRoaming', (& $q $TargetRoaming),
        '-TargetTemp', (& $q $TargetTemp))
    if ($Idioma -and -not $NoLang) { $a += @('-Idioma', $Idioma) }
    return $a
}

if (-not $script:IsAdmin -and -not $Analizar) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop -ArgumentList (Get-LaunchArgs)
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
$script:ConfigFile = Join-Path $script:DataDir 'config.json'

# ------------------------------------------------------------------ Idioma ----
function Get-Config {
    try { return (Get-Content -Raw -LiteralPath $script:ConfigFile -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}
function Save-Config([string]$lang) {
    try { @{ lang = $lang } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8 } catch { }
}

$cfg = Get-Config
$script:LangPref = 'auto'
if ($Idioma) { $script:LangPref = $Idioma }
elseif ($cfg -and $cfg.lang -in 'auto', 'es', 'en') { $script:LangPref = $cfg.lang }
$script:Lang = $script:LangPref
if ($script:Lang -eq 'auto') {
    $script:Lang = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'es') { 'es' } else { 'en' }
}

# Devuelve el texto en el idioma activo / Returns the text in the active language
function L([string]$es, [string]$en) { if ($script:Lang -eq 'es') { return $es } else { return $en } }

$AppName = L 'Limpiador de Windows' 'Windows Cleaner'

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
$script:Machine  = if ($script:IsVM) { L 'Máquina virtual' 'Virtual machine' } elseif ($script:IsLaptop) { L 'Portátil' 'Laptop' } else { L 'Sobremesa' 'Desktop' }

# --------------------------------------------------------------- Utilidades ---
function Pump {
    $script:Tick++
    if ($script:Tick % 150 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
}

function Format-Size([long]$b) {
    if ($b -lt 0)   { return (L 'Desconocido' 'Unknown') }
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

$CG_SYS  = L 'Sistema' 'System'
$CG_BROW = L 'Navegadores (solo caché)' 'Browsers (cache only)'
$CG_APPS = L 'Aplicaciones (solo caché)' 'Apps (cache only)'
$CG_DEV  = L 'Desarrollo (cachés de paquetes)' 'Development (package caches)'

$N_SAFE_BROWSER = L 'Seguro. No borra historial, contraseñas ni sesiones.' 'Safe. Does not delete history, passwords or sessions.'
$N_SAFE         = L 'Seguro.' 'Safe.'
$N_SAFE_PKG     = L 'Seguro. Los paquetes se vuelven a descargar si hacen falta.' 'Safe. Packages are downloaded again when needed.'

$Categories = @(
    # ---------------- Sistema ----------------
    New-Cat -Id tempuser -Group $CG_SYS -Name (L 'Archivos temporales del usuario' 'User temporary files') `
        -Note (L 'Seguro. Se omiten los archivos en uso y los de menos de 24 h.' 'Safe. Files in use and files newer than 24 h are skipped.') `
        -Desc (L 'Carpeta %TEMP%. Los programas dejan aquí archivos de instalación y trabajo que nunca borran.' 'The %TEMP% folder. Programs leave setup and working files here and never delete them.') `
        -Targets { T $TargetTemp -MinAgeDays 1 }

    New-Cat -Id tempwin -Group $CG_SYS -Name (L 'Archivos temporales de Windows' 'Windows temporary files') -Admin `
        -Note (L 'Seguro. Se omiten los archivos en uso y los de menos de 24 h.' 'Safe. Files in use and files newer than 24 h are skipped.') `
        -Desc (L 'Carpeta C:\Windows\Temp, usada por el sistema y los instaladores.' 'The C:\Windows\Temp folder, used by the system and installers.') `
        -Targets { T "$W\Temp" -MinAgeDays 1 }

    New-Cat -Id wupdate -Group $CG_SYS -Name (L 'Descargas de Windows Update' 'Windows Update downloads') -Admin `
        -Note (L 'Seguro. Son instaladores ya aplicados; se detiene el servicio un momento.' 'Safe. Already installed updates; the service is stopped briefly.') `
        -Desc (L 'C:\Windows\SoftwareDistribution\Download. Windows vuelve a descargar lo que necesite.' 'C:\Windows\SoftwareDistribution\Download. Windows downloads again whatever it needs.') `
        -Targets { T "$W\SoftwareDistribution\Download" } `
        -Action {
            param($cat, $res)
            $svcs = @('wuauserv', 'bits') | ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } |
                Where-Object { $_.Status -eq 'Running' }
            foreach ($s in $svcs) { try { Stop-Service -Name $s.Name -Force -ErrorAction Stop } catch { } }
            foreach ($t in (Get-Targets $cat)) { Clear-Target $t $res }
            foreach ($s in $svcs) { try { Start-Service -Name $s.Name -ErrorAction Stop } catch { } }
        }

    New-Cat -Id deliveryopt -Group $CG_SYS -Name (L 'Caché de Optimización de distribución' 'Delivery Optimization cache') -Admin `
        -Note (L 'Seguro. Copias de actualizaciones compartidas con otros PCs.' 'Safe. Copies of updates shared with other PCs.') `
        -Desc (L 'Caché que Windows usa para compartir actualizaciones en la red. Se borra con la herramienta oficial.' 'Cache Windows uses to share updates over the network. Cleared with the official tool.') `
        -Targets { T "$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" } `
        -Action {
            param($cat, $res)
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; return } catch { }
            }
            foreach ($t in (Get-Targets $cat)) { Clear-Target $t $res }
        }

    New-Cat -Id wer -Group $CG_SYS -Name (L 'Informes de errores de Windows' 'Windows Error Reporting files') -Admin `
        -Note (L 'Seguro. Informes de fallos antiguos.' 'Safe. Old crash reports.') `
        -Desc (L 'Informes que Windows genera cuando un programa se cuelga o falla.' 'Reports Windows creates when a program hangs or crashes.') `
        -Targets {
            T "$PD\Microsoft\Windows\WER\ReportArchive"
            T "$PD\Microsoft\Windows\WER\ReportQueue"
            T "$PD\Microsoft\Windows\WER\Temp"
            T "$L\Microsoft\Windows\WER"
        }

    New-Cat -Id dumps -Group $CG_SYS -Name (L 'Volcados de memoria por fallos' 'Crash memory dumps') -Admin `
        -Note (L 'Seguro. Solo sirven para diagnosticar pantallazos azules.' 'Safe. Only useful to diagnose blue screens.') `
        -Desc (L 'Archivos .dmp de pantallazos azules y programas cerrados inesperadamente. Pueden ocupar varios GB.' '.dmp files from blue screens and crashed programs. They can take several GB.') `
        -Targets {
            T "$L\CrashDumps"
            T "$W\Minidump"
            T $W -Filter 'MEMORY.DMP' -NoRecurse
            T "$W\LiveKernelReports" -Filter '*.dmp'
        }

    New-Cat -Id thumbs -Group $CG_SYS -Name (L 'Caché de miniaturas' 'Thumbnail cache') `
        -Note (L 'Seguro. Se regeneran solas; parte puede estar en uso.' 'Safe. Rebuilt automatically; some may be in use.') `
        -Desc (L 'Vistas previas de imágenes y vídeos del Explorador. Se vuelven a crear al abrir las carpetas.' 'Image and video previews in File Explorer. They are recreated when folders are opened.') `
        -Targets { T "$L\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -NoRecurse }

    New-Cat -Id inetcache -Group $CG_SYS -Name (L 'Caché de Internet de Windows' 'Windows Internet cache') `
        -Note $N_SAFE `
        -Desc (L 'Caché web usada por componentes de Windows, Office y aplicaciones antiguas.' 'Web cache used by Windows components, Office and older apps.') `
        -Targets { T "$L\Microsoft\Windows\INetCache" }

    New-Cat -Id logs -Group $CG_SYS -Name (L 'Registros (logs) antiguos de Windows' 'Old Windows log files') -Admin `
        -Note (L 'Seguro. Solo archivos de más de 7 días.' 'Safe. Only files older than 7 days.') `
        -Desc (L 'Archivos de registro de C:\Windows\Logs (instalaciones, CBS, DISM...).' 'Log files in C:\Windows\Logs (setup, CBS, DISM...).') `
        -Targets { T "$W\Logs" -MinAgeDays 7 }

    New-Cat -Id shaders -Group $CG_SYS -Name (L 'Caché de sombreadores (DirectX / GPU)' 'Shader cache (DirectX / GPU)') `
        -Note (L 'Seguro. Los juegos pueden tardar algo más la primera vez.' 'Safe. Games may take a bit longer to load the first time.') `
        -Desc (L 'Cachés de DirectX, NVIDIA, AMD e Intel. Se regeneran automáticamente.' 'DirectX, NVIDIA, AMD and Intel caches. Rebuilt automatically.') `
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

    New-Cat -Id recycle -Group $CG_SYS -Name (L 'Papelera de reciclaje' 'Recycle Bin') -Off `
        -Note (L 'Revisa antes que no haya nada que quieras recuperar.' 'Check first that there is nothing you want to recover.') `
        -Desc (L 'Vacía la papelera de todas las unidades. Lo borrado ya no se podrá recuperar.' 'Empties the Recycle Bin on all drives. Deleted items can no longer be recovered.') `
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

    New-Cat -Id dism -Group $CG_SYS -Name (L 'Limpieza del almacén de componentes (WinSxS)' 'Component store cleanup (WinSxS)') -Admin -Off `
        -Note (L 'Seguro (herramienta oficial DISM). Lento: 5-20 minutos.' 'Safe (official DISM tool). Slow: 5-20 minutes.') `
        -Desc (L 'Ejecuta "DISM /Online /Cleanup-Image /StartComponentCleanup" para quitar versiones antiguas de componentes reemplazados por actualizaciones.' 'Runs "DISM /Online /Cleanup-Image /StartComponentCleanup" to remove old versions of components superseded by updates.') `
        -Size { -1 } `
        -Action {
            param($cat, $res)
            $c = Invoke-Tool 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
            if ($c -ne 0) { Write-Log (L "  DISM terminó con código $c." "  DISM exited with code $c.") }
        }

    New-Cat -Id winold -Group $CG_SYS -Name (L 'Instalación anterior de Windows (Windows.old)' 'Previous Windows installation (Windows.old)') -Admin -Off -Optional `
        -Note (L 'No rompe nada, pero ya no podrás volver a la versión anterior.' 'Breaks nothing, but you will no longer be able to roll back.') `
        -Desc (L 'Restos de una actualización de Windows (Windows.old, $Windows.~BT, $Windows.~WS). Se borra con el Liberador de espacio oficial.' 'Leftovers from a Windows upgrade (Windows.old, $Windows.~BT, $Windows.~WS). Removed with the official Disk Cleanup tool.') `
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
    New-Cat -Id chrome -Group $CG_BROW -Name 'Google Chrome' -Optional -Procs 'chrome' -Note $N_SAFE_BROWSER `
        -Desc (L 'Caché de páginas, código y GPU de todos los perfiles de Chrome. Cierra Chrome para limpiar todo.' 'Page, code and GPU cache of all Chrome profiles. Close Chrome to clean everything.') `
        -Targets { Get-ChromiumTargets "$L\Google\Chrome\User Data" }

    New-Cat -Id edge -Group $CG_BROW -Name 'Microsoft Edge' -Optional -Procs 'msedge' -Note $N_SAFE_BROWSER `
        -Desc (L 'Caché de páginas, código y GPU de todos los perfiles de Edge. Cierra Edge para limpiar todo.' 'Page, code and GPU cache of all Edge profiles. Close Edge to clean everything.') `
        -Targets { Get-ChromiumTargets "$L\Microsoft\Edge\User Data" }

    New-Cat -Id brave -Group $CG_BROW -Name 'Brave' -Optional -Procs 'brave' -Note $N_SAFE_BROWSER `
        -Desc (L 'Caché de todos los perfiles de Brave.' 'Cache of all Brave profiles.') `
        -Targets { Get-ChromiumTargets "$L\BraveSoftware\Brave-Browser\User Data" }

    New-Cat -Id vivaldi -Group $CG_BROW -Name 'Vivaldi' -Optional -Procs 'vivaldi' -Note $N_SAFE_BROWSER `
        -Desc (L 'Caché de todos los perfiles de Vivaldi.' 'Cache of all Vivaldi profiles.') `
        -Targets { Get-ChromiumTargets "$L\Vivaldi\User Data" }

    New-Cat -Id opera -Group $CG_BROW -Name 'Opera' -Optional -Procs 'opera' -Note $N_SAFE_BROWSER `
        -Desc (L 'Caché de Opera y Opera GX.' 'Opera and Opera GX cache.') `
        -Targets {
            T "$L\Opera Software\Opera Stable\Cache"
            T "$L\Opera Software\Opera GX Stable\Cache"
        }

    New-Cat -Id firefox -Group $CG_BROW -Name 'Mozilla Firefox' -Optional -Procs 'firefox' -Note $N_SAFE_BROWSER `
        -Desc (L 'Caché de todos los perfiles de Firefox.' 'Cache of all Firefox profiles.') `
        -Targets {
            Get-ChildItem -LiteralPath "$L\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                T (Join-Path $_.FullName 'cache2')
                T (Join-Path $_.FullName 'startupCache')
            }
        }

    # ---------------- Aplicaciones ----------------
    New-Cat -Id discord -Group $CG_APPS -Name 'Discord' -Optional -Procs 'Discord' `
        -Note (L 'Seguro. No cierra tu sesión.' 'Safe. Does not sign you out.') `
        -Desc (L 'Caché de imágenes y código de Discord.' 'Discord image and code cache.') `
        -Targets { T "$R\discord\Cache"; T "$R\discord\Code Cache"; T "$R\discord\GPUCache" }

    New-Cat -Id teams -Group $CG_APPS -Name (L 'Microsoft Teams (clásico)' 'Microsoft Teams (classic)') -Optional -Procs 'Teams' `
        -Note $N_SAFE -Desc (L 'Caché de Teams clásico.' 'Classic Teams cache.') `
        -Targets {
            foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'tmp') { T "$R\Microsoft\Teams\$c" }
        }

    New-Cat -Id vscode -Group $CG_APPS -Name 'Visual Studio Code' -Optional -Procs 'Code' `
        -Note (L 'Seguro. No toca extensiones ni ajustes.' 'Safe. Does not touch extensions or settings.') `
        -Desc (L 'Cachés y logs de VS Code.' 'VS Code caches and logs.') `
        -Targets {
            foreach ($c in 'Cache', 'CachedData', 'Code Cache', 'GPUCache', 'CachedExtensionVSIXs', 'logs') { T "$R\Code\$c" }
        }

    New-Cat -Id steam -Group $CG_APPS -Name (L 'Steam (navegador interno)' 'Steam (built-in browser)') -Optional -Procs 'steam', 'steamwebhelper' `
        -Note (L 'Seguro. No toca juegos.' 'Safe. Does not touch games.') `
        -Desc (L 'Caché web de la tienda/comunidad de Steam.' 'Web cache of the Steam store/community.') `
        -Targets { T "$L\Steam\htmlcache" }

    # ---------------- Desarrollo ----------------
    New-Cat -Id npm -Group $CG_DEV -Name (L 'Caché de npm' 'npm cache') -Optional -Off -Note $N_SAFE_PKG -Desc '%LOCALAPPDATA%\npm-cache' `
        -Targets { T "$L\npm-cache" }

    New-Cat -Id pip -Group $CG_DEV -Name (L 'Caché de pip (Python)' 'pip cache (Python)') -Optional -Off -Note $N_SAFE_PKG -Desc '%LOCALAPPDATA%\pip\Cache' `
        -Targets { T "$L\pip\Cache" }

    New-Cat -Id nuget -Group $CG_DEV -Name (L 'Caché HTTP de NuGet' 'NuGet HTTP cache') -Optional -Off -Note $N_SAFE -Desc '%LOCALAPPDATA%\NuGet\v3-cache' `
        -Targets { T "$L\NuGet\v3-cache" }

    New-Cat -Id yarn -Group $CG_DEV -Name (L 'Caché de Yarn' 'Yarn cache') -Optional -Off -Note $N_SAFE -Desc '%LOCALAPPDATA%\Yarn\Cache' `
        -Targets { T "$L\Yarn\Cache" }
)

# Ocultar programas que no están instalados
$Categories = @($Categories | Where-Object { -not $_.Optional -or (Test-AnyTarget $_) })

# ============================================================ 2. BLOATWARE ====
# Solo se muestran apps de ESTA lista. Nada que no esté aquí se puede desinstalar
# desde la aplicación (Store, Edge, componentes del sistema, controladores... quedan fuera).
# Todas se pueden reinstalar desde Microsoft Store.
$G1 = L 'Recomendado quitar' 'Recommended to remove'
$G2 = L 'Opcional: quítala solo si no la usas' 'Optional: remove only if you do not use it'
$G3 = L 'Juegos y Xbox' 'Games and Xbox'

# B <grupo> <patrón> <marcada> <nombre ES> <nota ES> <nombre EN> <nota EN>  (nombre EN vacío = igual que ES)
function B($G, $P, $D, $Nes, $NoteEs, $Nen, $NoteEn) {
    if (-not $Nen) { $Nen = $Nes }
    [pscustomobject]@{ G = $G; P = $P; D = [bool]$D; N = (L $Nes $Nen); Note = (L $NoteEs $NoteEn) }
}
$PromoEs = 'Acceso directo promocional.';       $PromoEn = 'Promotional shortcut.'
$GameEs  = 'Juego promocional preinstalado.';  $GameEn  = 'Preinstalled promotional game.'
$IfEs    = 'Quítala solo si no la usas.';       $IfEn    = 'Remove only if you do not use it.'

$BloatCatalog = @(
    B $G1 'Microsoft.BingNews'                  1 'Microsoft Noticias'        'App de noticias con publicidad.'                         'Microsoft News'      'News app with ads.'
    B $G1 'Microsoft.BingSearch'                1 'Microsoft Bing'            'App de búsqueda de Bing. La búsqueda de Windows sigue funcionando.' '' 'Bing search app. Windows search keeps working.'
    B $G1 'Microsoft.News'                      1 'Noticias (antigua)'        'App de noticias.'                                        'News (legacy)'       'News app.'
    B $G1 'Microsoft.GetHelp'                   1 'Obtener ayuda'             'Asistente de soporte online.'                            'Get Help'            'Online support assistant.'
    B $G1 'Microsoft.Getstarted'                1 'Sugerencias'               'Consejos y promociones de Windows.'                      'Tips'                'Windows tips and promotions.'
    B $G1 'Microsoft.MicrosoftOfficeHub'        1 'Microsoft 365 (lanzador)'  'NO desinstala Office: solo la app promocional de Microsoft 365.' 'Microsoft 365 (launcher)' 'Does NOT uninstall Office: only the Microsoft 365 promo app.'
    B $G1 'Microsoft.M365Companions'            1 'Microsoft 365 Companions'  'Mini apps auxiliares de Microsoft 365. No afecta a Office.' '' 'Microsoft 365 helper mini apps. Does not affect Office.'
    B $G1 'Microsoft.People'                    1 'Contactos (People)'        'App de contactos obsoleta.'                              'People'              'Obsolete contacts app.'
    B $G1 'Microsoft.PowerAutomateDesktop'      1 'Power Automate'            'Automatización para empresas; casi nadie la usa en casa.' '' 'Business automation; rarely used at home.'
    B $G1 'Microsoft.WindowsFeedbackHub'        1 'Centro de opiniones'       'Para enviar comentarios a Microsoft.'                    'Feedback Hub'        'Sends feedback to Microsoft.'
    B $G1 'Microsoft.WindowsMaps'               1 'Mapas'                     'App de mapas sin mantenimiento.'                         'Maps'                'Unmaintained maps app.'
    B $G1 'Microsoft.ZuneVideo'                 1 'Películas y TV'            'Tienda de vídeo de Microsoft (abandonada).'              'Movies & TV'         'Discontinued Microsoft video store.'
    B $G1 'Microsoft.549981C3F5F10'             1 'Cortana'                   'Asistente retirado por Microsoft.'                       ''                    'Assistant retired by Microsoft.'
    B $G1 'Microsoft.SkypeApp'                  1 'Skype'                     'Servicio cerrado por Microsoft en 2025.'                 ''                    'Service shut down by Microsoft in 2025.'
    B $G1 'Microsoft.MixedReality.Portal'       1 'Portal de realidad mixta'  'Solo útil con gafas de realidad mixta.'                  'Mixed Reality Portal' 'Only useful with a mixed reality headset.'
    B $G1 'Microsoft.Microsoft3DViewer'         1 'Visor 3D'                  'Visor de modelos 3D.'                                    '3D Viewer'           '3D model viewer.'
    B $G1 'Microsoft.Print3D'                   1 'Print 3D'                  'Impresión 3D.'                                           ''                    '3D printing.'
    B $G1 'Microsoft.Windows.DevHome'           1 'Dev Home'                  'Herramienta para desarrolladores retirada por Microsoft.' '' 'Developer tool retired by Microsoft.'
    B $G1 'Microsoft.Wallet'                    1 'Microsoft Pay'             'Servicio retirado.'                                      ''                    'Retired service.'
    B $G1 'Microsoft.Messaging'                 1 'Mensajes'                  'App obsoleta.'                                           'Messaging'           'Obsolete app.'
    B $G1 'Microsoft.OneConnect'                1 'Planes móviles'            'App de operadoras móviles.'                              'Mobile Plans'        'Mobile carrier app.'
    B $G1 'Microsoft.Office.Sway'               1 'Sway'                      'App de presentaciones web.'                              ''                    'Web presentation app.'
    B $G1 'MicrosoftCorporationII.MicrosoftFamily' 1 'Microsoft Family'       'Control parental online (se gestiona igual desde la web).' '' 'Online parental controls (can be managed from the web).'
    B $G1 'Clipchamp.Clipchamp'                 1 'Clipchamp'                 'Editor de vídeo online preinstalado.'                    ''                    'Preinstalled online video editor.'
    B $G1 '*CandyCrush*'                        1 'Candy Crush'               $GameEs  '' $GameEn
    B $G1 '*BubbleWitch*'                       1 'Bubble Witch'              $GameEs  '' $GameEn
    B $G1 'king.com.*'                          1 'Juegos de King'            $GameEs  'King games' $GameEn
    B $G1 '*MarchofEmpires*'                    1 'March of Empires'          $GameEs  '' $GameEn
    B $G1 '*HiddenCity*'                        1 'Hidden City'               $GameEs  '' $GameEn
    B $G1 '*RoyalRevolt*'                       1 'Royal Revolt'              $GameEs  '' $GameEn
    B $G1 '*FarmVille*'                         1 'FarmVille'                 $GameEs  '' $GameEn
    B $G1 '*Facebook*'                          1 'Facebook'                  $PromoEs '' $PromoEn
    B $G1 '*Instagram*'                         1 'Instagram'                 $PromoEs '' $PromoEn
    B $G1 '*TikTok*'                            1 'TikTok'                    $PromoEs '' $PromoEn
    B $G1 '*Twitter*'                           1 'Twitter / X'               $PromoEs '' $PromoEn
    B $G1 '*LinkedIn*'                          1 'LinkedIn'                  $PromoEs '' $PromoEn
    B $G1 '*McAfee*'                            1 'McAfee (prueba)'           'Antivirus de prueba; Windows ya incluye Microsoft Defender.' 'McAfee (trial)' 'Trial antivirus; Windows already includes Microsoft Defender.'
    B $G1 '*Duolingo*'                          1 'Duolingo'                  $PromoEs '' $PromoEn
    B $G1 '*PicsArt*'                           1 'PicsArt'                   $PromoEs '' $PromoEn

    B $G2 'Microsoft.BingWeather'               0 'El Tiempo'                 'App del tiempo.'                                         'Weather'             'Weather app.'
    B $G2 'Microsoft.MicrosoftSolitaireCollection' 0 'Microsoft Solitaire'    'Solitario con anuncios.'                                 ''                    'Solitaire with ads.'
    B $G2 'Microsoft.Todos'                     0 'Microsoft To Do'           'Lista de tareas.'                                        ''                    'To-do list.'
    B $G2 'MicrosoftTeams'                      0 'Microsoft Teams (personal)' 'Versión gratuita/personal. No es el Teams del trabajo (MSTeams), que no se toca.' '' 'Free/personal version. Not Teams for work (MSTeams), which is never touched.'
    B $G2 'MicrosoftWindows.Client.WebExperience' 0 'Widgets'                 'Panel de widgets (tiempo, noticias) de la barra de tareas.' '' 'Taskbar widgets panel (weather, news).'
    B $G2 'Microsoft.Copilot'                   0 'Copilot'                   'Asistente de IA de Microsoft.'                           ''                    'Microsoft AI assistant.'
    B $G2 'Microsoft.MicrosoftPCManager'        0 'Microsoft PC Manager'      'Optimizador de Microsoft (esta app ya hace lo mismo).'   ''                    'Microsoft optimizer (this app does the same).'
    B $G2 'Microsoft.OutlookForWindows'         0 'Outlook (nuevo)'           'Cliente de correo. No afecta a Outlook de Office.'       'Outlook (new)'       'Mail client. Does not affect Office Outlook.'
    B $G2 'microsoft.windowscommunicationsapps' 0 'Correo y Calendario'       'Apps antiguas de correo.'                                'Mail and Calendar'   'Legacy mail apps.'
    B $G2 'Microsoft.YourPhone'                 0 'Enlace móvil'              'Conecta tu móvil con el PC.'                             'Phone Link'          'Connects your phone to your PC.'
    B $G2 'Microsoft.ZuneMusic'                 0 'Reproductor multimedia'    'Reproductor de música y vídeo de Windows.'               'Media Player'        'Windows music and video player.'
    B $G2 'Microsoft.WindowsSoundRecorder'      0 'Grabadora de sonido'       'Grabadora de audio.'                                     'Sound Recorder'      'Audio recorder.'
    B $G2 'Microsoft.WindowsAlarms'             0 'Reloj / Alarmas'           'Alarmas, temporizador y sesiones de concentración.'      'Clock / Alarms'      'Alarms, timer and focus sessions.'
    B $G2 'Microsoft.WindowsCamera'             0 'Cámara'                    'App de cámara.'                                          'Camera'              'Camera app.'
    B $G2 'Microsoft.MicrosoftStickyNotes'      0 'Notas rápidas'             'Notas adhesivas.'                                        'Sticky Notes'        'Sticky notes.'
    B $G2 'Microsoft.Office.OneNote'            0 'OneNote para Windows 10'   'Versión antigua de OneNote.'                             'OneNote for Windows 10' 'Legacy version of OneNote.'
    B $G2 'Microsoft.MicrosoftJournal'          0 'Microsoft Journal'         'Notas a mano alzada.'                                    ''                    'Handwritten notes.'
    B $G2 'MicrosoftCorporationII.QuickAssist'  0 'Asistencia rápida'         'Soporte remoto entre PCs.'                               'Quick Assist'        'Remote support between PCs.'
    B $G2 'SpotifyAB.SpotifyMusic'              0 'Spotify'                   $IfEs '' $IfEn
    B $G2 '*Netflix*'                           0 'Netflix'                   $IfEs '' $IfEn
    B $G2 'Disney.*'                            0 'Disney+'                   $IfEs '' $IfEn
    B $G2 'AmazonVideo.PrimeVideo'              0 'Prime Video'               $IfEs '' $IfEn
    B $G2 '5319275A.WhatsAppDesktop'            0 'WhatsApp'                  $IfEs '' $IfEn

    B $G3 'Microsoft.GamingApp'                 0 'Xbox'                      'App de Xbox / Game Pass. Déjala si juegas en PC.'        ''                    'Xbox / Game Pass app. Keep it if you play on PC.'
    B $G3 'Microsoft.XboxApp'                   0 'Xbox (antigua)'            'Versión antigua de la app de Xbox.'                      'Xbox (legacy)'       'Legacy version of the Xbox app.'
    B $G3 'Microsoft.XboxGamingOverlay'         0 'Xbox Game Bar'             'Barra Win+G (también graba la pantalla). Déjala si juegas.' '' 'Win+G bar (also records the screen). Keep it if you play.'
    B $G3 'Microsoft.XboxGameOverlay'           0 'Xbox Game Overlay'         'Superposición de juegos.'                                ''                    'Game overlay.'
    B $G3 'Microsoft.XboxSpeechToTextOverlay'   0 'Xbox voz a texto'          'Chat de voz en juegos.'                                  'Xbox Speech to Text' 'In-game voice chat.'
    B $G3 'Microsoft.Edge.GameAssist'           1 'Edge Game Assist'          'Navegador superpuesto para juegos.'                      ''                    'In-game browser overlay.'
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
                    Note = (L 'Deja de sincronizar. Tus archivos siguen en la nube y los ya descargados se quedan en el PC.' 'Stops syncing. Your files stay in the cloud and downloaded ones stay on the PC.')
                    Uninstall = $od.UninstallString }
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
        if ($p.ExitCode -ne 0) { throw (L "El desinstalador devolvió el código $($p.ExitCode)." "The uninstaller returned code $($p.ExitCode).") }
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
    try { $h | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8 }
    catch { Write-Log (L "  Aviso: no se pudo guardar la copia de seguridad: $($_.Exception.Message)" "  Warning: could not save the backup: $($_.Exception.Message)") }
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
    Write-Log (L '  Aplicado. Valores originales guardados para poder deshacerlo.' '  Applied. Original values saved so it can be undone.')
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
            switch ("$($_.MediaType)") { 'SSD' { 'SSD' } 'HDD' { 'HDD' } default { L 'virtual/otro' 'virtual/other' } }
        } | Select-Object -Unique)
        return ($t -join ', ')
    } catch { return (L 'desconocido' 'unknown') }
}

function Get-HiberFile { $f = New-Object System.IO.FileInfo "$SD\hiberfil.sys"; try { if ($f.Exists) { return $f } } catch { }; return $null }

function New-Opt {
    param([string]$Id, [string]$Group, [string]$Name, [string]$Note, [string]$Desc, [switch]$Admin, [bool]$Default = $false,
          [scriptblock]$Status, [scriptblock]$Run, [object[]]$Values, [scriptblock]$Apply, [scriptblock]$Undo)
    [pscustomobject]@{ Id = $Id; Group = $Group; Name = $Name; Note = $Note; Desc = $Desc; Admin = [bool]$Admin; Default = $Default
                       Status = $Status; Run = $Run; Values = $Values; Apply = $Apply; Undo = $Undo }
}

$OG1 = L 'Mantenimiento (herramientas oficiales de Windows)' 'Maintenance (official Windows tools)'
$OG2 = L 'Ajustes reversibles' 'Reversible tweaks'

$vmHint = ''
if ($script:IsVM) { $vmHint = L ' En una máquina virtual, después usa la opción de compactar / liberar espacio de tu software (Parallels, VMware, Hyper-V, VirtualBox) para que el anfitrión recupere el espacio.' ' In a virtual machine, then use the compact / reclaim disk space option of your software (Parallels, VMware, Hyper-V, VirtualBox) so the host gets the space back.' }

$hiberNote = if ($script:IsLaptop) { L 'En portátiles protege tu trabajo si se agota la batería: desactívala solo si no la usas.' 'On laptops it protects your work if the battery runs out: disable it only if you do not use it.' }
             else { L 'Libera tanto espacio como indica el estado. También desactiva el Inicio rápido.' 'Frees as much space as the status shows. Also disables Fast Startup.' }

$Optimizations = @(
    New-Opt -Id defrag -Group $OG1 -Name (L 'Optimizar unidades (TRIM / desfragmentar)' 'Optimize drives (TRIM / defragment)') -Admin -Default $true `
        -Note $(if ($script:IsVM) { L 'Seguro. En máquinas virtuales ayuda a devolver espacio al anfitrión.' 'Safe. In virtual machines it helps give space back to the host.' } else { L 'Seguro. Windows elige TRIM (SSD) o desfragmentación (HDD).' 'Safe. Windows picks TRIM (SSD) or defragmentation (HDD).' }) `
        -Desc ((L 'Ejecuta la optimización oficial de Windows (defrag /C /O) en todas las unidades: TRIM en SSD y desfragmentación en discos mecánicos. No toca tus datos.' 'Runs the official Windows optimization (defrag /C /O) on all drives: TRIM on SSDs and defragmentation on hard disks. Does not touch your data.') + $vmHint) `
        -Status { (L 'Discos: ' 'Disks: ') + (Get-DiskSummary) } `
        -Run {
            $c = Invoke-Tool 'defrag.exe' @('/C', '/O', '/H')
            if ($c -eq 0) { Write-Log (L '  Unidades optimizadas.' '  Drives optimized.') } else { Write-Log (L "  defrag terminó con código $c." "  defrag exited with code $c.") }
            if ($script:IsVM) { Write-Log (L '  Consejo: ahora compacta el disco virtual desde tu software de virtualización.' '  Tip: now compact the virtual disk from your virtualization software.') }
        }

    New-Opt -Id dismrestore -Group $OG1 -Name (L 'Reparar imagen de Windows (DISM)' 'Repair Windows image (DISM)') -Admin `
        -Note (L 'Seguro. Requiere Internet. 10-30 minutos.' 'Safe. Requires Internet. 10-30 minutes.') `
        -Desc (L 'Ejecuta "DISM /Online /Cleanup-Image /RestoreHealth": comprueba y repara el almacén de componentes de Windows usando Windows Update. Conviene ejecutarlo antes de SFC.' 'Runs "DISM /Online /Cleanup-Image /RestoreHealth": checks and repairs the Windows component store using Windows Update. Best run before SFC.') `
        -Run {
            $c = Invoke-Tool 'dism.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth')
            if ($c -eq 0) { Write-Log (L '  Imagen de Windows correcta o reparada.' '  Windows image is healthy or was repaired.') }
            else { Write-Log (L "  DISM terminó con código $c (detalles en $W\Logs\DISM\dism.log)." "  DISM exited with code $c (details in $W\Logs\DISM\dism.log).") }
        }

    New-Opt -Id sfc -Group $OG1 -Name (L 'Comprobar archivos del sistema (SFC)' 'Check system files (SFC)') -Admin `
        -Note (L 'Seguro. Repara archivos de Windows dañados. 10-20 minutos.' 'Safe. Repairs damaged Windows files. 10-20 minutes.') `
        -Desc (L 'Ejecuta "sfc /scannow": verifica todos los archivos protegidos de Windows y repara los que estén dañados.' 'Runs "sfc /scannow": verifies all protected Windows files and repairs damaged ones.') `
        -Run {
            $c = Invoke-Tool 'sfc.exe' @('/scannow')
            Write-Log (L "  SFC terminado (código $c). Detalles en $W\Logs\CBS\CBS.log" "  SFC finished (code $c). Details in $W\Logs\CBS\CBS.log")
        }

    New-Opt -Id chkdsk -Group $OG1 -Name (L 'Comprobar el disco del sistema (CHKDSK)' 'Check the system disk (CHKDSK)') -Admin `
        -Note (L 'Seguro. Análisis en línea, no reinicia el equipo.' 'Safe. Online scan, no restart needed.') `
        -Desc (L "Ejecuta `"chkdsk $SD /scan`": busca errores en el sistema de archivos sin desmontar la unidad." "Runs `"chkdsk $SD /scan`": looks for file system errors without unmounting the drive.") `
        -Run {
            $c = Invoke-Tool 'chkdsk.exe' @($SD, '/scan')
            switch ($c) {
                0       { Write-Log (L '  No se encontraron errores.' '  No errors found.') }
                1       { Write-Log (L '  Se encontraron y corrigieron errores.' '  Errors were found and fixed.') }
                2       { Write-Log (L '  Sin errores; se hizo limpieza de mantenimiento.' '  No errors; maintenance cleanup was performed.') }
                default { Write-Log (L "  Hay errores que no se pudieron corregir en línea (código $c). Reinicia y ejecuta 'chkdsk $SD /f' desde una consola de administrador." "  There are errors that could not be fixed online (code $c). Restart and run 'chkdsk $SD /f' from an administrator console.") }
            }
        }

    New-Opt -Id visual -Group $OG2 -Name (L 'Efectos visuales en modo rendimiento' 'Visual effects for best performance') `
        -Default ($script:IsVM -or ($script:RamGB -gt 0 -and $script:RamGB -lt 8)) `
        -Note (L 'Reversible. Quita animaciones, sombras y transparencias. Se aplica del todo al cerrar sesión.' 'Reversible. Removes animations, shadows and transparency. Fully applied after signing out.') `
        -Desc (L 'Desactiva animaciones de ventanas y barra de tareas, sombras, transparencias y Aero Peek. Mantiene el suavizado de fuentes. Útil en equipos modestos y máquinas virtuales.' 'Disables window and taskbar animations, shadows, transparency and Aero Peek. Keeps font smoothing. Useful on modest PCs and virtual machines.') `
        -Values @(
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3 'DWord'
            RegVal 'HKCU' 'Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
            RegVal 'HKCU' 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 'DWord'
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0 'DWord'
            RegVal 'HKCU' 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 'DWord'
            RegVal 'HKCU' 'Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 'DWord'
        )

    New-Opt -Id hibernate -Group $OG2 -Name (L 'Desactivar la hibernación' 'Disable hibernation') -Admin `
        -Default ([bool](Get-HiberFile) -and -not $script:IsLaptop) `
        -Note ((L 'Reversible. ' 'Reversible. ') + $hiberNote) `
        -Desc (L 'Ejecuta "powercfg /hibernate off" y elimina hiberfil.sys, que suele ocupar el 40 % de la RAM. Se puede volver a activar con "Deshacer ajustes".' 'Runs "powercfg /hibernate off" and removes hiberfil.sys, which is usually 40% of your RAM. Can be re-enabled with "Undo tweaks".') `
        -Status { $f = Get-HiberFile; if ($f) { (L 'Activa · ' 'On · ') + (Format-Size $f.Length) } else { L 'Desactivada' 'Off' } } `
        -Apply {
            if (-not (Get-HiberFile)) { Write-Log (L '  La hibernación ya estaba desactivada.' '  Hibernation was already disabled.'); return }
            $bk = Get-Backup; $bk['powercfg:hibernate'] = 'on'; Save-Backup $bk
            $c = Invoke-Tool 'powercfg.exe' @('/hibernate', 'off')
            if ($c -eq 0) { Write-Log (L '  Hibernación desactivada.' '  Hibernation disabled.') } else { Write-Log (L "  powercfg terminó con código $c." "  powercfg exited with code $c.") }
        } `
        -Undo {
            Invoke-Tool 'powercfg.exe' @('/hibernate', 'on') | Out-Null
            $bk = Get-Backup; $bk.Remove('powercfg:hibernate'); Save-Backup $bk
            Write-Log (L '  Hibernación reactivada.' '  Hibernation re-enabled.')
        }
)

function Get-OptStatus($o) {
    if ($o.Status) { return [string](& $o.Status) }
    if ($o.Values) { if (Test-RegToggle $o) { return (L 'Aplicado' 'Applied') } else { return (L 'No aplicado' 'Not applied') } }
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
    Write-Host ("$AppName $AppVersion - " + (L 'análisis (no se borra nada)' 'analysis (nothing is deleted)'))
    Write-Host ((L 'Equipo' 'Machine') + ": $script:Machine · RAM: $script:RamGB GB · " + (L 'Discos' 'Disks') + ": $(Get-DiskSummary) · " + (L 'Administrador' 'Administrator') + ': ' + $(if ($script:IsAdmin) { L 'Sí' 'Yes' } else { 'No' }) + "`n")
    $total = [long]0
    foreach ($c in $Categories) {
        $b = Measure-Cat $c
        if ($b -gt 0) { $total += $b }
        '{0,-50} {1,12}' -f $c.Name, (Format-Size $b) | Write-Host
    }
    Write-Host ("`n{0,-50} {1,12}" -f 'TOTAL', (Format-Size $total))
    Write-Host ("`n" + (L 'Bloatware detectado:' 'Bloatware found:'))
    foreach ($b in (Get-BloatItems)) {
        $mark = if ($b.Default) { '[x]' } else { '[ ]' }
        '  {0} {1,-32} {2}' -f $mark, $b.Name, $b.Id | Write-Host
    }
    Write-Host ("`n" + (L 'Optimizaciones:' 'Optimizations:'))
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

# Textos reutilizados
$TXT_ADMIN = L '[Requiere administrador] ' '[Requires administrator] '

# ---------- Ventana
$form = New-Object System.Windows.Forms.Form
$form.Text = "$AppName $AppVersion"
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new((S 1100), (S 800))
$form.MinimumSize = [System.Drawing.Size]::new((S 860), (S 580))
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.BackColor = $BgColor

# ---------- Pestaña 1: Archivos basura
$list = New-LV @(@((L 'Elemento' 'Item'), 380), @((L 'Tamaño' 'Size'), 110, 'Right'), @((L 'Nota' 'Note'), 500)) $true
$cg = @{}
foreach ($c in $Categories) {
    $allowed = (-not $c.Admin) -or $script:IsAdmin
    $note = if ($allowed) { $c.Note } else { $TXT_ADMIN + $c.Note }
    Add-LVItem $list $cg $c.Group $c.Name @('...', $note) $c $c.Default $allowed
}
$tabClean = New-Tab 'clean' (L 'Archivos basura' 'Junk files')
$tabClean.Controls.Add($list)

# ---------- Pestaña 2: Bloatware
$bloatList = New-LV @(@((L 'Aplicación' 'App'), 260), @((L 'Paquete' 'Package'), 300), @((L 'Nota' 'Note'), 450)) $true
$bloatOpts = New-OptionsBar
$chkRestore = New-Object System.Windows.Forms.CheckBox
$chkRestore.Text = L 'Crear punto de restauración antes' 'Create a restore point first'
$chkRestore.AutoSize = $true
$chkRestore.Checked = $script:IsAdmin
$chkRestore.Enabled = $script:IsAdmin
$chkProv = New-Object System.Windows.Forms.CheckBox
$chkProv.Text = L 'Evitar que Windows las reinstale' 'Prevent Windows from reinstalling them'
$chkProv.AutoSize = $true
$chkProv.Checked = $script:IsAdmin
$chkProv.Enabled = $script:IsAdmin
$chkProv.Margin = New-Object System.Windows.Forms.Padding((S 20), 0, 0, 0)
$bloatOpts.Controls.AddRange(@($chkRestore, $chkProv, (New-Hint (L 'Todas se pueden volver a instalar desde Microsoft Store.' 'All of them can be reinstalled from the Microsoft Store.'))))
$tabBloat = New-Tab 'bloat' 'Bloatware'
$tabBloat.Controls.Add($bloatList)
$tabBloat.Controls.Add($bloatOpts)

# ---------- Pestaña 3: Optimizar
$optList = New-LV @(@((L 'Acción / ajuste' 'Action / tweak'), 360), @((L 'Estado' 'Status'), 170), @((L 'Nota' 'Note'), 480)) $true
$og = @{}
foreach ($o in $Optimizations) {
    $allowed = (-not $o.Admin) -or $script:IsAdmin
    $note = if ($allowed) { $o.Note } else { $TXT_ADMIN + $o.Note }
    Add-LVItem $optList $og $o.Group $o.Name @('...', $note) $o $o.Default $allowed
}
$optBar = New-OptionsBar
$optBar.Controls.Add((New-Hint ((L 'Equipo detectado' 'Detected machine') + ": $script:Machine · RAM $script:RamGB GB · " + (L 'Discos' 'Disks') + ": $(Get-DiskSummary). " + (L 'Las recomendaciones se adaptan a tu equipo.' 'Recommendations adapt to your machine.'))))
$tabOpt = New-Tab 'opt' (L 'Optimizar' 'Optimize')
$tabOpt.Controls.Add($optList)
$tabOpt.Controls.Add($optBar)

# ---------- Pestaña 4: Espacio
$lvFolders = New-LV @(@((L 'Tamaño' 'Size'), 95, 'Right'), @('%', 60, 'Right'), @((L 'Carpeta' 'Folder'), 260)) $false
$lvFolders.ShowGroups = $false
$lvFolders.MultiSelect = $false
$lvFiles = New-LV @(@((L 'Archivo' 'File'), 260), @((L 'Tamaño' 'Size'), 100, 'Right'), @((L 'Modificado' 'Modified'), 100), @((L 'Ubicación' 'Location'), 300)) $false
$lvFiles.ShowGroups = $false
$lvFiles.MultiSelect = $true

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Vertical'
$split.Panel1.Controls.Add($lvFolders)
$split.Panel2.Controls.Add($lvFiles)

$lblFoldersTitle = New-Object System.Windows.Forms.Label
$lblFoldersTitle.Text = '  ' + (L 'Carpetas (doble clic para entrar)' 'Folders (double-click to open)')
$lblFoldersTitle.Dock = 'Top'; $lblFoldersTitle.Height = S 24; $lblFoldersTitle.TextAlign = 'MiddleLeft'
$lblFoldersTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$split.Panel1.Controls.Add($lblFoldersTitle)
$lblFilesTitle = New-Object System.Windows.Forms.Label
$lblFilesTitle.Text = '  ' + (L "Archivos más grandes (más de $(Format-Size $script:BigMin))" "Largest files (over $(Format-Size $script:BigMin))")
$lblFilesTitle.Dock = 'Top'; $lblFilesTitle.Height = S 24; $lblFilesTitle.TextAlign = 'MiddleLeft'
$lblFilesTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$split.Panel2.Controls.Add($lblFilesTitle)

$spaceBar = New-OptionsBar
$spaceBar.Height = S 52
$btnSpProfile   = New-Btn (L 'Mi perfil' 'My profile') $false
$btnSpDownloads = New-Btn (L 'Descargas' 'Downloads') $false
$btnSpDrive     = New-Btn ((L 'Unidad ' 'Drive ') + "$SD\") $false
$btnSpPick      = New-Btn (L 'Otra carpeta...' 'Other folder...') $false
$btnSpUp        = New-Btn (L 'Subir un nivel' 'Up one level') $false
$spaceBar.Controls.AddRange(@($btnSpProfile, $btnSpDownloads, $btnSpDrive, $btnSpPick, $btnSpUp))
$lblSpPath = New-Object System.Windows.Forms.Label
$lblSpPath.Dock = 'Top'
$lblSpPath.Height = S 26
$lblSpPath.Padding = New-Object System.Windows.Forms.Padding((S 10), 0, 0, 0)
$lblSpPath.TextAlign = 'MiddleLeft'
$lblSpPath.BackColor = $White
$lblSpPath.Text = L 'Elige una carpeta para analizar.' 'Choose a folder to scan.'

$tabSpace = New-Tab 'space' (L 'Espacio' 'Disk space')
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
$lblDesc.Height = S 68
$lblDesc.Padding = New-Object System.Windows.Forms.Padding((S 14), (S 6), (S 14), (S 6))
$lblDesc.BackColor = $White
$lblDesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

$DescDefault = @{
    clean = L 'Selecciona un elemento para ver qué se borra exactamente.' 'Select an item to see exactly what gets deleted.'
    bloat = L 'Selecciona una app para ver qué es. Solo se muestran apps de una lista segura: nunca componentes del sistema.' 'Select an app to see what it is. Only apps from a safe list are shown: never system components.'
    opt   = L 'Selecciona una acción para ver qué hace. Los ajustes guardan su valor original y se pueden deshacer.' 'Select an action to see what it does. Tweaks save their original value and can be undone.'
    space = L 'Solo muestra información. Si envías algo a la papelera, puedes recuperarlo desde ella. Las carpetas de Windows y de programas están protegidas.' 'Information only. Anything you send to the Recycle Bin can be restored from it. Windows and program folders are protected.'
}
$lblDesc.Text = $DescDefault.clean

# ---------- Registro
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = 'Bottom'
$logBox.Height = S 124
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
$lblStatus.Text = L 'Listo.' 'Ready.'
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

$TXT_RECOM = L 'Recomendados' 'Recommended'
$TXT_NONE  = L 'Ninguno' 'None'
$TabButtons = [ordered]@{
    clean = @((New-Btn (L 'Volver a analizar' 'Scan again') $false), (New-Btn $TXT_RECOM $false), (New-Btn $TXT_NONE $false), (New-Btn (L 'Limpiar seleccionados' 'Clean selected') $true))
    bloat = @((New-Btn (L 'Volver a buscar' 'Search again') $false), (New-Btn $TXT_RECOM $false), (New-Btn $TXT_NONE $false), (New-Btn (L 'Desinstalar seleccionadas' 'Uninstall selected') $true $Danger))
    opt   = @((New-Btn (L 'Deshacer ajustes' 'Undo tweaks') $false), (New-Btn $TXT_RECOM $false), (New-Btn $TXT_NONE $false), (New-Btn (L 'Aplicar seleccionadas' 'Apply selected') $true))
    space = @((New-Btn (L 'Volver a analizar' 'Scan again') $false), (New-Btn (L 'Abrir ubicación' 'Open location') $false), (New-Btn (L 'Enviar a la papelera' 'Send to Recycle Bin') $true $Danger))
}
$btnAnalyze, $btnRecom, $btnNone, $btnClean                       = $TabButtons.clean
$btnBloatReload, $btnBloatRecom, $btnBloatNone, $btnBloatRemove   = $TabButtons.bloat
$btnOptUndo, $btnOptRecom, $btnOptNone, $btnOptRun                = $TabButtons.opt
$btnSpRescan, $btnSpOpen, $btnSpTrash                             = $TabButtons.space
$btnCancel = New-Btn (L 'Cancelar' 'Cancel') $false
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

# Selector de idioma / Language selector
$langPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$langPanel.Dock = 'Right'
$langPanel.AutoSize = $true
$langPanel.AutoSizeMode = 'GrowAndShrink'
$langPanel.WrapContents = $false
$langPanel.Padding = New-Object System.Windows.Forms.Padding(0, (S 6), 0, 0)
$lblLang = New-Object System.Windows.Forms.Label
$lblLang.Text = L 'Idioma:' 'Language:'
$lblLang.ForeColor = $White
$lblLang.AutoSize = $true
$lblLang.Margin = New-Object System.Windows.Forms.Padding(0, (S 4), (S 6), 0)
$cmbLang = New-Object System.Windows.Forms.ComboBox
$cmbLang.DropDownStyle = 'DropDownList'
$cmbLang.Width = S 170
[void]$cmbLang.Items.AddRange(@((L 'Automático (Windows)' 'Automatic (Windows)'), 'Español', 'English'))
$cmbLang.SelectedIndex = switch ($script:LangPref) { 'es' { 1 } 'en' { 2 } default { 0 } }
$langPanel.Controls.AddRange(@($lblLang, $cmbLang))

$header.Controls.Add($lblInfo)
$header.Controls.Add($lblTitle)
$header.Controls.Add($langPanel)

# Orden de acoplamiento: el control "Fill" se añade primero
$form.Controls.Add($tabs)
$form.Controls.Add($lblDesc)
$form.Controls.Add($logBox)
$form.Controls.Add($bottom)
$form.Controls.Add($header)

# ================================================================ Lógica =====
function Update-Info {
    $d = New-Object System.IO.DriveInfo $env:SystemDrive
    $adm = if ($script:IsAdmin) { L 'Sí' 'Yes' } else { L 'No (algunas opciones desactivadas)' 'No (some options disabled)' }
    $txt = (L 'Espacio libre en ' 'Free space on ') + "${env:SystemDrive} $(Format-Size $d.AvailableFreeSpace) " + (L 'de' 'of') + " $(Format-Size $d.TotalSize)    ·    $script:Machine, $script:RamGB GB RAM    ·    " + (L 'Administrador' 'Administrator') + ": $adm"
    if ($script:OtherUser) { $txt += "    ·    " + (L 'Perfil' 'Profile') + ": $script:TargetName" }
    $lblInfo.Text = $txt
}

function Get-CurrentTab { $tabs.SelectedTab.Name }

function Update-Selection {
    if ($script:Busy) { return }
    switch (Get-CurrentTab) {
        'clean' {
            $sum = [long]0; $n = 0
            foreach ($it in @($list.Items | Where-Object { $_.Checked })) { $n++; if ($it.Tag.Bytes -gt 0) { $sum += $it.Tag.Bytes } }
            $lblStatus.Text = L "Seleccionado: $n elementos · aprox. $(Format-Size $sum) a liberar" "Selected: $n items · approx. $(Format-Size $sum) to free"
        }
        'bloat' {
            $n = @($bloatList.Items | Where-Object { $_.Checked }).Count
            $lblStatus.Text = L "Seleccionadas: $n de $($bloatList.Items.Count) apps" "Selected: $n of $($bloatList.Items.Count) apps"
        }
        'opt' {
            $n = @($optList.Items | Where-Object { $_.Checked }).Count
            $lblStatus.Text = L "Seleccionadas: $n acciones" "Selected: $n actions"
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
    $cmbLang.Enabled = -not $on
    $form.Cursor = if ($on) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    if (-not $on) { $progress.Value = 0 }
}

function Confirm-Action([string]$msg, [string]$title, [string]$icon = 'Question') {
    return ([System.Windows.Forms.MessageBox]::Show($msg, $title, 'YesNo', $icon) -eq 'Yes')
}
function Show-Info([string]$msg) { [void][System.Windows.Forms.MessageBox]::Show($msg, $AppName, 'OK', 'Information') }

# ---------- Idioma
function Set-Language {
    $new = switch ($cmbLang.SelectedIndex) { 1 { 'es' } 2 { 'en' } default { 'auto' } }
    if ($new -eq $script:LangPref) { return }
    Save-Config $new
    $script:LangPref = $new
    $q = L "Se ha guardado el idioma. ¿Reiniciar la aplicación ahora para aplicarlo?`n`nThe language has been saved. Restart the app now to apply it?" "The language has been saved. Restart the app now to apply it?`n`nSe ha guardado el idioma. ¿Reiniciar la aplicación ahora para aplicarlo?"
    if (Confirm-Action $q $AppName) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-LaunchArgs -NoLang)
        $form.Close()
    }
}

# ---------- 1. Archivos basura
function Set-ItemSize($it) {
    $b = $it.Tag.Bytes
    $it.SubItems[1].Text = if ($b -eq 0) { L 'Vacío' 'Empty' } else { Format-Size $b }
}

function Invoke-Analyze {
    Set-Busy $true
    Write-Log (L 'Analizando archivos basura...' 'Scanning junk files...')
    $n = $list.Items.Count; $i = 0
    foreach ($it in $list.Items) {
        $i++
        $lblStatus.Text = (L 'Analizando: ' 'Scanning: ') + "$($it.Tag.Name)..."
        $progress.Value = [int](100 * ($i - 1) / $n)
        $it.SubItems[1].Text = L 'Analizando...' 'Scanning...'
        [System.Windows.Forms.Application]::DoEvents()
        try { $it.Tag.Bytes = Measure-Cat $it.Tag } catch { $it.Tag.Bytes = -1 }
        Set-ItemSize $it
    }
    $total = [long]0
    foreach ($it in $list.Items) { if ($it.Tag.Bytes -gt 0) { $total += $it.Tag.Bytes } }
    Write-Log (L "Análisis terminado. Total recuperable estimado: $(Format-Size $total)" "Scan finished. Estimated recoverable total: $(Format-Size $total)")
    Set-Busy $false
    Update-Info
    Update-Selection
}

function Invoke-Clean {
    $sel = @($list.Items | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { Show-Info (L 'No hay nada seleccionado.' 'Nothing is selected.'); return }
    $est = [long]0
    foreach ($it in $sel) { if ($it.Tag.Bytes -gt 0) { $est += $it.Tag.Bytes } }
    $names = ($sel | ForEach-Object { '  • ' + $_.Tag.Name }) -join "`n"
    $msg = L "Se van a limpiar $($sel.Count) elementos (aprox. $(Format-Size $est)):`n`n$names`n`nLos archivos en uso se omitirán. ¿Continuar?" "$($sel.Count) items will be cleaned (approx. $(Format-Size $est)):`n`n$names`n`nFiles in use will be skipped. Continue?"
    if (-not (Confirm-Action $msg (L 'Confirmar limpieza' 'Confirm cleanup'))) { return }

    Set-Busy $true
    $freeBefore = Get-FreeSpace
    $grand = [long]0
    $i = 0
    Write-Log (L '===== Inicio de la limpieza =====' '===== Cleanup started =====')
    foreach ($it in $sel) {
        $i++
        $cat = $it.Tag
        $progress.Value = [int](100 * ($i - 1) / $sel.Count)
        $lblStatus.Text = (L 'Limpiando: ' 'Cleaning: ') + "$($cat.Name)..."
        $it.SubItems[1].Text = L 'Limpiando...' 'Cleaning...'
        [System.Windows.Forms.Application]::DoEvents()
        Write-Log ((L 'Limpiando: ' 'Cleaning: ') + $cat.Name)

        if ($cat.Bytes -eq 0) { Write-Log (L '  Nada que limpiar.' '  Nothing to clean.'); Set-ItemSize $it; continue }

        if ($cat.Procs.Count -gt 0) {
            $running = @(Get-Process -Name $cat.Procs -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) { Write-Log (L "  Aviso: $($cat.Name) está abierto; ciérralo para limpiar por completo." "  Warning: $($cat.Name) is open; close it to clean everything.") }
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
            Write-Log ("  Error: " + $_.Exception.Message)
        }
        $grand += $res.Freed
        $extra = if ($res.Failed -gt 0) { L " ($($res.Failed) archivos en uso omitidos)" " ($($res.Failed) files in use skipped)" } else { '' }
        Write-Log ((L '  Liberado: ' '  Freed: ') + (Format-Size $res.Freed) + $extra)

        try { $cat.Bytes = Measure-Cat $cat } catch { }
        Set-ItemSize $it
        $script:Internal = $true; $it.Checked = $false; $script:Internal = $false
    }
    $freeAfter = Get-FreeSpace
    Write-Log (L "===== Fin. Total liberado: $(Format-Size $grand) =====" "===== Done. Total freed: $(Format-Size $grand) =====")
    Set-Busy $false
    Update-Info
    Update-Selection
    $msg = L "Limpieza completada.`n`nEspacio liberado: $(Format-Size $grand)`nEspacio libre en ${env:SystemDrive} $(Format-Size $freeBefore)  →  $(Format-Size $freeAfter)" "Cleanup completed.`n`nSpace freed: $(Format-Size $grand)`nFree space on ${env:SystemDrive} $(Format-Size $freeBefore)  →  $(Format-Size $freeAfter)"
    if ($script:IsVM) { $msg += L "`n`nEs una máquina virtual: ejecuta 'Optimizar unidades' en la pestaña Optimizar y compacta el disco virtual para que el anfitrión recupere el espacio." "`n`nThis is a virtual machine: run 'Optimize drives' in the Optimize tab and compact the virtual disk so the host gets the space back." }
    Show-Info $msg
}

# ---------- 2. Bloatware
function Update-BloatList {
    Set-Busy $true
    $lblStatus.Text = L 'Buscando bloatware instalado...' 'Looking for installed bloatware...'
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
    Write-Log (L "Bloatware: $($items.Count) apps prescindibles encontradas." "Bloatware: $($items.Count) unnecessary apps found.")
    Set-Busy $false
    Update-Selection
}

function Invoke-BloatRemove {
    $sel = @($bloatList.Items | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { Show-Info (L 'No hay ninguna app seleccionada.' 'No app is selected.'); return }
    $names = ($sel | ForEach-Object { '  • ' + $_.Tag.Name }) -join "`n"
    $msg = L "Se van a desinstalar $($sel.Count) apps:`n`n$names`n`nSe pueden volver a instalar desde Microsoft Store. ¿Continuar?" "$($sel.Count) apps will be uninstalled:`n`n$names`n`nThey can be reinstalled from the Microsoft Store. Continue?"
    if (-not (Confirm-Action $msg (L 'Confirmar desinstalación' 'Confirm uninstall') 'Warning')) { return }

    Set-Busy $true
    Write-Log (L '===== Desinstalación de bloatware =====' '===== Bloatware removal =====')

    if ($chkRestore.Checked -and $script:IsAdmin) {
        $lblStatus.Text = L 'Creando punto de restauración (puede tardar un minuto)...' 'Creating a restore point (may take a minute)...'
        Write-Log (L 'Creando punto de restauración...' 'Creating restore point...')
        $desc = L 'Limpiador de Windows: antes de quitar bloatware' 'Windows Cleaner: before removing bloatware'
        $cmd = "try { Checkpoint-Computer -Description '$desc' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; exit 0 } catch { exit 1 }"
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', $cmd -WindowStyle Hidden -PassThru
        Wait-Proc $p
        if ($p.ExitCode -eq 0) {
            Write-Log (L '  Punto de restauración creado (o ya existía uno de las últimas 24 h).' '  Restore point created (or one from the last 24 h already existed).')
        } else {
            Write-Log (L '  No se pudo crear el punto de restauración (¿Protección del sistema desactivada?).' '  Could not create the restore point (is System Protection disabled?).')
            $q = L "No se pudo crear el punto de restauración.`nProbablemente la Protección del sistema está desactivada.`n`n¿Continuar de todas formas?" "Could not create the restore point.`nSystem Protection is probably disabled.`n`nContinue anyway?"
            if (-not (Confirm-Action $q (L 'Punto de restauración' 'Restore point') 'Warning')) {
                Write-Log (L 'Cancelado.' 'Cancelled.'); Set-Busy $false; Update-Selection; return
            }
        }
    }

    $provList = @()
    if ($chkProv.Checked -and $script:IsAdmin) {
        $lblStatus.Text = L 'Leyendo apps preinstaladas de Windows...' 'Reading Windows preinstalled apps...'
        [System.Windows.Forms.Application]::DoEvents()
        try { $provList = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { Write-Log ((L '  Aviso: ' '  Warning: ') + $_.Exception.Message) }
    }

    $ok = 0; $fail = 0; $i = 0
    foreach ($it in $sel) {
        $i++
        $b = $it.Tag
        $progress.Value = [int](100 * ($i - 1) / $sel.Count)
        $lblStatus.Text = (L 'Desinstalando: ' 'Uninstalling: ') + "$($b.Name)..."
        [System.Windows.Forms.Application]::DoEvents()
        Write-Log ((L 'Desinstalando: ' 'Uninstalling: ') + "$($b.Name) ($($b.Id))")
        try {
            Remove-BloatItem $b $provList
            Write-Log '  OK'
            $bloatList.Items.Remove($it)
            $ok++
        } catch {
            Write-Log ("  Error: " + $_.Exception.Message)
            $it.ForeColor = [System.Drawing.Color]::Firebrick
            $fail++
        }
    }
    Write-Log (L "===== Fin. Desinstaladas: $ok · Con error: $fail =====" "===== Done. Uninstalled: $ok · Failed: $fail =====")
    Set-Busy $false
    Update-Info
    Update-Selection
    $extra = if ($fail -gt 0) { L "`nCon error: $fail (detalles en el registro inferior)" "`nFailed: $fail (details in the log below)" } else { '' }
    Show-Info ((L "Desinstalación completada.`n`nDesinstaladas: $ok" "Uninstall completed.`n`nUninstalled: $ok") + $extra)
}

# ---------- 3. Optimizar
function Update-OptList {
    foreach ($it in $optList.Items) {
        try { $it.SubItems[1].Text = Get-OptStatus $it.Tag } catch { $it.SubItems[1].Text = '?' }
    }
}

function Invoke-OptRun {
    $sel = @($optList.Items | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { Show-Info (L 'No hay ninguna acción seleccionada.' 'No action is selected.'); return }
    $names = ($sel | ForEach-Object { '  • ' + $_.Tag.Name }) -join "`n"
    $msg = L "Se va a ejecutar:`n`n$names`n`nAlgunas tareas pueden tardar varios minutos. No cierres la ventana mientras tanto. ¿Continuar?" "The following will run:`n`n$names`n`nSome tasks may take several minutes. Do not close the window meanwhile. Continue?"
    if (-not (Confirm-Action $msg (L 'Confirmar optimización' 'Confirm optimization'))) { return }

    Set-Busy $true
    Write-Log (L '===== Optimización =====' '===== Optimization =====')
    $i = 0
    foreach ($it in $sel) {
        $i++
        $o = $it.Tag
        $progress.Value = [int](100 * ($i - 1) / $sel.Count)
        $lblStatus.Text = L "Ejecutando: $($o.Name)... (puede tardar)" "Running: $($o.Name)... (may take a while)"
        $it.SubItems[1].Text = L 'En curso...' 'Running...'
        [System.Windows.Forms.Application]::DoEvents()
        Write-Log ((L 'Ejecutando: ' 'Running: ') + $o.Name)
        try {
            if ($o.Run) { & $o.Run }
            elseif ($o.Apply) { & $o.Apply }
            elseif ($o.Values) { Set-RegToggle $o }
        } catch {
            Write-Log ("  Error: " + $_.Exception.Message)
        }
        $script:Internal = $true; $it.Checked = $false; $script:Internal = $false
        try { $it.SubItems[1].Text = Get-OptStatus $o } catch { }
    }
    Write-Log (L '===== Fin de la optimización =====' '===== Optimization finished =====')
    Set-Busy $false
    Update-Info
    Update-Selection
    Show-Info (L 'Optimización terminada. Revisa el registro inferior para ver los resultados.' 'Optimization finished. Check the log below for the results.')
}

function Invoke-OptUndo {
    $undoable = @($Optimizations | Where-Object { ($_.Values -or $_.Undo) -and (Test-HasBackup $_) })
    if ($undoable.Count -eq 0) { Show-Info (L 'No hay ajustes aplicados por esta herramienta que deshacer.' 'There are no tweaks applied by this tool to undo.'); return }
    $names = ($undoable | ForEach-Object { '  • ' + $_.Name }) -join "`n"
    if (-not (Confirm-Action (L "Se restaurarán los valores originales de:`n`n$names`n`n¿Continuar?" "The original values of the following will be restored:`n`n$names`n`nContinue?") (L 'Deshacer ajustes' 'Undo tweaks'))) { return }
    Set-Busy $true
    Write-Log (L '===== Deshacer ajustes =====' '===== Undo tweaks =====')
    foreach ($o in $undoable) {
        Write-Log ((L 'Restaurando: ' 'Restoring: ') + $o.Name)
        try {
            if ($o.Undo) { & $o.Undo }
            else { $n = Undo-RegToggle $o; Write-Log (L "  $n valores restaurados." "  $n values restored.") }
        } catch { Write-Log ("  Error: " + $_.Exception.Message) }
    }
    Update-OptList
    Set-Busy $false
    Update-Info
    Update-Selection
    Show-Info (L 'Ajustes restaurados. Algunos cambios visuales se aplican del todo al cerrar sesión.' 'Tweaks restored. Some visual changes fully apply after signing out.')
}

# ---------- 4. Espacio
$script:SpaceRoot = $null
$script:SpaceSummary = L 'Elige una carpeta para analizar.' 'Choose a folder to scan.'

function Invoke-SpaceScan([string]$root) {
    if (-not $root -or -not (Test-SafeRoot $root)) { Show-Info ((L 'No se puede analizar: ' 'Cannot scan: ') + $root); return }
    $script:SpaceRoot = $root
    $lblSpPath.Text = (L 'Carpeta: ' 'Folder: ') + $root
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
        $lblStatus.Text = (L 'Analizando: ' 'Scanning: ') + $d.FullName
        [System.Windows.Forms.Application]::DoEvents()
        $rows += [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Size = (Measure-Tree $d.FullName $big) }
    }
    if ($rootFiles -gt 0) { $rows += [pscustomobject]@{ Name = (L '(archivos sueltos en esta carpeta)' '(loose files in this folder)'); Path = $null; Size = $rootFiles } }

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
    if ($script:Cancel) { $script:SpaceSummary += L ' (análisis cancelado: resultados parciales)' ' (scan cancelled: partial results)' }
    Write-Log ((L 'Espacio: ' 'Disk space: ') + $script:SpaceSummary)
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
    if ($sel.Count -eq 0) { Show-Info (L 'Selecciona uno o varios archivos en la lista de la derecha.' 'Select one or more files in the list on the right.'); return }
    $prot = @($sel | Where-Object { Test-Protected $_.Tag })
    $sel  = @($sel | Where-Object { -not (Test-Protected $_.Tag) })
    if ($prot.Count -gt 0) { Write-Log (L "Se omiten $($prot.Count) archivos protegidos del sistema." "Skipping $($prot.Count) protected system files.") }
    if ($sel.Count -eq 0) { Show-Info (L 'Los archivos seleccionados pertenecen a Windows o a programas instalados y están protegidos.' 'The selected files belong to Windows or installed programs and are protected.'); return }
    $names = ($sel | Select-Object -First 15 | ForEach-Object { '  • ' + $_.Text + '  (' + $_.SubItems[1].Text + ')' }) -join "`n"
    if ($sel.Count -gt 15) { $names += L "`n  ... y $($sel.Count - 15) más" "`n  ... and $($sel.Count - 15) more" }
    $msg = L "Se enviarán a la papelera $($sel.Count) archivos:`n`n$names`n`nPodrás recuperarlos desde la papelera. ¿Continuar?" "$($sel.Count) files will be sent to the Recycle Bin:`n`n$names`n`nYou can restore them from the Recycle Bin. Continue?"
    if (-not (Confirm-Action $msg (L 'Enviar a la papelera' 'Send to Recycle Bin') 'Warning')) { return }
    Set-Busy $true
    $ok = 0
    foreach ($it in $sel) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($it.Tag, 'OnlyErrorDialogs', 'SendToRecycleBin')
            Write-Log ((L 'Enviado a la papelera: ' 'Sent to Recycle Bin: ') + $it.Tag)
            $lvFiles.Items.Remove($it)
            $ok++
        } catch {
            Write-Log ("  Error ($($it.Tag)): " + $_.Exception.Message)
        }
    }
    Set-Busy $false
    Update-Info
    Update-Selection
    Show-Info (L "$ok archivos enviados a la papelera.`nRecuerda vaciar la papelera para liberar el espacio." "$ok files sent to the Recycle Bin.`nRemember to empty the Recycle Bin to free the space.")
}

# ================================================================ Eventos =====
$script:BloatLoaded = $false
$script:SpaceLoaded = $false

foreach ($lv in $list, $bloatList, $optList) { Add-CheckGuard $lv }

$cmbLang.Add_SelectedIndexChanged({ Set-Language })

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
        $txt = "$p  ·  $($e.Item.SubItems[1].Text)  ·  " + (L 'modificado ' 'modified ') + $e.Item.SubItems[2].Text
        if (Test-Protected $p) { $txt += L '  ·  PROTEGIDO (archivo del sistema o de programas)' '  ·  PROTECTED (system or program file)' }
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
    $dlg.Description = L 'Elige la carpeta que quieres analizar' 'Choose the folder you want to scan'
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
$btnCancel.Add_Click({ $script:Cancel = $true; $btnCancel.Enabled = $false; $lblStatus.Text = L 'Cancelando...' 'Cancelling...' })

$form.Add_Shown({
    $form.Activate()
    Show-TabButtons
    Update-Info
    Write-Log "$AppName $AppVersion · $script:Machine · $script:RamGB GB RAM · $(L 'Discos' 'Disks'): $(Get-DiskSummary)"
    if (-not $script:IsAdmin) { Write-Log (L 'Sin permisos de administrador: las opciones del sistema están desactivadas.' 'No administrator rights: system options are disabled.') }
    if ($script:OtherUser) { Write-Log (L "Ejecutando como administrador con otra cuenta: se limpia el perfil de $script:TargetName." "Running as administrator with another account: cleaning the profile of $script:TargetName.") }
    Update-OptList
    Invoke-Analyze
})

[void]$form.ShowDialog()
