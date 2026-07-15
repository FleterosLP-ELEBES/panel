/* ==========================================================================
   Lago Puelo S.A. + Elebes S.A. — Panel de Fleteros
   app.js  ·  Lógica de la herramienta (vanilla JS, sin dependencias)
   - Anillo GENERAL, ranking y boletas: del reporte oficial de repartos.
   - Anillos por EMPRESA, clientes, motivos, vendedores y proveedores:
     del detalle de ventas (los genera el robot en data.js).
   ========================================================================== */
(function () {
  "use strict";

  var UMBRAL = { bueno: 90, medio: 75 };
  var MESES = ["ene", "feb", "mar", "abr", "may", "jun",
               "jul", "ago", "sep", "oct", "nov", "dic"];
  var NOMBRES_MES = ["enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];

  function safe(fn, name) {
    try { fn(); } catch (e) { console.error("[LPE] Error en " + name + ":", e); }
  }
  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function el(tag, cls, html) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }
  function pct(x) { return x == null ? null : Math.round(x * 1000) / 10; } // 1 decimal
  function claseColor(p) {
    if (p == null) return "n";
    if (p >= UMBRAL.bueno) return "ok";
    if (p >= UMBRAL.medio) return "mid";
    return "low";
  }
  function fmtFecha(iso) {
    var p = iso.split("-");
    if (p.length !== 3) return iso;
    return parseInt(p[2], 10) + " " + MESES[parseInt(p[1], 10) - 1];
  }
  function fmtNum(n) {
    return String(Math.round(n || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  }
  function esc(s) { return String(s).replace(/"/g, "&quot;"); }

  // ---- Componentes visuales --------------------------------------------
  function anillo(pValue, etiqueta, sub, general) {
    var p = pValue == null ? 0 : Math.max(0, Math.min(100, pValue));
    var cls = claseColor(pValue);
    var wrap = el("div", "ring ring--" + cls);
    var R = 52, C = 2 * Math.PI * R;
    wrap.innerHTML =
      '<svg viewBox="0 0 130 130" class="ring__svg" aria-hidden="true">' +
        '<circle class="ring__track" cx="65" cy="65" r="' + R + '"></circle>' +
        '<circle class="ring__val" cx="65" cy="65" r="' + R + '" ' +
          'stroke-dasharray="' + C.toFixed(1) + '" stroke-dashoffset="' + C.toFixed(1) + '"></circle>' +
      '</svg>' +
      '<div class="ring__center">' +
        '<span class="ring__num">' + (pValue == null ? "—" : "0") + '</span>' +
        '<span class="ring__pct">' + (pValue == null ? "" : "%") + '</span>' +
      '</div>';
    var block = el("div", "metric" + (general ? " metric--general" : ""));
    block.appendChild(wrap);
    block.appendChild(el("div", "metric__label", etiqueta + (sub ? '<span class="metric__sub">' + sub + '</span>' : "")));
    wrap._ring = { C: C, p: p, valEl: $(".ring__val", wrap), numEl: $(".ring__num", wrap), raw: pValue };
    return { block: block, wrap: wrap };
  }

  function animaAnillo(wrap) {
    var d = wrap._ring;
    if (!d || wrap._done) return;
    wrap._done = true;
    var offset = d.C * (1 - d.p / 100);
    requestAnimationFrame(function () {
      d.valEl.style.strokeDashoffset = offset.toFixed(1);
    });
    if (d.raw == null) return;
    var start = null, dur = 950;
    function step(t) {
      if (start == null) start = t;
      var k = Math.min(1, (t - start) / dur);
      var eased = 1 - Math.pow(1 - k, 3);
      d.numEl.textContent = (d.raw * eased).toFixed(1).replace(".0", "");
      if (k < 1) requestAnimationFrame(step);
      else d.numEl.textContent = (Math.round(d.raw * 10) / 10).toString().replace(/\.0$/, "");
    }
    requestAnimationFrame(step);
  }

  function chip(p) {
    var c = claseColor(p);
    var t = p == null ? "—" : (Math.round(p * 10) / 10).toString().replace(/\.0$/, "") + "%";
    return '<span class="chip chip--' + c + '">' + t + "</span>";
  }

  // Tarjeta gráfica de barras horizontales (una serie de cantidades).
  // sufijo: texto pegado al valor (por ej. "%").
  function graficoBarras(titulo, items, unidad, colorClase, sufijo) {
    if (!items || !items.length) return null;
    sufijo = sufijo || "";
    var max = items[0].cantidad || 1;
    items.forEach(function (it) { if (it.cantidad > max) max = it.cantidad; });
    var card = el("div", "chart reveal");
    var rows = items.map(function (it) {
      var w = Math.max(4, Math.round(100 * it.cantidad / max));
      return '<div class="chart__row" title="' + esc(it.etiqueta) + ' · ' + it.cantidad + sufijo + ' ' + unidad + '">' +
        '<div class="chart__top"><span class="chart__label">' + it.etiqueta + '</span>' +
        '<b class="chart__val">' + it.cantidad + sufijo + '</b></div>' +
        '<i class="chart__track"><i class="rank__fill rank__fill--' + (colorClase || "low") + '" style="width:2%" data-w="' + w + '"></i></i>' +
      '</div>';
    }).join("");
    card.innerHTML = '<h2 class="chart__title">' + titulo + '</h2>' + rows;
    return card;
  }

  // Datos agregados del mes por fletero, desde los registros oficiales.
  function resumenMes(datos) {
    var registros = datos.registros;
    var fechas = {};
    registros.forEach(function (r) { fechas[r.fecha] = 1; });
    var fechasTodas = Object.keys(fechas).sort();
    var mesPrefijo = fechasTodas.length ? fechasTodas[fechasTodas.length - 1].slice(0, 7) : "";
    var mesNombre = mesPrefijo ? NOMBRES_MES[parseInt(mesPrefijo.slice(5), 10) - 1] : "mes";
    var delMes = registros.filter(function (r) { return r.fecha.indexOf(mesPrefijo) === 0; });
    var porFletero = {};
    var totB = 0, totE = 0, totRep = 0;
    delMes.forEach(function (r) {
      totB += r.boletas; totE += r.entregadas; totRep += r.repartos;
      var f = porFletero[r.fletero];
      if (!f) f = porFletero[r.fletero] = { nombre: r.fletero, repartos: 0, boletas: 0, entregadas: 0, itemsRech: 0, ultima: "" };
      f.repartos += r.repartos; f.boletas += r.boletas; f.entregadas += r.entregadas;
      f.itemsRech += (r.itemsRech || 0);
      if (r.fecha > f.ultima) f.ultima = r.fecha;
    });
    return { mesNombre: mesNombre, porFletero: porFletero, totB: totB, totE: totE, totRep: totRep };
  }

  // ---- Vista: resumen general -------------------------------------------
  function vistaGeneral(datos) {
    var cont = el("div", "view");
    var m = resumenMes(datos);
    var efGeneral = m.totB > 0 ? m.totE / m.totB : null;

    // Anillos: general (oficial) + uno por empresa (detalle de ventas)
    var grid = el("div", "metrics reveal");
    var rings = [];
    var aG = anillo(pct(efGeneral), "Efectividad general", "las dos empresas · " + m.mesNombre, true);
    grid.appendChild(aG.block); rings.push(aG.wrap);
    (datos.empresas || []).forEach(function (e) {
      var ef = e.boletas > 0 ? (e.boletas - e.rechazadas) / e.boletas : null;
      var a = anillo(pct(ef), e.nombre, "total " + m.mesNombre);
      grid.appendChild(a.block); rings.push(a.wrap);
    });
    cont.appendChild(grid);
    cont._rings = rings;

    // Tarjetas de totales del mes. Boletas entregadas: solo se restan las boletas
    // rechazadas COMPLETAS (un producto suelto devuelto no voltea la boleta).
    var nombres = Object.keys(m.porFletero);
    var cli = datos.clientes || null;
    var bol = datos.boletasCsv || null;
    var celdas =
      '<div class="avg"><span class="avg__k">Repartos de ' + m.mesNombre + '</span><b>' + fmtNum(m.totRep) + '</b></div>';
    if (bol && bol.sac > 0) {
      celdas += '<div class="avg"><span class="avg__k">Boletas entregadas</span><b>' + fmtNum(bol.sac - bol.rech) + ' / ' + fmtNum(bol.sac) + '</b></div>';
    } else {
      celdas += '<div class="avg"><span class="avg__k">Boletas entregadas</span><b>' + fmtNum(m.totE) + ' / ' + fmtNum(m.totB) + '</b></div>';
    }
    if (cli && cli.sac > 0) {
      celdas += '<div class="avg"><span class="avg__k">Clientes entregados</span><b>' + fmtNum(cli.ent) + ' / ' + fmtNum(cli.sac) + '</b></div>';
    }
    celdas += '<div class="avg"><span class="avg__k">Fleteros activos</span><b>' + nombres.length + '</b></div>';
    var proms = el("div", "avgs reveal");
    proms.innerHTML = celdas;
    cont.appendChild(proms);

    // Tarjetas gráficas: motivos, fleteros con más clientes no entregados, vendedores
    var topMotivos = (datos.motivos || []).slice(0, 5).map(function (x) {
      return { etiqueta: x.motivo, cantidad: x.cantidad };
    });
    var statsF = datos.estadisticasFletero || {};
    var topFleteros = Object.keys(statsF).map(function (n) {
      return { etiqueta: n, cantidad: statsF[n].recTot || 0 };
    }).filter(function (x) { return x.cantidad > 0; })
      .sort(function (a, b) { return b.cantidad - a.cantidad; })
      .slice(0, 5);
    var topVend = (datos.vendedoresTop || []).slice(0, 5).map(function (x) {
      return { etiqueta: x.nombre, cantidad: x.cantidad };
    });
    var topProv = (datos.proveedoresTop || []).slice(0, 5).map(function (x) {
      return { etiqueta: x.nombre, cantidad: x.pct };
    });

    var g1 = graficoBarras("📋 Motivos de rechazo más comunes", topMotivos, "rechazos");
    var g2 = graficoBarras("⚠️ Rechazos totales de cliente · " + m.mesNombre, topFleteros, "clientes");
    var g3 = graficoBarras("🧑‍💼 Vendedores con más boletas rechazadas · " + m.mesNombre, topVend, "boletas");
    var g4 = graficoBarras("🏭 Proveedores con más rechazos · " + m.mesNombre, topProv, "de rechazo", null, "%");
    if (g1 || g2 || g3 || g4) {
      var fila = el("div", "charts");
      if (g1) fila.appendChild(g1);
      if (g2) fila.appendChild(g2);
      if (g3) fila.appendChild(g3);
      if (g4) fila.appendChild(g4);
      cont.appendChild(fila);
    }

    // Ranking único: todos los fleteros de las dos empresas
    var filas = nombres.map(function (n) {
      var f = m.porFletero[n];
      return {
        nombre: n,
        repartos: f.repartos,
        ef: f.boletas > 0 ? pct(f.entregadas / f.boletas) : null
      };
    }).filter(function (f) { return f.ef != null; })
      .sort(function (a, b) { return (b.ef || 0) - (a.ef || 0); });

    if (filas.length) {
      var tabla = el("div", "rank reveal");
      var head =
        '<div class="rank__head"><span>#</span><span>Fletero</span>' +
        '<span class="rank__num">Repartos</span>' +
        '<span class="rank__num">Entrega</span></div>';
      var body = filas.map(function (f, i) {
        var medal = i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : (i + 1);
        var bar = Math.max(4, Math.min(100, f.ef || 0));
        return '<button class="rank__row" data-fletero="' + esc(f.nombre) + '">' +
          '<span class="rank__pos">' + medal + '</span>' +
          '<span class="rank__name"><b>' + f.nombre + '</b>' +
            '<i class="rank__track"><i class="rank__fill rank__fill--' + claseColor(f.ef) + '" style="width:2%" data-w="' + bar + '"></i></i>' +
          '</span>' +
          '<span class="rank__num rank__reps">' + f.repartos + '<small>repartos</small></span>' +
          '<span class="rank__num">' + chip(f.ef) + '</span>' +
        '</button>';
      }).join("");
      tabla.innerHTML =
        '<h2 class="rank__title">🚚 Ranking · Efectividad de entrega · total ' + m.mesNombre + '</h2>' +
        '<div class="rank__grid">' + head + body + '</div>' +
        '<p class="rank__hint">Tocá un fletero para ver su detalle. Efectividad y repartos del mes en curso, de las dos empresas juntas.</p>';
      cont.appendChild(tabla);
    }

    return cont;
  }

  // ---- Vista: detalle de un fletero ---------------------------------------
  function vistaFletero(datos, nombre) {
    var cont = el("div", "view");
    var m = resumenMes(datos);
    var f = m.porFletero[nombre];

    var volver = el("button", "volver", "← Volver al resumen");
    volver.addEventListener("click", function () {
      seleccionar("__general__");
      var sel = $("#selector"); if (sel) sel.value = "__general__";
      window.scrollTo({ top: 0, behavior: "smooth" });
    });
    cont.appendChild(volver);

    if (!f) { cont.appendChild(el("p", "muted", "Sin datos para este fletero todavía.")); return cont; }

    // Encabezado del fletero
    var head = el("div", "person");
    head.innerHTML =
      '<div class="person__id"><span class="person__avatar">' +
        (nombre.trim().charAt(0).toUpperCase() || "?") + '</span>' +
        '<div><h2 class="person__name">' + nombre + '</h2>' +
        '<p class="person__meta">Último reparto: ' + fmtFecha(f.ultima) + '</p></div></div>';
    cont.appendChild(head);

    // Anillo con su efectividad del mes (cifra oficial)
    var ef = f.boletas > 0 ? f.entregadas / f.boletas : null;
    var grid = el("div", "metrics reveal");
    var aE = anillo(pct(ef), "Efectividad de entrega", "total " + m.mesNombre, true);
    grid.appendChild(aE.block);
    cont.appendChild(grid);
    cont._rings = [aE.wrap];

    // Sus números del mes. Boletas entregadas: solo se restan las rechazadas
    // COMPLETAS, así coincide con su tabla de motivos.
    var st = (datos.estadisticasFletero || {})[nombre];
    var celdas =
      '<div class="avg"><span class="avg__k">Repartos de ' + m.mesNombre + '</span><b>' + fmtNum(f.repartos) + '</b></div>';
    if (st && st.compSac > 0) {
      celdas += '<div class="avg"><span class="avg__k">Boletas entregadas</span><b>' + fmtNum(st.compEnt) + ' / ' + fmtNum(st.compSac) + '</b></div>' +
        '<div class="avg"><span class="avg__k">Boletas rechazadas completas</span><b class="rojo">' + fmtNum(st.compRech) + '</b></div>';
    } else {
      celdas += '<div class="avg"><span class="avg__k">Boletas entregadas</span><b>' + fmtNum(f.entregadas) + ' / ' + fmtNum(f.boletas) + '</b></div>';
    }
    if (st && st.cliSac > 0) {
      celdas += '<div class="avg"><span class="avg__k">Clientes entregados</span><b>' + fmtNum(st.cliEnt) + ' / ' + fmtNum(st.cliSac) + '</b></div>' +
        '<div class="avg"><span class="avg__k">Clientes no entregados</span><b class="rojo">' + fmtNum(st.recTot) + '</b></div>';
    }
    celdas += '<div class="avg"><span class="avg__k">Items rechazados <small>(productos)</small></span><b class="rojo">' + fmtNum(f.itemsRech) + '</b></div>';
    var proms = el("div", "avgs reveal");
    proms.innerHTML = celdas;
    cont.appendChild(proms);

    // Motivos de sus boletas rechazadas (solo boletas completas), medidos en %
    var mios = (datos.motivosPorFletero || {})[nombre] || [];
    if (mios.length) {
      var total = 0, maxM = 0;
      mios.forEach(function (x) { total += x.cantidad; if (x.cantidad > maxM) maxM = x.cantidad; });
      var card = el("div", "chart reveal");
      var rowsM = mios.map(function (x) {
        var p = Math.round(100 * x.cantidad / (total || 1));
        var w = Math.max(4, Math.round(100 * x.cantidad / (maxM || 1)));
        return '<div class="chart__row" title="' + esc(x.motivo) + ' · ' + x.cantidad + ' de ' + total + ' (' + p + '%)">' +
          '<div class="chart__top"><span class="chart__label">' + x.motivo + '</span>' +
          '<b class="chart__val">' + p + '%</b></div>' +
          '<i class="chart__track"><i class="rank__fill rank__fill--low" style="width:2%" data-w="' + w + '"></i></i>' +
        '</div>';
      }).join("");
      card.innerHTML = '<h2 class="chart__title">📋 Motivos de sus boletas rechazadas</h2>' + rowsM;
      cont.appendChild(card);
    }

    // Su entrega por proveedor (% en plata)
    var provs = (datos.proveedoresPorFletero || {})[nombre] || [];
    if (provs.length) {
      var maxP = 0;
      provs.forEach(function (p) { if (p.pct > maxP) maxP = p.pct; });
      var cardP = el("div", "chart reveal");
      var rowsP = provs.map(function (p) {
        var w = Math.max(4, Math.round(100 * p.pct / (maxP || 1)));
        return '<div class="chart__row">' +
          '<div class="chart__top"><span class="chart__label">' + p.prov + '</span>' +
          '<b class="chart__val">' + p.pct + '%</b></div>' +
          '<i class="chart__track"><i class="rank__fill rank__fill--' + claseColor(p.pct) + '" style="width:2%" data-w="' + w + '"></i></i>' +
        '</div>';
      }).join("");
      cardP.innerHTML = '<h2 class="chart__title">🏭 Su efectividad de entrega por proveedor</h2>' + rowsP;
      cont.appendChild(cardP);
    }

    return cont;
  }

  // ---- Reveal + animaciones al entrar en viewport -----------------------
  function activarReveal(scope) {
    var els = scope.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window)) {
      Array.prototype.forEach.call(els, function (e) { e.classList.add("in"); });
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); }
      });
    }, { threshold: 0.05 });
    Array.prototype.forEach.call(els, function (e) { io.observe(e); });
    setTimeout(function () {
      Array.prototype.forEach.call(els, function (e) { e.classList.add("in"); });
    }, 6000);
  }

  // ---- Render principal -------------------------------------------------
  var STATE = { datos: null, seleccion: "__general__" };

  function render() {
    var main = $("#panel");
    if (!main || !STATE.datos) return;
    main.innerHTML = "";
    var v = STATE.seleccion === "__general__"
      ? vistaGeneral(STATE.datos)
      : vistaFletero(STATE.datos, STATE.seleccion);
    main.appendChild(v);

    activarReveal(main);
    setTimeout(function () {
      if (v._rings) v._rings.forEach(animaAnillo);
      Array.prototype.forEach.call(main.querySelectorAll(".rank__fill"), function (f, i) {
        setTimeout(function () { f.style.width = (f.getAttribute("data-w") || 2) + "%"; }, 120 + i * 40);
      });
    }, 120);

    // click en filas del ranking → detalle del fletero
    Array.prototype.forEach.call(main.querySelectorAll(".rank__row[data-fletero]"), function (row) {
      row.addEventListener("click", function () {
        var n = row.getAttribute("data-fletero");
        seleccionar(n);
        var sel = $("#selector"); if (sel) sel.value = n;
        window.scrollTo({ top: 0, behavior: "smooth" });
      });
    });
  }

  function seleccionar(nombre) {
    STATE.seleccion = nombre;
    try { localStorage.setItem("lpe_fletero", nombre); } catch (e) {}
    render();
  }

  function poblarSelector() {
    var sel = $("#selector");
    if (!sel) return;
    sel.innerHTML = "";
    var opt0 = el("option", null, "📊 Resumen general");
    opt0.value = "__general__";
    sel.appendChild(opt0);
    var m = resumenMes(STATE.datos);
    Object.keys(m.porFletero).sort().forEach(function (n) {
      var o = el("option", null, n);
      o.value = n;
      sel.appendChild(o);
    });
    sel.addEventListener("change", function () { seleccionar(sel.value); });

    // Recordar selección previa (útil para el celular de cada fletero)
    var prev = null;
    try { prev = localStorage.getItem("lpe_fletero"); } catch (e) {}
    if (prev && (prev === "__general__" || m.porFletero[prev])) {
      STATE.seleccion = prev;
      sel.value = prev;
    }
  }

  function ultimaActualizacion(registros) {
    var max = "";
    registros.forEach(function (r) { if (r.fecha > max) max = r.fecha; });
    var lbl = $("#update-date");
    if (lbl) lbl.textContent = max ? fmtFecha(max) + " de " + (max.split("-")[0]) : "—";
  }

  function cargar() {
    var d = window.__LPE_DATA__ || {};
    STATE.datos = {
      registros: d.registros || [],
      empresas: d.empresas || [],
      clientes: d.clientes || null,
      boletasCsv: d.boletasCsv || null,
      motivos: d.motivos || [],
      motivosPorFletero: d.motivosPorFletero || {},
      estadisticasFletero: d.estadisticasFletero || {},
      vendedoresTop: d.vendedoresTop || [],
      proveedoresTop: d.proveedoresTop || [],
      proveedoresPorFletero: d.proveedoresPorFletero || {}
    };
    ultimaActualizacion(STATE.datos.registros);
    poblarSelector();
    render();
  }

  // ---- Splash + arranque ------------------------------------------------
  function ocultarSplash() {
    var s = $("#splash");
    if (s) { s.classList.add("hide"); setTimeout(function () { if (s.parentNode) s.parentNode.removeChild(s); }, 700); }
  }

  function init() {
    safe(cargar, "cargar");
    setTimeout(ocultarSplash, 550);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else { init(); }

  setTimeout(ocultarSplash, 4500);
})();
