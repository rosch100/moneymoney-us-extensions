// ==UserScript==
// @name         MoneyMoney Cookie Exporter (US-Banken)
// @namespace    https://github.com/rosch100/moneymoney-us-extensions
// @version      1.3
// @description  Session-Cookies für MoneyMoney
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
      sessionHost: 'secure.bankofamerica.com',
      sessionPath: '/myaccounts/details/card/account-details.go',
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
  let statusHint = '';

  function isSafari() {
    const ua = navigator.userAgent;
    return ua.includes('Safari') && !ua.includes('Chrome') && !ua.includes('Chromium');
  }

  function hasGmCookieApi() {
    return (typeof GM !== 'undefined' && GM.cookie && typeof GM.cookie.list === 'function')
      || (typeof GM_cookie !== 'undefined' && typeof GM_cookie.list === 'function');
  }

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
        GM_cookie.list(details, function (list, error) {
          resolve(error ? [] : (list || []));
        });
        return;
      }
      resolve([]);
    });
  }

  async function collectCookiesViaGM(bank) {
    const merged = {};
    const seen = new Set();
    const tried = new Set();

    async function addFromList(details) {
      const key = JSON.stringify(details);
      if (tried.has(key)) {
        return;
      }
      tried.add(key);
      const list = await gmCookieList(details);
      list.forEach(function (item) {
        if (item && item.name && !seen.has(item.name)) {
          seen.add(item.name);
          merged[item.name] = item.value;
        }
      });
    }

    const queries = [];
    if (bank.cookieDomain) {
      queries.push({ domain: bank.cookieDomain });
      queries.push({ domain: bank.cookieDomain.replace(/^\./, '') });
    }
    bank.origins.forEach(function (origin) {
      queries.push({ url: origin + '/' });
      queries.push({ url: origin + '/', partitionKey: {} });
    });
    if (location.href.startsWith('http')) {
      queries.push({ url: location.href });
      queries.push({ url: location.origin + '/' });
    }
    for (const query of queries) {
      await addFromList(query);
    }

    return merged;
  }

  function missingCritical(cookies, bank) {
    return bank.critical.filter(function (name) { return !cookies[name]; });
  }

  function buildHint(bank, cookies, gmCount) {
    if (missingCritical(cookies, bank).length === 0) {
      return '';
    }
    if (bank.sessionHost && location.hostname !== bank.sessionHost) {
      return 'Seite: ' + bank.sessionHost;
    }
    if (isSafari()) {
      return 'Safari: HAR oder crul (README).';
    }
    if (!hasGmCookieApi() || gmCount === 0) {
      return 'Tampermonkey: Cookie-Zugriff «Alle».';
    }
    return '';
  }

  async function collectAllCookies(bank) {
    const doc = parseDocumentCookies();
    const gm = await collectCookiesViaGM(bank);
    const merged = Object.assign({}, doc, gm);
    statusHint = buildHint(bank, merged, Object.keys(gm).length);
    return merged;
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

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (e) {}
    }
    if (typeof GM !== 'undefined' && GM.setClipboard) {
      try {
        GM.setClipboard(text);
        return true;
      } catch (e) {}
    }
    if (typeof GM_setClipboard !== 'undefined') {
      try {
        GM_setClipboard(text);
        return true;
      } catch (e) {}
    }
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;left:-9999px';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }

  function setStatus(text, level) {
    const el = document.getElementById('mm-status');
    if (!el) {
      return;
    }
    el.className = level || '';
    el.textContent = text + (statusHint ? ' — ' + statusHint : '');
  }

  async function refreshStatus(bank) {
    const cookies = await collectAllCookies(bank);
    const n = Object.keys(cookies).length;
    const missing = missingCritical(cookies, bank);
    if (n === 0) {
      setStatus('Nicht eingeloggt', 'error');
    } else if (missing.length === 0) {
      setStatus(n + ' Cookies bereit', 'ok');
    } else {
      setStatus('Fehlt: ' + missing.join(', '), 'warn');
    }
    return cookies;
  }

  async function exportCookies(bank) {
    const cookies = await collectAllCookies(bank);
    const missing = missingCritical(cookies, bank);
    const output = 'COOKIE:' + formatCookies(cookies, bank);
    const debug = document.getElementById('mm-debug');
    const copyBtn = document.getElementById('mm-copy');

    if (debug) {
      debug.value = output;
      debug.style.display = 'block';
    }
    if (missing.length > 0) {
      setStatus('Fehlt: ' + missing.join(', '), 'warn');
      return;
    }
    if (await copyText(output)) {
      setStatus('Kopiert', 'ok');
      if (copyBtn) {
        copyBtn.textContent = 'Kopiert';
        setTimeout(function () { copyBtn.textContent = 'Cookies kopieren'; }, 1500);
      }
    } else {
      setStatus('Manuell kopieren (Textfeld)', 'warn');
    }
  }

  function createPanel(bank) {
    if (panelReady || document.getElementById('mm-cookie-panel')) {
      return;
    }

    const root = document.createElement('div');
    root.id = 'mm-cookie-panel';
    root.innerHTML =
      '<button id="mm-toggle" title="Alt+C">MM</button>' +
      '<div id="mm-panel">' +
      '<div id="mm-header"><span>' + bank.label + '</span><button id="mm-close" type="button">×</button></div>' +
      '<div id="mm-status"></div>' +
      '<button id="mm-copy" type="button">Cookies kopieren</button>' +
      '<textarea id="mm-debug" readonly spellcheck="false"></textarea>' +
      '</div>';

    const style = document.createElement('style');
    style.textContent =
      '#mm-cookie-panel{font:13px/system-ui,sans-serif}' +
      '#mm-toggle{position:fixed;top:72px;right:16px;z-index:2147483647;width:40px;height:40px;border:1px solid #999;border-radius:6px;background:#1a5f2a;color:#fff;cursor:pointer}' +
      '#mm-panel{position:fixed;top:72px;right:16px;z-index:2147483646;display:none;width:280px;padding:10px;border-radius:6px;background:#1a5f2a;color:#fff;box-shadow:0 2px 12px rgba(0,0,0,.3)}' +
      '#mm-panel.open{display:block}#mm-toggle.hidden{display:none}' +
      '#mm-header{display:flex;justify-content:space-between;margin-bottom:8px;font-weight:600}' +
      '#mm-close{background:none;border:none;color:#fff;font-size:18px;cursor:pointer}' +
      '#mm-status{margin-bottom:8px;padding:6px;font-size:12px;background:rgba(0,0,0,.2)}' +
      '#mm-status.ok{background:rgba(76,175,80,.3)}#mm-status.warn{background:rgba(255,152,0,.3)}#mm-status.error{background:rgba(244,67,54,.3)}' +
      '#mm-copy{width:100%;padding:8px;border:none;border-radius:4px;background:#4caf50;color:#fff;cursor:pointer}' +
      '#mm-debug{display:none;width:100%;height:100px;margin-top:8px;font:11px monospace}';

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
    if (location.href === lastUrl) {
      return;
    }
    lastUrl = location.href;
    panelReady = false;
    const old = document.getElementById('mm-cookie-panel');
    if (old) {
      old.remove();
    }
    setTimeout(init, 300);
  }, 1000);
})();
