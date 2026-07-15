/* ==========================================================================
   Lago Puelo S.A. + Elebes S.A. — Panel de Fleteros
   app.js  ·  Lógica de la herramienta (vanilla JS, sin dependencias)
   - Anillo GENERAL y ranking: del reporte oficial de repartos (registros).
   - Anillos por EMPRESA: del detalle de ventas (empresas), calculados por el robot.
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

  // ---- Vista única: resumen general + ranking ---------------------------
  function vistaGeneral(datos) {
    var cont = el("div", "view");
    var registros = datos.registros;

    // Mes en curso = mes de la última fecha con datos
    var fechas = {};
    registros.forEach(function (r) { fechas[r.fecha] = 1; });
    var fechasTodas = Object.keys(fechas).sort();
    var mesPrefijo = fechasTodas.length ? fechasTodas[fechasTodas.length - 1].slice(0, 7) : "";
    var mesNombre = mesPrefijo ? NOMBRES_MES[parseInt(mesPrefijo.slice(5), 10) - 1] : "mes";
    var delMes = registros.filter(function (r) { return r.fecha.indexOf(mesPrefijo) === 0; });

    // Totales generales del mes (cifra oficial del reporte de repartos)
    var totB = 0, totE = 0, totRep = 0;
    var porFletero = {};
    delMes.forEach(function (r) {
      totB += r.boletas; totE += r.entregadas; totRep += r.repartos;
      var f = porFletero[r.fletero];
      if (!f) f = porFletero[r.fletero] = { nombre: r.fletero, repartos: 0, boletas: 0, entregadas: 0 };
      f.repartos += r.repartos; f.boletas += r.boletas; f.entregadas += r.entregadas;
    });
    var efGeneral = totB > 0 ? totE / totB : null;

    // Anillos: general (oficial) + uno por empresa (detalle de ventas)
    var grid = el("div", "metrics reveal");
    var rings = [];
    var aG = anillo(pct(efGeneral), "Efectividad general", "las dos empresas · " + mesNombre, true);
    grid.appendChild(aG.block); rings.push(aG.wrap);
    (datos.empresas || []).forEach(function (e) {
      var ef = e.boletas > 0 ? (e.boletas - e.rechazadas) / e.boletas : null;
      var a = anillo(pct(ef), e.nombre, "total " + mesNombre);
      grid.appendChild(a.block); rings.push(a.wrap);
    });
    cont.appendChild(grid);
    cont._rings = rings;

    // Tarjetas de totales del mes
    var nombres = Object.keys(porFletero);
    var cli = datos.clientes || null;
    var celdas =
      '<div class="avg"><span class="avg__k">Repartos de ' + mesNombre + '</span><b>' + fmtNum(totRep) + '</b></div>' +
      '<div class="avg"><span class="avg__k">Boletas entregadas</span><b>' + fmtNum(totE) + ' / ' + fmtNum(totB) + '</b></div>';
    if (cli && cli.sac > 0) {
      celdas += '<div class="avg"><span class="avg__k">Clientes entregados</span><b>' + fmtNum(cli.ent) + ' / ' + fmtNum(cli.sac) + '</b></div>';
    }
    celdas += '<div class="avg"><span class="avg__k">Fleteros activos</span><b>' + nombres.length + '</b></div>';
    var proms = el("div", "avgs reveal");
    proms.innerHTML = celdas;
    cont.appendChild(proms);

    // Ranking único: todos los fleteros de las dos empresas
    var filas = nombres.map(function (n) {
      var f = porFletero[n];
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
        return '<div class="rank__row">' +
          '<span class="rank__pos">' + medal + '</span>' +
          '<span class="rank__name"><b>' + f.nombre + '</b>' +
            '<i class="rank__track"><i class="rank__fill rank__fill--' + claseColor(f.ef) + '" style="width:2%" data-w="' + bar + '"></i></i>' +
          '</span>' +
          '<span class="rank__num rank__reps">' + f.repartos + '<small>repartos</small></span>' +
          '<span class="rank__num">' + chip(f.ef) + '</span>' +
        '</div>';
      }).join("");
      tabla.innerHTML =
        '<h2 class="rank__title">🚚 Ranking · Efectividad de entrega · total ' + mesNombre + '</h2>' +
        '<div class="rank__grid">' + head + body + '</div>' +
        '<p class="rank__hint">Efectividad y repartos del mes en curso, de las dos empresas juntas.</p>';
      cont.appendChild(tabla);
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
  function render(datos) {
    var main = $("#panel");
    if (!main) return;
    main.innerHTML = "";
    var v = vistaGeneral(datos);
    main.appendChild(v);

    activarReveal(main);
    setTimeout(function () {
      if (v._rings) v._rings.forEach(animaAnillo);
      Array.prototype.forEach.call(main.querySelectorAll(".rank__fill"), function (f, i) {
        setTimeout(function () { f.style.width = (f.getAttribute("data-w") || 2) + "%"; }, 120 + i * 40);
      });
    }, 120);
  }

  function ultimaActualizacion(registros) {
    var max = "";
    registros.forEach(function (r) { if (r.fecha > max) max = r.fecha; });
    var lbl = $("#update-date");
    if (lbl) lbl.textContent = max ? fmtFecha(max) + " de " + (max.split("-")[0]) : "—";
  }

  function cargar() {
    var d = window.__LPE_DATA__ || {};
    var datos = { registros: d.registros || [], empresas: d.empresas || [], clientes: d.clientes || null };
    ultimaActualizacion(datos.registros);
    render(datos);
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
