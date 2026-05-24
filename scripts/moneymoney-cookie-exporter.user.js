// ==UserScript==
// @name         MoneyMoney Cookie Exporter (US-Banken)
// @namespace    https://github.com/rosch100/moneymoney-us-extensions
// @version      1.0
// @description  Session-Cookies für MoneyMoney — Bank of America, Fidelity, Presidential Bank
// @author       rosch100
// @match        https://*.fidelity.com/*
// @match        https://fidelity.com/*
// @match        https://*.bankofamerica.com/*
// @match        https://bankofamerica.com/*
// @match        https://*.presidentialpcbanking.com/*
// @match        https://presidentialpcbanking.com/*
// @grant        GM.cookie
// @grant        GM_cookie
// @grant        GM_setClipboard
// @grant        GM.setClipboard
// @grant        GM.notification
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  const BANKS = {
    fidelity: {
      label: 'Fidelity',
      match: /fidelity\.com$/i,
      cookieDomain: '.fidelity.com',
      origins: [
        'https://digital.fidelity.com',
        'https://login.fidelity.com',
        'https://www.fidelity.com',
        'https://ecaap.fidelity.com',
        'https://fidelity.com',
      ],
      critical: ['_abck', 'bm_sz', 'ATC', 'ET', 'SESSION_SCTX', 'PIT'],
      priority: [
        '_abck', 'bm_sz', 'bm_s', 'bm_sv', 'bm_so', 'bm_ss', 'bm_mi', 'bm_lso', 'ak_bmsc',
        'ATC', 'ATT', 'ET', 'SESSION_SCTX', 'JSESSIONID',
        'FC', 'MC', 'PIT', 'RC', 'SC',
        'PORTSUM_XSRF-TOKEN', 'FVL-XSRF-TOKEN',
        'AWSALB', 'AWSALBCORS',
      ],
    },
    boa: {
      label: 'Bank of America',
      match: /bankofamerica\.com$/i,
      cookieDomain: '.bankofamerica.com',
      origins: [
        'https://secure.bankofamerica.com',
        'https://www.bankofamerica.com',
        'https://bankofamerica.com',
      ],
      critical: ['SMSESSION', 'SSOTOKEN', 'LSESSIONID'],
      priority: [
        'SMSESSION', 'SSOTOKEN', 'LSESSIONID', 'GSID', 'CSID', 'MMID', 'cdSNum', 'ctd',
        'bm_sv', 'bm_sz', 'bmuid', 'ak_bmsc',
      ],
    },
    presidential: {
      label: 'Presidential Bank',
      match: /presidentialpcbanking\.com$/i,
      cookieDomain: '.presidentialpcbanking.com',
      origins: ['https://www.presidentialpcbanking.com'],
      critical: ['SESSION_TOKEN', 'rftoken'],
      priority: [
        'SESSION_TOKEN', 'SESSION', 'FMISSESSIONID',
        'tkt', 'at', 'ag', 'rftoken', 'USPIBID',
        '__cf_bm', '_cfuvid', 'cf_clearance',
      ],
    },
  };

  let panelReady = false;
  let lastSource = 'document.cookie';

  function detectBank() {
    const host = location.hostname.replace(/^www\./, '');
    for (const bank of Object.values(BANKS)) {
      if (bank.match.test(host)) {
        return bank;
      }
    }
    return null;
  }

  function parseDocumentCookies() {
    const cookies = {};
    if (!document.cookie) {
      return cookies;
    }
    document.cookie.split(';').forEach(function (part) {
      const idx = part.indexOf('=');
      if (idx <= 0) {
        return;
      }
      const name = part.slice(0, idx).trim();
      const value = part.slice(idx + 1).trim();
      if (name) {
        cookies[name] = value;
      }
    });
    return cookies;
  }

  function gmCookieList(details) {
    return new Promise(function (resolve) {
      if (typeof GM !== 'undefined' && GM.cookie && typeof GM.cookie.list === 'function') {
        GM.cookie.list(details).then(resolve).catch(function () { resolve([]); });
        return;
      }
      if (typeof GM_cookie !== 'undefined' && typeof GM_cookie.list === 'function') {
        GM_cookie.list(details, function (list) { resolve(list || []); });
        return;
      }
      resolve([]);
    });
  }

  async function collectCookiesViaGM(bank) {
    const merged = {};
    const seen = new Set();

    async function addFromList(details) {
      const list = await gmCookieList(details);
      list.forEach(function (item) {
        if (!item || !item.name || seen.has(item.name)) {
          return;
        }
        seen.add(item.name);
        merged[item.name] = item.value;
      });
      return list.length;
    }

    let apiCount = 0;
    if (typeof GM !== 'undefined' && GM.cookie && bank.cookieDomain) {
      apiCount += await addFromList({ domain: bank.cookieDomain });
    }
    for (const origin of bank.origins) {
      apiCount += await addFromList({ url: origin + '/' });
    }

    return { cookies: merged, apiCount: apiCount };
  }

  async function collectAllCookies(bank) {
    const docCookies = parseDocumentCookies();
    const gm = await collectCookiesViaGM(bank);

    if (gm.apiCount > 0) {
      lastSource = 'GM.cookie + document.cookie';
      return Object.assign({}, docCookies, gm.cookies);
    }

    lastSource = 'document.cookie';
    return docCookies;
  }

  function formatCookies(cookies, bank) {
    const pairs = [];
    const added = new Set();

    bank.priority.forEach(function (name) {
      if (cookies[name] && !added.has(name)) {
        pairs.push(name + '=' + cookies[name]);
        added.add(name);
      }
    });

    Object.keys(cookies).sort().forEach(function (name) {
      if (!added.has(name)) {
        pairs.push(name + '=' + cookies[name]);
        added.add(name);
      }
    });

    return pairs.join(';');
  }

  function missingCritical(cookies, bank) {
    return bank.critical.filter(function (name) { return !cookies[name]; });
  }

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (e) { /* next */ }
    }

    if (typeof GM !== 'undefined' && GM.setClipboard) {
      try {
        GM.setClipboard(text);
        return true;
      } catch (e) { /* next */ }
    }

    if (typeof GM_setClipboard !== 'undefined') {
      try {
        GM_setClipboard(text);
        return true;
      } catch (e) { /* next */ }
    }

    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0;';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch (e) { /* ignore */ }
    document.body.removeChild(ta);
    return ok;
  }

  function notify(title, text) {
    if (typeof GM !== 'undefined' && GM.notification) {
      GM.notification({ title: title, text: text, timeout: 4000 });
      return;
    }
    if (typeof GM_notification !== 'undefined') {
      GM_notification({ title: title, text: text, timeout: 4000 });
    }
  }

  function setStatus(html, level) {
    const el = document.getElementById('mm-status');
    if (!el) {
      return;
    }
    el.className = level || '';
    el.innerHTML = html;
  }

  async function refreshStatus(bank) {
    const cookies = await collectAllCookies(bank);
    const count = Object.keys(cookies).length;
    const missing = missingCritical(cookies, bank);
    const httpOnlyHint = lastSource === 'document.cookie'
      ? '<br><small>HttpOnly fehlt — Tampermonkey mit GM.cookie oder HAR-Export.</small>'
      : '<br><small>Quelle: ' + lastSource + '</small>';

    if (count === 0) {
      setStatus('Nicht eingeloggt.', 'error');
      return cookies;
    }

    if (missing.length === 0) {
      setStatus('<strong>Bereit</strong> — ' + count + ' Cookies' + httpOnlyHint, 'ok');
    } else {
      setStatus(
        '<strong>Unvollständig</strong> — fehlt: ' + missing.join(', ') + httpOnlyHint,
        'warn'
      );
    }
    return cookies;
  }

  async function exportCookies(bank) {
    const cookies = await collectAllCookies(bank);
    const output = 'COOKIE:' + formatCookies(cookies, bank);
    const copied = await copyText(output);
    const count = Object.keys(cookies).length;
    const debug = document.getElementById('mm-debug');
    const copyBtn = document.getElementById('mm-copy');

    if (debug) {
      debug.value = output;
      debug.style.display = 'block';
    }

    if (copied) {
      setStatus('<strong>Kopiert</strong> — ' + count + ' Cookies. Sofort in MoneyMoney einfügen.', 'ok');
      notify(bank.label + ' → MoneyMoney', count + ' Cookies kopiert.');
      if (copyBtn) {
        copyBtn.textContent = 'Kopiert';
        setTimeout(function () { copyBtn.textContent = 'Cookies kopieren'; }, 2000);
      }
    } else {
      setStatus('Kopieren fehlgeschlagen — Text unten manuell markieren.', 'warn');
    }
  }

  function createPanel(bank) {
    if (panelReady || document.getElementById('mm-cookie-panel')) {
      return;
    }

    const root = document.createElement('div');
    root.id = 'mm-cookie-panel';
    root.innerHTML =
      '<button id="mm-toggle" title="Cookie-Export (Alt+C)">MM</button>' +
      '<div id="mm-panel">' +
      '  <div id="mm-header"><span>' + bank.label + ' → MoneyMoney</span><button id="mm-close" type="button">×</button></div>' +
      '  <div id="mm-status">Lade…</div>' +
      '  <button id="mm-copy" type="button">Cookies kopieren</button>' +
      '  <textarea id="mm-debug" readonly spellcheck="false"></textarea>' +
      '</div>';

    const style = document.createElement('style');
    style.textContent =
      '#mm-cookie-panel{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:13px}' +
      '#mm-toggle{position:fixed;top:72px;right:16px;z-index:2147483647;width:44px;height:44px;border-radius:8px;' +
      'border:1px solid #ccc;background:#1a5f2a;color:#fff;font-weight:600;cursor:pointer}' +
      '#mm-panel{position:fixed;top:72px;right:16px;z-index:2147483646;display:none;width:300px;padding:12px;' +
      'border-radius:8px;background:#1a5f2a;color:#fff;box-shadow:0 4px 16px rgba(0,0,0,.35)}' +
      '#mm-panel.open{display:block}#mm-toggle.hidden{display:none}' +
      '#mm-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;font-weight:600}' +
      '#mm-close{background:transparent;border:none;color:#fff;font-size:18px;cursor:pointer}' +
      '#mm-status{padding:8px;border-radius:4px;margin-bottom:8px;background:rgba(0,0,0,.2);font-size:12px;line-height:1.4}' +
      '#mm-status.ok{background:rgba(76,175,80,.35)}#mm-status.warn{background:rgba(255,152,0,.35)}' +
      '#mm-status.error{background:rgba(244,67,54,.35)}' +
      '#mm-copy{width:100%;padding:10px;border:none;border-radius:4px;background:#4caf50;color:#fff;font-weight:600;cursor:pointer}' +
      '#mm-debug{display:none;width:100%;height:120px;margin-top:8px;font:11px/1.3 monospace;resize:vertical}';

    document.head.appendChild(style);
    document.body.appendChild(root);
    panelReady = true;

    const panel = document.getElementById('mm-panel');
    const toggle = document.getElementById('mm-toggle');

    document.getElementById('mm-close').onclick = function () {
      panel.classList.remove('open');
      toggle.classList.remove('hidden');
    };

    toggle.onclick = function () {
      panel.classList.add('open');
      toggle.classList.add('hidden');
      refreshStatus(bank);
    };

    document.getElementById('mm-copy').onclick = function () { exportCookies(bank); };

    refreshStatus(bank);
  }

  function init() {
    const bank = detectBank();
    if (!bank) {
      return;
    }

    if (document.body) {
      createPanel(bank);
    } else {
      document.addEventListener('DOMContentLoaded', function () { createPanel(bank); }, { once: true });
    }
  }

  init();

  document.addEventListener('keydown', function (e) {
    if (e.altKey && (e.key === 'c' || e.key === 'C')) {
      e.preventDefault();
      const toggle = document.getElementById('mm-toggle');
      if (toggle) {
        toggle.click();
      }
    }
  });

  let lastUrl = location.href;
  setInterval(function () {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      panelReady = false;
      const old = document.getElementById('mm-cookie-panel');
      if (old) {
        old.remove();
      }
      setTimeout(init, 300);
    }
  }, 1000);
})();
