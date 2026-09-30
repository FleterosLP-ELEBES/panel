# ============================================================================
# ROBOT NUBE (GitHub Actions) - Panel Lago Puelo S.A. + Elebes S.A.
# Igual al robot local (robot-actualizar-web.ps1 v2/API) pero:
#   - credenciales por variables de entorno (secretos GESCOM_*)
#   - escribe data.js e historial-meses.json en el workspace; el workflow
#     los commitea (no publica por API de GitHub)
# Si se corre SIN GITHUB_WORKSPACE entra en modo PRUEBA LOCAL: usa las rutas
# y credenciales locales y escribe data-nube-prueba.js sin publicar.
# ============================================================================

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$EN_NUBE = [bool]$env:GITHUB_WORKSPACE
if ($EN_NUBE) {
  $CARPETA_PROYECTO = $env:GITHUB_WORKSPACE
  $HIST_FILE = Join-Path $CARPETA_PROYECTO "historial-meses.json"
} else {
  $CARPETA_PROYECTO = "C:\Users\luqaa\Documents\LagoPuelo-Elebes"
  $HIST_FILE = Join-Path $CARPETA_PROYECTO "robot\historial-meses.json"
}

$EXCLUIR = @("PEDIDOS INTERNOS", "SIN CHOFER", "RETIRA EN DEPOSITO")
$EMPRESA_COD = @{ "1" = "elebes"; "99" = "elebes"; "3" = "lagopuelo"; "97" = "lagopuelo" }
$EMPRESAS = @(
  @{ id = "lagopuelo"; nombre = "Lago Puelo S.A."; logo = "assets/img/logo-lagopuelo.jpg" },
  @{ id = "elebes";    nombre = "Elebes S.A.";     logo = "assets/img/logo-elebes.jpg" }
)

# Excepcion PUNTUAL (pedido de Lucas 7/9/2026; SOLO panel, NO se toca Gescom):
# SOLO estas 3 notas MAL FACTURADO de Marcos (SILVI-LORE, reparto 3017 del 1/9;
# error de administracion, no del fletero) NO cuentan como rechazo. Se sacan de
# TODO: rechazo en plata, boletas rechazadas, motivos y efectividad. Son SOLO
# estas 3 por numero de nota de credito, NO cualquier MAL FACTURADO. Revertir:
# vaciar la lista $EXC_NOTAS = @().
$EXC_NOTAS = @("118145", "118132", "118146")
function EsExcNota($vv) {
  return ([string]$vv.numeroComprobante -in $EXC_NOTAS)
}

function Log($msg) {
  # OJO: [Console] y no Write-Output — dentro de una funcion, Write-Output se
  # mezcla con el valor de retorno y contamina los datos (bug ya sufrido).
  [Console]::Out.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $msg)
}
Log "================ INICIO (NUBE) ================"

# --- Bajada inteligente: una sola por dia -----------------------------------
# En corridas automaticas (schedule), si el data.js del repo ya tiene la fecha
# de HOY, salimos sin pegarle a Gescom. Asi los reintentos del turno saltan en
# 1s y la tarde solo baja si fallo la manana entera. Las corridas MANUALES
# (workflow_dispatch) NUNCA saltan, para poder forzar.
if ($EN_NUBE -and $env:GITHUB_EVENT_NAME -eq "schedule" -and -not $env:FORCE_MES) {
  $dataJsRepo = Join-Path $CARPETA_PROYECTO "data.js"
  if (Test-Path $dataJsRepo) {
    $cab = (Get-Content $dataJsRepo -TotalCount 3 -Encoding UTF8) -join " "
    $hoyStr = (Get-Date -Format "yyyy-MM-dd")
    if ($cab -match ("Ultima actualizacion: " + [regex]::Escape($hoyStr))) {
      Log "Datos de hoy ($hoyStr) ya publicados: no hace falta bajar de nuevo"
      Log "================ FIN (NUBE) ================"
      exit 0
    }
  }
}

# --- Fuente: BASE de Gescom (datos-gescom) ----------------------------------
# Desde el 30/9/2026 el robot NO le pide nada a la API de Gescom: lee la base
# gescom-lagopuelo por datos-gescom con una clave propia del panel (secreto
# DATOS_GESCOM_CLAVE). Tope 120 consultas/hora y 20.000 filas/respuesta, por eso
# las consultas grandes se paginan. Una corrida usa unas 10.
$URL_BASE = "https://datos-gescom.panelempresas.workers.dev/consulta"
# Trim: un salto de linea colado en un secreto rompe el encabezado
$claveBase = ([string]$env:DATOS_GESCOM_CLAVE).Trim()
if (-not $claveBase) {
  # Modo prueba local: la clave del panel, del archivo de claves de la base
  $archClaves = "C:\Users\luqaa\Documents\Panel-Ventas\base\claves-companeros.txt"
  if (Test-Path $archClaves) {
    foreach ($lg in Get-Content $archClaves -Encoding UTF8) {
      if ($lg -match '^PANEL-FLETEROS-LPE \(.*\): (\S+)\s*$') { $claveBase = $matches[1] }
    }
  }
}
if (-not $claveBase) { Log "ERROR: falta el secreto DATOS_GESCOM_CLAVE (la clave del panel para leer la base)"; exit 1 }
$script:nConsultas = 0

function Get-Base($sql) {
  # Una consulta SELECT a la base. Reintenta ante cortes de red o fallas del
  # servidor; corta enseguida si la base rechaza la consulta (400), la clave (401)
  # o el tope por hora (429). Una respuesta CORTADA (>20.000 filas) tambien aborta.
  # OJO: devuelve la lista con la coma adelante; asignarla a una variable y
  # recorrer esa variable (nunca @(Get-Base ...), que la envuelve en 1 elemento).
  $cuerpo = [System.Text.Encoding]::UTF8.GetBytes((@{ sql = $sql } | ConvertTo-Json -Compress))
  $esperas = @(10, 30, 60); $n = 0
  while ($true) {
    try {
      $script:nConsultas++
      $r = Invoke-RestMethod -Method Post -Uri $URL_BASE -Headers @{ Authorization = "Bearer " + $claveBase } `
        -ContentType "application/json; charset=utf-8" -Body $cuerpo -TimeoutSec 120
      break
    } catch {
      $st = 0; try { $st = [int]$_.Exception.Response.StatusCode } catch { }
      if ($st -eq 400 -or $st -eq 401 -or $st -eq 429 -or $n -ge $esperas.Count) { throw }
      Start-Sleep -Seconds $esperas[$n]; $n++
    }
  }
  if ($r.truncado) { throw ("la base corto la respuesta en " + $r.cantidad + " filas (hay que paginar): " + $sql.Substring(0, [Math]::Min(90, $sql.Length))) }
  return ,@($r.filas)
}

function Get-BasePaginado($sql, $orden) {
  # Para consultas que pueden pasar las 20.000 filas: de a 15.000, en orden fijo.
  $todo = New-Object System.Collections.ArrayList
  $desde = 0; $pag = 15000
  while ($true) {
    $f = Get-Base ($sql + " ORDER BY " + $orden + " LIMIT " + $pag + " OFFSET " + $desde)
    foreach ($x in $f) { [void]$todo.Add($x) }
    if ($f.Count -lt $pag) { break }
    $desde += $pag
  }
  return ,$todo
}

# --- Mes en curso ------------------------------------------------------------
$hoy = (Get-Date).ToString("yyyy-MM-dd")
$mesIniDt = Get-Date -Day 1
$mesIni = $mesIniDt.ToString("yyyy-MM-01")
$mesActual = $mesIniDt.ToString("yyyy-MM")
$mesFinExcl = $mesIniDt.AddMonths(1).ToString("yyyy-MM-dd")
# Escape hatch / refresco de cierre: FORCE_MES=yyyy-MM recalcula ese mes.
# Se usa para el re-chequeo del mes anterior cuando cierran los camiones.
if ($env:FORCE_MES -match '^\d{4}-\d{2}$') {
  $mesIniDt = [DateTime]($env:FORCE_MES + "-01")
  $mesIni = $mesIniDt.ToString("yyyy-MM-01")
  $mesActual = $mesIniDt.ToString("yyyy-MM")
  $mesFinExcl = $mesIniDt.AddMonths(1).ToString("yyyy-MM-dd")
  Log "FORZADO mes = $mesActual"
  # Si ese mes ya quedo cerrado definitivo (camiones cerrados), no re-bajar.
  if (Test-Path $HIST_FILE) {
    try {
      $hChk = Get-Content $HIST_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($hChk.$mesActual -and $hChk.$mesActual.cierreFinal -eq $true) {
        Log "Mes $mesActual ya cerrado definitivo: no hace falta re-bajar"
        Log "================ FIN (NUBE) ================"
        exit 0
      }
    } catch { }
  }
}

# --- 1) Repartos del mes (de la base) ---------------------------------------
# fechahasta es EXCLUSIVA (como antes con la API): fecha < mesFinExcl.
function Repartos-DelMes($desde, $hastaExcl) {
  return Get-Base ("SELECT codigo, fecha, chofer, nombre_chofer, cerrado FROM repartos " +
    "WHERE fecha >= '" + $desde + "' AND fecha < '" + $hastaExcl + "'")
}
$listaRepartos = Repartos-DelMes $mesIni $mesFinExcl
if (@($listaRepartos).Count -eq 0) {
  $mesIniDt = $mesIniDt.AddMonths(-1)
  $mesIni = $mesIniDt.ToString("yyyy-MM-01")
  $mesActual = $mesIniDt.ToString("yyyy-MM")
  $mesFinExcl = $mesIniDt.AddMonths(1).ToString("yyyy-MM-dd")
  $listaRepartos = Repartos-DelMes $mesIni $mesFinExcl
}
$repInfo = @{}
$repAbiertos = 0   # camiones del mes todavia sin cerrar (rendir)
foreach ($rpx in $listaRepartos) {
  $fch = [string]$rpx.fecha
  if ($fch.Length -lt 10) { continue }
  $fch = $fch.Substring(0, 10)
  if ($fch -gt $hoy) { continue }
  if ([int]$rpx.cerrado -ne 1) { $repAbiertos++ }
  $choR = ""
  if ($rpx.nombre_chofer) { $choR = (([string]$rpx.nombre_chofer).Trim().ToUpper() -replace "\s+", " ") }
  $repInfo[[string]$rpx.codigo] = @{ fecha = $fch; chofer = $choR }
}
Log ("Repartos del mes ($mesActual): " + $repInfo.Count + " (sin cerrar: $repAbiertos)")
if ($repInfo.Count -eq 0) { Log "ERROR: la base no devolvio repartos; NO se publica nada"; exit 1 }

# --- 2) Catalogos (de la base) ----------------------------------------------
# OJO: guardar la respuesta en una variable ANTES de recorrerla (bug con @(funcion)).
# Choferes = empleados con el tipo CHF (Gescom no tiene una lista aparte).
$resp = Get-Base "SELECT codigo, nombre FROM empleados WHERE ',' || tipos || ',' LIKE '%,CHF,%'"
$mapaChofer = @{}
foreach ($x in $resp) { $mapaChofer[[string]$x.codigo] = (([string]$x.nombre).Trim().ToUpper() -replace "\s+", " ") }
$resp = Get-Base "SELECT codigo, nombre FROM vendedores"
$mapaVend = @{}
foreach ($x in $resp) { $mapaVend[[string]$x.codigo] = ([string]$x.nombre).Trim() }
$resp = Get-Base "SELECT codigo, nombre FROM proveedores"
$mapaProvNombre = @{}
foreach ($x in $resp) { $mapaProvNombre[[string]$x.codigo] = ([string]$x.nombre).Trim() }
$resp = Get-Base "SELECT codigo, proveedor FROM articulos"
$mapaArtProv = @{}
foreach ($x in $resp) { if ($x.proveedor) { $mapaArtProv[[string]$x.codigo] = [string]$x.proveedor } }
Log ("Catalogos: " + $mapaChofer.Count + " choferes, " + $mapaVend.Count + " vendedores, " + $mapaProvNombre.Count + " proveedores, " + $mapaArtProv.Count + " articulos")

# --- 3) Ventas (de la base) -------------------------------------------------
# La MISMA ventana que antes se le pedia a la API: cargadas (ventas.fecha =
# fechaPedido = dia de carga) entre mesIni-MARGEN y hoy, tipos VEN/DEV-RE/DEV-CA.
# El margen existe porque una boleta entregada este mes pudo cargarse el mes
# pasado (la preventa se carga antes de entregarse). Se arma cada venta con la
# MISMA forma que devolvia la API, asi el calculo de abajo queda intacto.
$MARGEN_DIAS = 7
$desdeDt = $mesIniDt.AddDays(-$MARGEN_DIAS)
$d1v = $desdeDt.ToString("yyyy-MM-dd")
$filtroV = "v.fecha BETWEEN '" + $d1v + "' AND '" + $hoy + "' AND v.tipo IN ('VEN', 'DEV-RE', 'DEV-CA')"
$ventasBase = Get-BasePaginado ("SELECT v.id, v.tipo, v.reparto, v.chofer, v.cliente, v.vendedor, v.empresa, " +
  "v.fecha, v.entrega, v.directa, v.ref_id, v.nro_comprobante, v.total, v.motivo " +
  "FROM ventas v WHERE " + $filtroV) "v.id"
# Los articulos, ya sumados por venta y proveedor: el calculo solo necesita
# unidades (cantidad x factor de empaque, en valor absoluto) e importe por
# proveedor. Mismas cuentas que hacia item por item, pero devuelve ~1/3 de filas.
$itemsBase = Get-BasePaginado ("SELECT i.venta_id AS vid, COALESCE(a.proveedor, '') AS prov, " +
  "SUM(ABS(i.cantidad) * (CASE WHEN i.factor > 0 THEN i.factor ELSE 1 END)) AS unid, SUM(ABS(i.total)) AS imp " +
  "FROM venta_items i JOIN ventas v ON v.id = i.venta_id LEFT JOIN articulos a ON a.codigo = i.articulo " +
  "WHERE " + $filtroV + " GROUP BY i.venta_id, COALESCE(a.proveedor, '')") "vid, prov"
$itemsPorVenta = @{}
foreach ($f in $itemsBase) {
  $kv = [string]$f.vid
  if (-not $itemsPorVenta[$kv]) { $itemsPorVenta[$kv] = New-Object System.Collections.ArrayList }
  # pseudo-renglon por proveedor: el factor ya va aplicado en unid, por eso 1
  $ci = "P|" + [string]$f.prov
  $mapaArtProv[$ci] = [string]$f.prov
  [void]$itemsPorVenta[$kv].Add(@{ cantidad = [double]$f.unid; unidadFactor = 1; importeTotal = [double]$f.imp; codigoItem = $ci })
}
$ventasPorId = @{}
foreach ($f in $ventasBase) {
  $its = $itemsPorVenta[[string]$f.id]
  if (-not $its) { $its = @() }
  $ref = $null
  if ($f.ref_id) { $ref = @{ id = $f.ref_id } }
  $ventasPorId[[string]$f.id] = @{
    id = $f.id; codigoTipoVenta = $f.tipo; codigoReparto = $f.reparto; codigoChofer = $f.chofer
    codigoCliente = $f.cliente; codigoVendedor = $f.vendedor; codigoEmpresa = ([string]$f.empresa)
    fechaPedido = $f.fecha; fechaEntrega = $f.entrega; ventaDirecta = ($f.directa -eq 1)
    ventaReferenciada = $ref; numeroComprobante = ([string]$f.nro_comprobante); motivo = $f.motivo
    importeTotal = $f.total; items = $its
  }
}
Log ("Ventas de la base: " + $ventasPorId.Count + " (consultas hasta aca: " + $script:nConsultas + ")")
if ($ventasPorId.Count -eq 0) { Log "ERROR: la base no devolvio ventas; NO se publica nada"; exit 1 }

# --- 4) Efectividad OFICIAL por chofer/dia ----------------------------------
$entregas = @{}
foreach ($idv in @($ventasPorId.Keys)) {
  $vv = $ventasPorId[$idv]
  $repC = [string]$vv.codigoReparto
  if (-not $repC -or -not $repInfo.ContainsKey($repC)) { continue }
  $fechaRep = $repInfo[$repC].fecha
  $choferRep = $repInfo[$repC].chofer
  if (-not $choferRep -or $choferRep -in $EXCLUIR) { continue }
  $clave = "$fechaRep|$choferRep"
  if (-not $entregas[$clave]) { $entregas[$clave] = @{ asig = 0; real = 0; reps = @{}; itemsRech = 0.0 } }
  $entregas[$clave].reps[$repC] = $true
  $tipoV = [string]$vv.codigoTipoVenta
  $fpd = [string]$vv.fechaPedido
  $fpDia = ""; if ($fpd.Length -ge 10) { $fpDia = $fpd.Substring(0, 10) }
  $esDirecta = $false
  if ($null -ne $vv.ventaDirecta) { $esDirecta = [bool]$vv.ventaDirecta }
  if ($tipoV -eq "VEN") {
    if (-not $esDirecta) { $entregas[$clave].asig++; $entregas[$clave].real++ }
  } elseif ($tipoV -eq "DEV-CA") {
    $entregas[$clave].asig++; $entregas[$clave].real++
  } elseif ($tipoV -eq "DEV-RE") {
    if ($fpDia -and $fpDia -lt $fechaRep) {
      $entregas[$clave].asig++; $entregas[$clave].real++
    } elseif (EsExcNota $vv) {
      # Excepcion puntual: estas 3 notas no restan (la boleta original ya conto como entregada)
    } else {
      $entregas[$clave].real--
      foreach ($itx in @($vv.items)) {
        $ufa = 1.0; if ($null -ne $itx.unidadFactor) { $ufa = [double]$itx.unidadFactor }
        $entregas[$clave].itemsRech += [Math]::Abs([double]$itx.cantidad) * $ufa
      }
    }
  }
}
$claves = @($entregas.Keys | Where-Object { $entregas[$_].asig -gt 0 } | Sort-Object)
Log ("Efectividad oficial: " + $claves.Count + " registros dia/chofer")

# --- 5) Estadisticas del mes ------------------------------------------------
$empStats = @{}
foreach ($emx in $EMPRESAS) { $empStats[$emx.id] = @{ ventas = @{}; rech = @{}; rechImp = 0.0 } }
$motivos = @{}; $motivosPorChofer = @{}; $statsChofer = @{}
$vendRech = @{}; $choProvFact = @{}; $choProvRech = @{}; $choRechImp = @{}
$cliDias = @{}; $facImp = @{}; $refImp = @{}; $facCho = @{}
$refMotivo = @{}; $choRefs = @{}
$empresasRaras = @{}
$cliSac = 0; $cliEnt = 0; $bolSac = 0; $bolCompTot = 0

foreach ($idv in @($ventasPorId.Keys)) {
  $vv = $ventasPorId[$idv]
  $tipoV = [string]$vv.codigoTipoVenta
  if ($tipoV -ne "VEN" -and $tipoV -ne "DEV-RE") { continue }
  $fev = [string]$vv.fechaEntrega
  if ($fev.Length -lt 10) { continue }
  $feDia = $fev.Substring(0, 10)
  if ($feDia.Substring(0, 7) -ne $mesActual -or $feDia -gt $hoy) { continue }
  $chox = $mapaChofer[[string]$vv.codigoChofer]
  if (-not $chox -or $chox -in $EXCLUIR) { continue }
  $empx = $EMPRESA_COD[[string]$vv.codigoEmpresa]
  if (-not $empx) {
    $ce = [string]$vv.codigoEmpresa
    if ($ce -and -not $empresasRaras[$ce]) { $empresasRaras[$ce] = $true }
    continue
  }
  $impTot = 0.0
  if ($null -ne $vv.importeTotal) { $impTot = [Math]::Abs([double]$vv.importeTotal) }
  if ($tipoV -eq "VEN") {
    $empStats[$empx].ventas[$idv] = $true
    $kcli = [string]$vv.codigoCliente + "|" + $feDia
    if (-not $cliDias[$kcli]) { $cliDias[$kcli] = @{ fac = @{}; cho = "" } }
    $cliDias[$kcli].fac[$idv] = $true
    $cliDias[$kcli].cho = $chox
    if (-not $facImp.ContainsKey($idv)) { $facImp[$idv] = 0.0 }
    $facImp[$idv] += $impTot
    $facCho[$idv] = $chox
    foreach ($itx in @($vv.items)) {
      $provC = $mapaArtProv[[string]$itx.codigoItem]
      $provN = "Otros"; if ($provC -and $mapaProvNombre[$provC]) { $provN = $mapaProvNombre[$provC] }
      $iimp = 0.0; if ($null -ne $itx.importeTotal) { $iimp = [Math]::Abs([double]$itx.importeTotal) }
      $kcp = "$chox|$provN"
      if (-not $choProvFact.ContainsKey($kcp)) { $choProvFact[$kcp] = 0.0 }
      $choProvFact[$kcp] += $iimp
    }
  } else {
    # Excepcion puntual: estas 3 notas no cuentan como rechazo (ver arriba)
    if (EsExcNota $vv) { continue }
    $refx = ""
    if ($null -ne $vv.ventaReferenciada -and $null -ne $vv.ventaReferenciada.id) { $refx = [string]$vv.ventaReferenciada.id }
    if (-not $refx) { $refx = $idv }
    $empStats[$empx].rech[$refx] = $true
    $empStats[$empx].rechImp += $impTot
    if (-not $refImp.ContainsKey($refx)) { $refImp[$refx] = 0.0 }
    $refImp[$refx] += $impTot
    if (-not $choRechImp.ContainsKey($chox)) { $choRechImp[$chox] = 0.0 }
    $choRechImp[$chox] += $impTot
    foreach ($itx in @($vv.items)) {
      $provC = $mapaArtProv[[string]$itx.codigoItem]
      $provN = "Otros"; if ($provC -and $mapaProvNombre[$provC]) { $provN = $mapaProvNombre[$provC] }
      $iimp = 0.0; if ($null -ne $itx.importeTotal) { $iimp = [Math]::Abs([double]$itx.importeTotal) }
      $kcp2 = "$chox|$provN"
      if (-not $choProvRech.ContainsKey($kcp2)) { $choProvRech[$kcp2] = 0.0 }
      $choProvRech[$kcp2] += $iimp
    }
    $venN = $mapaVend[[string]$vv.codigoVendedor]
    if ($venN) {
      if (-not $vendRech[$venN]) { $vendRech[$venN] = @{} }
      $vendRech[$venN][$refx] = $true
    }
    $choRefs["$chox|$refx"] = $true
    $motx = ([string]$vv.motivo).Trim() -replace "\s+", " "
    if (-not $motx) { $motx = "Sin especificar" }
    if (-not $motivos[$motx]) { $motivos[$motx] = 0 }
    $motivos[$motx]++
    if (-not $refMotivo.ContainsKey("$chox|$refx")) { $refMotivo["$chox|$refx"] = $motx }
  }
}
if ($empresasRaras.Count -gt 0) { Log ("AVISO: codigos de empresa no reconocidos: " + (@($empresasRaras.Keys) -join ", ")) }

$cliRechTot = 0
foreach ($kcli in @($cliDias.Keys)) {
  $dcl = $cliDias[$kcli]
  $nBol = $dcl.fac.Count
  if ($nBol -le 0) { continue }
  $cliSac++
  $cho9 = $dcl.cho
  if ($cho9 -and -not $statsChofer[$cho9]) { $statsChofer[$cho9] = @{ cliSac = 0; recTot = 0; compSac = 0; compRech = 0 } }
  if ($cho9) { $statsChofer[$cho9].cliSac++ }
  $bolComp = 0
  foreach ($fx in @($dcl.fac.Keys)) {
    $fiv = 0.0; if ($facImp.ContainsKey($fx)) { $fiv = $facImp[$fx] }
    $riv = 0.0; if ($refImp.ContainsKey($fx)) { $riv = $refImp[$fx] }
    if ($fiv -gt 0 -and $riv -ge (0.98 * $fiv)) { $bolComp++ }
  }
  if ($bolComp -ge $nBol) {
    $cliRechTot++
    if ($cho9) { $statsChofer[$cho9].recTot++ }
  }
}
$cliEnt = $cliSac - $cliRechTot
Log ("Clientes del mes: $cliSac salieron, $cliEnt entregados ($cliRechTot rechazados completos)")

foreach ($fx in @($facImp.Keys)) {
  $bolSac++
  $fiv = $facImp[$fx]
  $riv = 0.0; if ($refImp.ContainsKey($fx)) { $riv = $refImp[$fx] }
  $completa = ($fiv -gt 0 -and $riv -ge (0.98 * $fiv))
  if ($completa) { $bolCompTot++ }
  $choF = $facCho[$fx]
  if ($choF) {
    if (-not $statsChofer[$choF]) { $statsChofer[$choF] = @{ cliSac = 0; recTot = 0; compSac = 0; compRech = 0 } }
    $statsChofer[$choF].compSac++
    if ($completa) { $statsChofer[$choF].compRech++ }
  }
}
Log ("Boletas (API): $bolSac sacadas, $bolCompTot rechazadas completas")

foreach ($krf in @($choRefs.Keys)) {
  $ppk = $krf.Split("|"); $cho8 = $ppk[0]; $ref8 = $ppk[1]
  $fiv = 0.0; if ($facImp.ContainsKey($ref8)) { $fiv = $facImp[$ref8] }
  $riv = 0.0; if ($refImp.ContainsKey($ref8)) { $riv = $refImp[$ref8] }
  if (-not ($fiv -gt 0 -and $riv -ge (0.98 * $fiv))) { continue }
  $mot8 = $refMotivo[$krf]
  if (-not $mot8) { $mot8 = "Sin especificar" }
  if (-not $motivosPorChofer[$cho8]) { $motivosPorChofer[$cho8] = @{} }
  if (-not $motivosPorChofer[$cho8][$mot8]) { $motivosPorChofer[$cho8][$mot8] = 0 }
  $motivosPorChofer[$cho8][$mot8]++
}
Log ("Motivos OK: " + ($motivos.Values | Measure-Object -Sum).Sum + " rechazos, " + $motivos.Count + " motivos distintos, " + $motivosPorChofer.Count + " choferes con detalle")
foreach ($emx in $EMPRESAS) {
  $vC = $empStats[$emx.id].ventas.Count; $rC = $empStats[$emx.id].rech.Count
  $pctT = "sin datos"
  if ($vC -gt 0) { $pctT = [math]::Round(100.0 * ($vC - $rC) / $vC, 2).ToString() + "%" }
  Log ($emx.nombre + ": $vC boletas, $rC rechazadas -> " + $pctT)
}

# --- 6) Generar data.js -----------------------------------------------------
function NombreMostrar($chofer) {
  (($chofer.ToLower() -split "\s+") | ForEach-Object { if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1) } }) -join " "
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("/* GENERADO AUTOMATICAMENTE por robot-nube.ps1 (API Gescom, GitHub Actions) - NO EDITAR A MANO")
[void]$sb.AppendLine("   Ultima actualizacion: " + (Get-Date -Format "yyyy-MM-dd HH:mm") + " */")
[void]$sb.AppendLine("window.__LPE_DATA__ = { registros: [")
$primero = $true
foreach ($clave in $claves) {
  $pcl = $clave.Split("|"); $fechaR = $pcl[0]; $choferR = $pcl[1]
  $ee = $entregas[$clave]
  $coma = ","; if ($primero) { $coma = " "; $primero = $false }
  $json = '{"fecha":"' + $fechaR + '","fletero":"' + (NombreMostrar $choferR) + '","repartos":' + $ee.reps.Count + ',"boletas":' + $ee.asig + ',"entregadas":' + $ee.real + ',"itemsRech":' + [int][Math]::Round($ee.itemsRech) + '}'
  [void]$sb.AppendLine($coma + $json)
}
[void]$sb.AppendLine("] };")
$jEmp = foreach ($emx in $EMPRESAS) {
  $vC = $empStats[$emx.id].ventas.Count; $rC = $empStats[$emx.id].rech.Count
  '{"id":"' + $emx.id + '","nombre":"' + $emx.nombre + '","logo":"' + $emx.logo + '","boletas":' + $vC + ',"rechazadas":' + $rC + '}'
}
[void]$sb.AppendLine("window.__LPE_DATA__.empresas = [" + ($jEmp -join ",") + "];")
[void]$sb.AppendLine('window.__LPE_DATA__.clientes = {"sac":' + $cliSac + ',"ent":' + $cliEnt + '};')
[void]$sb.AppendLine('window.__LPE_DATA__.boletasCsv = {"sac":' + $bolSac + ',"rech":' + $bolCompTot + '};')
$rLP = [math]::Round($empStats["lagopuelo"].rechImp)
$rEL = [math]::Round($empStats["elebes"].rechImp)
[void]$sb.AppendLine('window.__LPE_DATA__.rechazoPlata = {"general":' + ($rLP + $rEL) + ',"lagopuelo":' + $rLP + ',"elebes":' + $rEL + '};')
function JsonTxt($s) { return ([string]$s -replace '\\', '\\\\' -replace '"', "'") }
$listaMot = @($motivos.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
  '{"motivo":"' + (JsonTxt $_.Key) + '","cantidad":' + $_.Value + '}'
})
[void]$sb.AppendLine("window.__LPE_DATA__.motivos = [" + ($listaMot -join ",") + "];")
$porFle = @(foreach ($cho in ($motivosPorChofer.Keys | Sort-Object)) {
  $lista = @($motivosPorChofer[$cho].GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    '{"motivo":"' + (JsonTxt $_.Key) + '","cantidad":' + $_.Value + '}'
  })
  '"' + (NombreMostrar $cho) + '":[' + ($lista -join ",") + ']'
})
[void]$sb.AppendLine("window.__LPE_DATA__.motivosPorFletero = {" + ($porFle -join ",") + "};")
$statsJson = @(foreach ($cho in ($statsChofer.Keys | Sort-Object)) {
  $sx = $statsChofer[$cho]
  $cs = 0; if ($sx.compSac) { $cs = $sx.compSac }
  $cr = 0; if ($sx.compRech) { $cr = $sx.compRech }
  $ri9 = 0; if ($choRechImp.ContainsKey($cho)) { $ri9 = [math]::Round($choRechImp[$cho]) }
  '"' + (NombreMostrar $cho) + '":{"cliSac":' + $sx.cliSac + ',"cliEnt":' + ($sx.cliSac - $sx.recTot) + ',"recTot":' + $sx.recTot +
    ',"compSac":' + $cs + ',"compEnt":' + ($cs - $cr) + ',"compRech":' + $cr + ',"rechImp":' + $ri9 + '}'
})
[void]$sb.AppendLine("window.__LPE_DATA__.estadisticasFletero = {" + ($statsJson -join ",") + "};")
$jVend = @($vendRech.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 5 | ForEach-Object {
  '{"nombre":"' + (JsonTxt $_.Key) + '","cantidad":' + $_.Value.Count + '}'
})
[void]$sb.AppendLine("window.__LPE_DATA__.vendedoresTop = [" + ($jVend -join ",") + "];")
$provTot = @{}
foreach ($kcp in @($choProvFact.Keys)) {
  $pr9 = $kcp.Split("|")[1]
  if (-not $provTot[$pr9]) { $provTot[$pr9] = @{ fac = 0.0; rech = 0.0 } }
  $provTot[$pr9].fac += $choProvFact[$kcp]
}
foreach ($kcp in @($choProvRech.Keys)) {
  $pr9 = $kcp.Split("|")[1]
  if (-not $provTot[$pr9]) { $provTot[$pr9] = @{ fac = 0.0; rech = 0.0 } }
  $provTot[$pr9].rech += $choProvRech[$kcp]
}
$provLista = @(foreach ($pr9 in @($provTot.Keys)) {
  $fv9 = $provTot[$pr9].fac
  if ($fv9 -lt 1000000) { continue }
  $rv9 = $provTot[$pr9].rech
  [PSCustomObject]@{ nombre = $pr9; pct = [math]::Round(100.0 * $rv9 / $fv9, 1) }
}) | Sort-Object pct -Descending | Select-Object -First 5
$jProvTop = @($provLista | ForEach-Object {
  '{"nombre":"' + (JsonTxt $_.nombre) + '","pct":' + (([string]$_.pct) -replace ",", ".") + '}'
})
[void]$sb.AppendLine("window.__LPE_DATA__.proveedoresTop = [" + ($jProvTop -join ",") + "];")
$porCho3 = @{}
foreach ($kcp in @($choProvFact.Keys)) {
  $pp3 = $kcp.Split("|"); $cho3 = $pp3[0]; $pr3 = $pp3[1]
  $fv = $choProvFact[$kcp]
  if ($fv -lt 100000) { continue }
  $rv = 0.0; if ($choProvRech.ContainsKey($kcp)) { $rv = $choProvRech[$kcp] }
  if (-not $porCho3[$cho3]) { $porCho3[$cho3] = New-Object System.Collections.ArrayList }
  [void]$porCho3[$cho3].Add([PSCustomObject]@{ prov = $pr3; fac = $fv; pct = [math]::Round(100.0 * ($fv - $rv) / $fv, 1) })
}
$jFleProv = @(foreach ($cho3 in ($porCho3.Keys | Sort-Object)) {
  $lst = @($porCho3[$cho3] | Sort-Object fac -Descending | Select-Object -First 6 | ForEach-Object {
    '{"prov":"' + (JsonTxt $_.prov) + '","pct":' + (([string]$_.pct) -replace ",", ".") + '}'
  })
  '"' + (NombreMostrar $cho3) + '":[' + ($lst -join ",") + ']'
})
[void]$sb.AppendLine("window.__LPE_DATA__.proveedoresPorFletero = {" + ($jFleProv -join ",") + "};")

# --- Resumen del MES ANTERIOR (para la tarjeta de cierre de mes) -------------
# Totales del mes en curso (se reusan tambien en el historial de la seccion 7)
$mB = 0; $mE = 0; $mR = 0
foreach ($clave in $claves) { $ee = $entregas[$clave]; $mB += $ee.asig; $mE += $ee.real; $mR += $ee.reps.Count }
$nFleteros = @($claves | ForEach-Object { $_.Split("|")[1] } | Sort-Object -Unique).Count
$hist = @{}
if (Test-Path $HIST_FILE) {
  try {
    $viejo = Get-Content $HIST_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($ph in $viejo.PSObject.Properties) { $hist[$ph.Name] = $ph.Value }
  } catch { Log "AVISO: no pude leer historial-meses.json, se regenera" }
}
$mesAntKey = ([DateTime]($mesActual + "-01")).AddMonths(-1).ToString("yyyy-MM")
$ma = $hist[$mesAntKey]
if ($ma) {
  $maEf = 0
  if ($null -ne $ma.efGeneral) { $maEf = $ma.efGeneral }
  elseif ($null -ne $ma.boletas -and [double]$ma.boletas -gt 0) { $maEf = [math]::Round(100.0 * $ma.entregadas / $ma.boletas, 1) }
  $maEmp = @()
  foreach ($emx in $EMPRESAS) {
    # OJO: NO usar $me (PS es case-insensitive y pisaria a $mE = total entregadas)
    $emH = $null; if ($null -ne $ma.empresas) { $emH = $ma.empresas.($emx.id) }
    $efE = 0
    if ($null -ne $emH) {
      if ($null -ne $emH.ef) { $efE = $emH.ef }
      elseif ($null -ne $emH.boletas -and [double]$emH.boletas -gt 0) { $efE = [math]::Round(100.0 * ($emH.boletas - $emH.rechazadas) / $emH.boletas, 1) }
    }
    $maEmp += '{"nombre":"' + $emx.nombre + '","ef":' + (([string]$efE) -replace ",", ".") + '}'
  }
  $maBSac = 0; if ($null -ne $ma.boletasSac) { $maBSac = [int]$ma.boletasSac }
  $maBRech = 0; if ($null -ne $ma.boletasRech) { $maBRech = [int]$ma.boletasRech }
  $maCSac = 0; if ($null -ne $ma.clientesSac) { $maCSac = [int]$ma.clientesSac }
  $maCEnt = 0; if ($null -ne $ma.clientesEnt) { $maCEnt = [int]$ma.clientesEnt }
  $maPlata = 0; if ($null -ne $ma.plataRech) { $maPlata = [long]$ma.plataRech }
  $maReps = 0; if ($null -ne $ma.repartos) { $maReps = [int]$ma.repartos }
  $maFlet = 0; if ($null -ne $ma.fleteros) { $maFlet = [int]$ma.fleteros }
  $maMes = [int]$mesAntKey.Substring(5, 2)
  $maAnio = [int]$mesAntKey.Substring(0, 4)
  $maRank = @()
  if ($null -ne $ma.ranking) {
    foreach ($rk in @($ma.ranking)) {
      $maRank += '{"nombre":"' + (JsonTxt $rk.nombre) + '","repartos":' + ([int]$rk.repartos) + ',"ef":' + (([string]$rk.ef) -replace ",", ".") + '}'
    }
  }
  $maJson = '{"clave":"' + $mesAntKey + '","anio":' + $maAnio + ',"mes":' + $maMes +
    ',"efGeneral":' + (([string]$maEf) -replace ",", ".") +
    ',"empresas":[' + ($maEmp -join ",") + ']' +
    ',"repartos":' + $maReps + ',"boletasEnt":' + ($maBSac - $maBRech) + ',"boletasSac":' + $maBSac +
    ',"clientesEnt":' + $maCEnt + ',"clientesSac":' + $maCSac +
    ',"plataRech":' + $maPlata + ',"fleteros":' + $maFlet +
    ',"ranking":[' + ($maRank -join ",") + ']}'
  [void]$sb.AppendLine("window.__LPE_DATA__.mesAnterior = " + $maJson + ";")
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $EN_NUBE) {
  $salidaPrueba = Join-Path $CARPETA_PROYECTO "robot\data-nube-prueba.js"
  [System.IO.File]::WriteAllText($salidaPrueba, $sb.ToString(), $utf8)
  Log "MODO PRUEBA LOCAL: data-nube-prueba.js generado, NO se publica"
  Log "================ FIN (NUBE) ================"
  exit 0
}
if ($env:FORCE_MES) {
  # Refresco del mes anterior: solo se toca el historial, NO la web del mes en curso
  Log "FORCE_MES: solo se refresca el historial, no se reescribe data.js"
} else {
  [System.IO.File]::WriteAllText((Join-Path $CARPETA_PROYECTO "data.js"), $sb.ToString(), $utf8)
  Log "data.js generado"
}

# --- 7) Historial mensual (lo commitea el workflow) --------------------------
# $hist, $mB, $mE, $mR y $nFleteros ya se calcularon en la seccion de mesAnterior.
$efGen = 0.0; if ($mB -gt 0) { $efGen = [math]::Round(100.0 * $mE / $mB, 1) }
$hEmp = @{}
foreach ($emx in $EMPRESAS) {
  $vC = $empStats[$emx.id].ventas.Count; $rC = $empStats[$emx.id].rech.Count
  $efE = 0.0; if ($vC -gt 0) { $efE = [math]::Round(100.0 * ($vC - $rC) / $vC, 1) }
  $hEmp[$emx.id] = @{ nombre = $emx.nombre; boletas = $vC; rechazadas = $rC; ef = $efE }
}
# Ranking por fletero del mes (para el "ver detalles" de la tarjeta de cierre)
$flMes = @{}
foreach ($clave in $claves) {
  $choK = $clave.Split("|")[1]
  $eeK = $entregas[$clave]
  if (-not $flMes[$choK]) { $flMes[$choK] = @{ reps = 0; bol = 0; ent = 0 } }
  $flMes[$choK].reps += $eeK.reps.Count
  $flMes[$choK].bol += $eeK.asig
  $flMes[$choK].ent += $eeK.real
}
$rankTmp = foreach ($choK in $flMes.Keys) {
  $fk = $flMes[$choK]
  $efK = 0.0; if ($fk.bol -gt 0) { $efK = [math]::Round(100.0 * $fk.ent / $fk.bol, 1) }
  [PSCustomObject]@{ nombre = (NombreMostrar $choK); repartos = $fk.reps; ef = $efK }
}
$rankFletero = @($rankTmp | Sort-Object ef -Descending)
# Cierre definitivo: solo en un refresco (FORCE_MES) y con TODOS los camiones cerrados.
$esCierreFinal = $false
if ($env:FORCE_MES -and $repAbiertos -eq 0) { $esCierreFinal = $true }
$hist[$mesActual] = @{
  boletas = $mB; entregadas = $mE; repartos = $mR; efGeneral = $efGen
  boletasSac = $bolSac; boletasRech = $bolCompTot
  clientesSac = $cliSac; clientesEnt = $cliEnt
  plataRech = ($rLP + $rEL); fleteros = $nFleteros
  empresas = $hEmp; ranking = $rankFletero
  cierreFinal = $esCierreFinal
  actualizado = (Get-Date -Format "yyyy-MM-dd")
}
if ($env:FORCE_MES) {
  if ($esCierreFinal) { Log "Mes $mesActual marcado como CIERRE FINAL (todos los camiones cerrados)" }
  else { Log "Mes $mesActual refrescado (aun $repAbiertos camiones sin cerrar; se reintentara)" }
}
[System.IO.File]::WriteAllText($HIST_FILE, ($hist | ConvertTo-Json -Depth 6), $utf8)
Log "Historial mensual actualizado ($mesActual)"
Log "================ FIN (NUBE) ================"
