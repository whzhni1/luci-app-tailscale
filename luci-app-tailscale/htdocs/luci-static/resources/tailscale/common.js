'use strict';
'require baseclass';
'require rpc';
'require ui';
'require uci';

const ASSET_VERSION = '2.0.0-52';
const callGetStatus = rpc.declare({ object: 'tailscale', method: 'getStatus', params: ['force_refresh'] });
const callGetStatusDerp = rpc.declare({ object: 'tailscale', method: 'getStatus', params: ['include_derp_map'] });
const callGetConfig = rpc.declare({ object: 'tailscale', method: 'getConfig', params: ['section'] });
const callSetConfig = rpc.declare({ object: 'tailscale', method: 'setConfig', params: ['section', 'values', 'apply'] });
const callGetSources = rpc.declare({ object: 'tailscale', method: 'getSources', params: ['proj', 'source'] });
const callGetVersionFiles = rpc.declare({ object: 'tailscale', method: 'getVersionFiles', params: ['proj', 'source', 'version'] });
const callRefreshSources = rpc.declare({ object: 'tailscale', method: 'refreshSources', params: ['source', 'proj'] });
const callResolveFile = rpc.declare({ object: 'tailscale', method: 'resolveFile', params: ['proj', 'source', 'version', 'file', 'arch'] });
const callGetFileSize = rpc.declare({ object: 'tailscale', method: 'getFileSize', params: ['source', 'file'] });
const callDownload = rpc.declare({ object: 'tailscale', method: 'download', params: ['proj', 'source', 'version', 'file', 'arch'] });
const callProgress = rpc.declare({ object: 'tailscale', method: 'progress', params: ['task_id'] });
const callCancelTask = rpc.declare({ object: 'tailscale', method: 'cancelTask', params: ['task_id'] });
const callBeginManualUpload = rpc.declare({ object: 'tailscale', method: 'beginManualUpload', params: ['name', 'size'] });
const callFinishManualUpload = rpc.declare({ object: 'tailscale', method: 'finishManualUpload', params: ['task_id'] });
const callApplyNetwork = rpc.declare({ object: 'tailscale', method: 'applyNetwork', params: ['token'] });
const callApplyCron = rpc.declare({ object: 'tailscale', method: 'applyCron' });
const callApplyUp = rpc.declare({ object: 'tailscale', method: 'applyUp' });
const callGetLogin = rpc.declare({ object: 'tailscale', method: 'getLogin' });
const callLogout = rpc.declare({ object: 'tailscale', method: 'logout' });
const callReauth = rpc.declare({ object: 'tailscale', method: 'reauth', params: ['use_auth_key'] });
const callPingPeers = rpc.declare({ object: 'tailscale', method: 'pingPeers', params: ['max', 'timeout_s'] });
const callServiceAction = rpc.declare({ object: 'tailscale', method: 'serviceAction', params: ['action'] });
const callGetLogs = rpc.declare({ object: 'tailscale', method: 'getLogs', params: ['lines'] });
const callClearLogs = rpc.declare({ object: 'tailscale', method: 'clearLogs' });
const callRemoveCore = rpc.declare({ object: 'tailscale', method: 'removeCore' });
const callDiag = rpc.declare({ object: 'tailscale', method: 'diag' });

const STATUS_CACHE_KEY = 'tailscale-status-v2';
const STATUS_AUTH_KEY = 'tailscale-auth-v1';
const STATUS_CACHE_TTL = 10000;
const STATUS_POLL_INTERVAL = 1500;
let activeRoot = null, statusCache = null, statusCacheAt = 0, statusRequest = null, statusRequestFresh = false, statusTimer = null, statusTickTimer = null, statusPollRoot = null, badgeRestarting = false;
const statusSubscribers = [];
const ACTION_THEME_VARS = ['--text', '--muted', '--accent', '--accent-soft', '--edge', '--hi', '--glass', '--glass2', '--shadow'];
let actionObserver = null, actionFooter = null;
try {
	const saved = JSON.parse(window.sessionStorage.getItem(STATUS_CACHE_KEY) || 'null');
	if (saved && saved.status && Number.isFinite(+saved.at)) {
		statusCache = saved.status;
		statusCacheAt = +saved.at;
	}
}
catch (e) {}

function publishStatus(s) {
	const now = Date.now();
	s = Object.assign({}, s || {});
	if (s.running)
		s.uptime = Math.max(0, +s.uptime || 0);
	else
		s.uptime = 0;
	statusCache = s;
	const rawServerAge = Number(s.status_age_seconds);
	const serverAge = Number.isFinite(rawServerAge) && rawServerAge >= 0 ? rawServerAge : 0;
	statusCacheAt = Math.max(0, now - serverAge * 1000);
	try {
		window.sessionStorage.setItem(STATUS_CACHE_KEY, JSON.stringify({ at: statusCacheAt, status: statusCache }));
		if (s.logged_in)
			window.sessionStorage.setItem(STATUS_AUTH_KEY, JSON.stringify({ at: statusCacheAt, logged_in: true, tailnet: s.tailnet || '' }));
		else if (['NeedsLogin', 'NeedsMachineAuth', 'InUseOtherUser'].includes(s.backend_state))
			window.sessionStorage.removeItem(STATUS_AUTH_KEY);
	}
	catch (e) {}
	if (activeRoot && activeRoot.isConnected) {
		try { main.badges(activeRoot, statusCache, true); } catch (e) {}
	}
	const subscribers = statusSubscribers.slice();
	for (let i = 0; i < subscribers.length; i++) {
		try { subscribers[i](statusCache); } catch (e) {}
	}
}

function fetchStatus(force, forceBackend) {
	forceBackend = forceBackend === true;
	if (statusRequest) {
		if (forceBackend && !statusRequestFresh)
			return statusRequest.then(() => fetchStatus(true, true), () => fetchStatus(true, true));
		return statusRequest;
	}
	const age = Date.now() - statusCacheAt;
	if (!force && statusCache && age >= 0 && age < STATUS_CACHE_TTL)
		return Promise.resolve(statusCache);
	const request = callGetStatus(forceBackend ? '1' : '0').then((s) => {
		publishStatus(s);
		return statusCache;
	});
	statusRequestFresh = forceBackend;
	statusRequest = request.then((s) => {
		statusRequest = null;
		statusRequestFresh = false;
		return s;
	}, (e) => {
		statusRequest = null;
		statusRequestFresh = false;
		throw e;
	});
	return statusRequest;
}

function clearActionFooter() {
	if (!actionFooter)
		return;
	actionFooter.classList.remove('ts-luci-actions');
	for (let i = 0; i < ACTION_THEME_VARS.length; i++)
		actionFooter.style.removeProperty(ACTION_THEME_VARS[i]);
	actionFooter = null;
}

function stopActionObserver() {
	if (actionObserver) {
		actionObserver.disconnect();
		actionObserver = null;
	}
}

const api = baseclass.singleton({
	getStatus(force) { return fetchStatus(force === true, force === true); },
	getCachedStatus() {
		const age = Date.now() - statusCacheAt;
		return statusCache && age >= 0 && age < STATUS_CACHE_TTL ? statusCache : null;
	},
	getKnownAuth() {
		try {
			const saved = JSON.parse(window.sessionStorage.getItem(STATUS_AUTH_KEY) || 'null');
			const age = saved ? Date.now() - (+saved.at || 0) : -1;
			return saved && saved.logged_in && age >= 0 && age < 86400000 ? saved : null;
		}
		catch (e) {
			return null;
		}
	},
	clearKnownAuth() {
		try { window.sessionStorage.removeItem(STATUS_AUTH_KEY); } catch (e) {}
	},
	getStatusWithDerp() {
		return callGetStatusDerp('1').then((s) => {
			publishStatus(s);
			return statusCache;
		});
	},
	getConfig(s) { return callGetConfig(s); },
	setConfig(s, v, apply) { return callSetConfig(s, v, apply === true ? '1' : '0'); },
	getSources(proj, src) { return callGetSources(proj, src); },
	getVersionFiles(proj, src, version) { return callGetVersionFiles(proj, src, version); },
	refreshSources(src, proj) { return callRefreshSources(src, proj); },
	resolveFile(proj, src, ver, file, arch) { return callResolveFile(proj, src, ver, file, arch); },
	getFileSize(src, file) { return callGetFileSize(src, file); },
	download(proj, src, ver, file, arch) { return callDownload(proj, src, ver, file, arch); },
	progress(id) { return callProgress(id); },
	cancelTask(id) { return callCancelTask(id); },
	beginManualUpload(name, size) { return callBeginManualUpload(name, size); },
	finishManualUpload(id) { return callFinishManualUpload(id); },
	applyNetwork(token) { return callApplyNetwork(token); },
	applyCron() { return callApplyCron(); },
	applyUp() { return callApplyUp(); },
	getLogin() { return callGetLogin(); },
	logout() { return callLogout(); },
	reauth(useAuthKey) { return callReauth(useAuthKey ? '1' : '0'); },
	pingPeers(max, tmo) { return callPingPeers(max, tmo); },
	service(action) { return callServiceAction(action); },
	getLogs(n) { return callGetLogs(n); },
	clearLogs() { return callClearLogs(); },
	removeCore() { return callRemoveCore(); },
	diag() { return callDiag(); }
});

const pageLang = (document.documentElement.getAttribute('lang') || '').toLowerCase();
if (pageLang)
	api.getConfig('update').then((r) => {
		if (r && r.config && r.config.lang !== pageLang) return api.setConfig('update', { lang: pageLang });
	}).catch(() => {});

const SVG_O = '<svg width="1em" height="1em" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">';

const ICONS = {
	logo: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.6 2.6L16 9.5"/>',
	dashboard: '<rect x="3" y="3" width="8" height="10" rx="1.5"/><rect x="13" y="3" width="8" height="6" rx="1.5"/><rect x="13" y="11" width="8" height="10" rx="1.5"/><rect x="3" y="15" width="8" height="6" rx="1.5"/>',
	qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM20 14v.01M14 20h.01M18 18h3v3h-3z"/>',
	settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.9 2.9l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.2a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.9-2.9l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.2a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.9-2.9l.1.1a1.7 1.7 0 0 0 1.9.3h0a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.2a1.7 1.7 0 0 0 1 1.5h0a1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.9 2.9l-.1.1a1.7 1.7 0 0 0-.3 1.9v0a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.2a1.7 1.7 0 0 0-1.4 1z"/>',
	network: '<circle cx="5" cy="12" r="2"/><circle cx="19" cy="6" r="2"/><circle cx="19" cy="18" r="2"/><path d="M6.7 11l10.6-4M6.7 13l10.6 4"/>',
	nodes: '<rect x="2" y="2" width="8" height="8" rx="1.5"/><rect x="14" y="2" width="8" height="8" rx="1.5"/><rect x="8" y="14" width="8" height="8" rx="1.5"/><path d="M6 10v2h4v2M18 10v2h-4v2"/>',
	download: '<path d="M12 3v12m0 0l-4.5-4.5M12 15l4.5-4.5M4 19h16"/>',
	doc: '<path d="M6 2h8l4 4v14a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1z"/><path d="M14 2v5h5M9 13h6M9 17h6"/>',
	sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
	moon: '<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z"/>',
	auto: '<rect x="3" y="6" width="18" height="12" rx="6"/><circle cx="9" cy="12" r="2.5"/><circle cx="15.5" cy="12" r="1" fill="currentColor"/>',
	check: '<path d="M4 12.5l5 5L20 6.5"/>',
	warn: '<path d="M12 3L2 20h20L12 3z"/><path d="M12 9.5V14M12 17v.01"/>',
	error: '<circle cx="12" cy="12" r="9"/><path d="M9 9l6 6M15 9l-6 6"/>',
	info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/>',
	refresh: '<path d="M20 12a8 8 0 1 1-2.3-5.6M20 3v4.5h-4.5"/>',
	power: '<path d="M12 3v8M6.3 6.5a8 8 0 1 0 11.4 0"/>',
	external: '<path d="M14 4h6v6M20 4L10 14M9 5H5a1 1 0 0 0-1 1v13a1 1 0 0 0 1 1h13a1 1 0 0 0 1-1v-4"/>',
	copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M5 15V5a1 1 0 0 1 1-1h10"/>',
	trash: '<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/>',
	shield: '<path d="M12 3l7.5 3v6c0 4.5-3.2 7.6-7.5 9-4.3-1.4-7.5-4.5-7.5-9V6L12 3z"/><path d="M9 12l2.2 2.2L15.5 10"/>',
	link: '<path d="M10 14a5 5 0 0 0 7.1 0l2.4-2.4a5 5 0 0 0-7.1-7.1L11 5.9M14 10a5 5 0 0 0-7.1 0L4.5 12.4a5 5 0 0 0 7.1 7.1L13 18.1"/>',
	unlink: '<path d="M9 15l-2 2a4 4 0 0 1-5.7-5.7l2-2M15 9l2-2a4 4 0 0 1 5.7 5.7l-2 2M4 4l16 16"/>',
	chevron: '<path d="M9 5l7 7-7 7"/>',
	palette: '<circle cx="12" cy="12" r="9"/><circle cx="9" cy="10" r="1" fill="currentColor"/><circle cx="14.5" cy="9.5" r="1" fill="currentColor"/><circle cx="15" cy="14.5" r="1" fill="currentColor"/><path d="M12 3a9 9 0 0 0 0 18c1.4 0 2-1 1.3-2-.6-1 0-2.3 1.4-2.3H17a4 4 0 0 0 4-4c0-5-4-9-9-9z"/>',
	x: '<path d="M6 6l12 12M18 6L6 18"/>',
	clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>'
};

const icons = baseclass.singleton({
	icon(k) {
		return '<span class="ic">' + SVG_O + (ICONS[k] || ICONS.info) + '</svg></span>';
	},
});

const THEME_KEY = 'ts-theme';
const THEME_SEQ = ['auto', 'light', 'dark'];

const theme = baseclass.singleton({
	get() {
		try {
			return localStorage.getItem(THEME_KEY) || 'auto';
		}
		catch (e) {
			return 'auto';
		}
	},
	name(t) {
		return t === 'light' ? _('Light') : t === 'dark' ? _('Dark') : _('Auto');
	},
	next(t) {
		const i = THEME_SEQ.indexOf(t);
		return THEME_SEQ[((i < 0 ? 0 : i) + 1) % THEME_SEQ.length];
	},
	apply(t, root) {
		const v = THEME_SEQ.indexOf(t) >= 0 ? t : 'auto';
		try {
			localStorage.setItem(THEME_KEY, v);
		}
		catch (e) {}
		const app = root || document.getElementById('app');
		if (app)
			app.setAttribute('data-theme', v);
		return v;
	}
});

const PAGES = [
	['overview', 'dashboard', 'Overview'],
	['nodes', 'nodes', 'Nodes'],
	['settings', 'settings', 'Settings'],
	['network', 'network', 'Network'],
	['update', 'download', 'Core'],
	['logs', 'doc', 'Logs']
];

let toastT = null;

const main = baseclass.singleton({
	esc(s) {
		return ('' + (s == null ? '' : s)).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
	},
	stageUci(sections) {
		let task = Promise.resolve();
		for (let i = 0; i < sections.length; i++) {
			const section = sections[i][0], values = sections[i][1];
			task = task.then(() => uci.callSet('tailscale', section, values));
		}
		return task.then(() => ui.changes.init());
	},
	applyUci(mode) {
		return ui.changes.apply(mode == '0');
	},
	fmtBytes(n) {
		n = +n || 0;
		if (n >= 1073741824)
			return (n / 1073741824).toFixed(1) + ' GB';
		if (n >= 1048576)
			return (n / 1048576).toFixed(1) + ' MB';
		if (n >= 1024)
			return (n / 1024).toFixed(1) + ' KB';
		return n + ' B';
	},
	fmtRate(kb) {
		kb = +kb || 0;
		return kb > 1024 ? (kb / 1024).toFixed(1) + ' MB/s' : Math.round(kb) + ' KB/s';
	},
	fmtDur(sec) {
		sec = Math.max(0, Math.floor(+sec || 0));
		const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
		const hm = (h < 10 ? '0' + h : h) + ':' + (m < 10 ? '0' + m : m);
		return d > 0 ? d + ' ' + _('days') + ' ' + hm : hm;
	},
	fmtClock(sec) {
		sec = Math.max(0, Math.floor(+sec || 0));
		const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
		const pad = (n) => n < 10 ? '0' + n : '' + n;
		const clock = pad(h) + ':' + pad(m) + ':' + pad(s);
		const days = d === 1 ? _('1 day') : _('%d days').replace('%d', '' + d);
		return d > 0 ? days + ' ' + clock : clock;
	},
	ensureViewport() {
		let m = document.querySelector('meta[name="viewport"]');
		if (!m) {
			m = document.createElement('meta');
			m.name = 'viewport';
			document.head.appendChild(m);
		}
		m.content = 'width=device-width, initial-scale=1, user-scalable=yes';
	},
	ensureCss() {
		this.ensureViewport();
		if (document.getElementById('ts-css'))
			return;
		const l = document.createElement('link');
		l.id = 'ts-css';
		l.rel = 'stylesheet';
		l.href = L.resource('tailscale/style.css') + '?v=' + ASSET_VERSION;
		document.head.appendChild(l);
	},
	shell(active, body) {
		this.ensureCss();
		const t = theme.get();
		let dock = '';
		for (let i = 0; i < PAGES.length; i++) {
			const k = PAGES[i][0];
			dock += '<button type="button" class="' + (k === active ? 'active' : '') + '" data-go="' + L.url('admin/vpn/tailscale/' + k) + '">' + icons.icon(PAGES[i][1]) + ' <span>' + _(PAGES[i][2]) + '</span></button>';
		}
		return '<div id="app" data-theme="' + t + '"><div class="wrap">' +
			'<header class="topbar glass"><div class="logo">' + icons.icon('logo') + '</div>' +
			'<a class="title title-link" href="https://console.tailscale.com/admin/machines" target="_blank" rel="noopener noreferrer">Tailscale</a>' +
			'<span class="badge" id="tsVer">—</span>' +
			'<span class="badge err" id="svcBadge"><span class="dot off" id="svcDot"></span><span id="svcTxt">…</span></span>' +
			'<div class="spacer"></div>' +
			'<button type="button" class="btn sm" id="themeBtn">' + icons.icon(t === 'light' ? 'sun' : t === 'dark' ? 'moon' : 'auto') + ' <span id="themeLabel">' + theme.name(t) + '</span></button></header>' +
			'<main>' + body + '</main></div><nav class="dock glass">' + dock + '</nav>' +
			'<div class="overlay" id="loginOverlay"><div class="sheet glass">' +
			'<div class="sheet-head"><h3>' + icons.icon('qr') + ' ' + _('Login to Tailscale') + '</h3><div class="spacer"></div>' +
			'<button type="button" class="btn sm icon-only" id="loginClose" aria-label="' + _('Close') + '">' + icons.icon('x') + '</button></div>' +
			'<div class="stat-s">' + _('Scan, jump, or AuthKey') + '</div>' +
			'<div id="seg-logged"><table class="tbl" id="loginTbl"></table>' +
			'<div class="btnrow"><button type="button" class="btn sm" id="reauthBtn">' + icons.icon('refresh') + ' <span>' + _('Re-authenticate') + '</span></button>' +
			'<button type="button" class="btn sm danger" id="logoutBtn">' + icons.icon('x') + ' <span>' + _('Log out') + '</span></button></div></div>' +
			'<div id="seg-unlogged" style="display:none">' +
			'<div class="field"><label>' + _('Login URL') + '</label><div class="login-url"><input id="loginUrl" readonly>' +
			'<button type="button" class="btn sm" id="copyUrlBtn" style="display:none">' + icons.icon('copy') + ' <span>' + _('Copy') + '</span></button>' +
			'<button type="button" class="btn sm primary" id="openUrlBtn" style="display:none">' + icons.icon('external') + ' <span>' + _('Open') + '</span></button></div></div>' +
			'<div class="run-transition" id="loginUrlWait"><span class="spinner"></span><span id="loginUrlWaitText">' + _('Getting login URL') + '</span></div>' +
			'<div class="qr-center" id="qrCenter" style="display:none"><span class="qr-paper"><span id="qrBox"></span></span>' +
			'<div class="stat-s">' + _('Scan to login') + '</div></div>' +
			'<form id="authForm" autocomplete="off" novalidate><div class="field"><label>' + _('Or use AuthKey for one-click login') + '</label><div class="login-url">' +
			'<input type="password" id="authKey" name="auth_key" autocomplete="off" placeholder="tskey-auth-…">' +
			'<button type="submit" class="btn sm primary" id="authGo">' + icons.icon('check') + ' <span>' + _('Login') + '</span></button></div></div></form>' +
			'</div></div></div>' +
			'<div class="overlay" id="confirmOverlay"><div class="sheet glass confirm-sheet">' +
			'<h3 id="cfTitle"></h3><div class="stat-s" id="cfText"></div>' +
			'<div class="btnrow confirm-actions"><button type="button" class="btn" id="cfCancel">' + _('Cancel') + '</button>' +
			'<button type="button" class="btn danger" id="cfOk"></button></div></div></div>' +
			'<div id="toast"></div></div>';
	},
	styleActions(active, root) {
		stopActionObserver();
		clearActionFooter();
		if (active !== 'settings' && active !== 'network' && active !== 'update' && active !== 'nodes')
			return;
		const sync = () => {
			if (!root || !root.isConnected) {
				stopActionObserver();
				clearActionFooter();
				return;
			}
			const view = document.getElementById('view');
			const main = root.querySelector('.wrap main');
			const footer = (view && view.querySelector('.cbi-page-actions')) || document.querySelector('.cbi-page-actions');
			if (footer && main && !root.contains(footer))
				main.insertAdjacentElement('afterend', footer);
			if (footer !== actionFooter) {
				clearActionFooter();
				actionFooter = footer;
			}
			if (!actionFooter)
				return;
			actionFooter.classList.add('ts-luci-actions');
			this.syncActionTheme(root);
		};
		sync();
		const css = document.getElementById('ts-css');
		if (css && css.addEventListener)
			css.addEventListener('load', sync, { once: true });
		if (root && root.isConnected && document.body && typeof MutationObserver !== 'undefined') {
			actionObserver = new MutationObserver(sync);
			actionObserver.observe(document.body, { childList: true, subtree: true });
		}
	},
	syncActionTheme(root) {
		if (!actionFooter || !root)
			return;
		const style = window.getComputedStyle(root);
		for (let i = 0; i < ACTION_THEME_VARS.length; i++) {
			const name = ACTION_THEME_VARS[i], value = style.getPropertyValue(name).trim();
			if (value)
				actionFooter.style.setProperty(name, value);
			else
				actionFooter.style.removeProperty(name);
		}
	},
	wire(active, root, status, deferStatus) {
		root = root || document.getElementById('app');
		if (!root)
			return;
		activeRoot = root;
		this.ensureCss();
		theme.apply(theme.get(), root);
		this.styleActions(active, root);
		const tb = root.querySelector('#themeBtn');
		tb.addEventListener('click', () => {
			const v = theme.apply(theme.next(theme.get()), root);
			this.syncActionTheme(root);
			root.querySelector('#themeLabel').textContent = theme.name(v);
			const old = tb.querySelector('.ic');
			if (old)
				old.remove();
			tb.insertAdjacentHTML('afterbegin', icons.icon(v === 'light' ? 'sun' : v === 'dark' ? 'moon' : 'auto') + ' ');
		});
		const ds = root.querySelectorAll('.dock button');
		for (let i = 0; i < ds.length; i++)
			ds[i].addEventListener('click', () => { location.href = ds[i].getAttribute('data-go'); });
		this.startStatusPolling(root);
		if (deferStatus !== true) this.badges(root, status);
	},

	startStatusPolling(root) {
		if (statusTimer)
			clearInterval(statusTimer);
		if (statusTickTimer)
			clearInterval(statusTickTimer);
		statusPollRoot = root || activeRoot;
		const stop = () => {
			if (statusTimer)
				clearInterval(statusTimer);
			if (statusTickTimer)
				clearInterval(statusTickTimer);
			statusTimer = null;
			statusTickTimer = null;
			statusPollRoot = null;
		};
		statusTimer = setInterval(() => {
			if (!statusPollRoot || !statusPollRoot.isConnected) {
				stop();
				return;
			}
			fetchStatus(true, false).catch(() => {});
		}, STATUS_POLL_INTERVAL);
		statusTickTimer = setInterval(() => {
			if (!statusPollRoot || !statusPollRoot.isConnected) {
				stop();
				return;
			}
			const age = Date.now() - statusCacheAt;
			if (statusCache && age >= 0 && age < STATUS_CACHE_TTL) {
				const s = Object.assign({}, statusCache, { uptime: (+statusCache.uptime || 0) + Math.floor(age / 1000) });
				this.badges(statusPollRoot, s, true);
			}
		}, 1000);
	},
	onStatus(callback) {
		if (typeof callback !== 'function')
			return () => {};
		statusSubscribers.push(callback);
		return () => {
			const i = statusSubscribers.indexOf(callback);
			if (i >= 0)
				statusSubscribers.splice(i, 1);
		};
	},
	badges(root, status, sharedUpdate) {
		root = root || activeRoot || document;
		if (status != null && !sharedUpdate)
			badgeRestarting = !!status.restarting;
		const apply = (s) => {
			s = s || {};
			if (sharedUpdate && badgeRestarting)
				s = Object.assign({}, s, { restarting: true });
			if (s.running && statusCache && statusCache.running) {
				const age = Date.now() - statusCacheAt;
				const baseUptime = statusCache.status_age_seconds != null ? (+statusCache.uptime || 0) : (+s.uptime || 0);
				if (age >= 0)
					s = Object.assign({}, s, { uptime: baseUptime + Math.floor(age / 1000) });
			}
			const ver = root.querySelector('#tsVer'), badge = root.querySelector('#svcBadge'), dot = root.querySelector('#svcDot'), txt = root.querySelector('#svcTxt');
			if (!ver || !badge || !dot || !txt)
				return;
			if (s.version != null)
				ver.textContent = s.version ? 'v' + ('' + s.version).split(/[ \n]/)[0] : '—';
			if (s.restarting) {
				badge.className = 'badge warn';
				dot.className = 'dot warn';
				txt.textContent = _('Restarting');
				return;
			}
			const run = !!s.running;
			badge.className = 'badge ' + (run ? 'ok' : 'err');
			dot.className = 'dot' + (run ? '' : ' off');
			txt.textContent = run ? _('Running') + ' ' + this.fmtClock(s.uptime) : _('Not running');
		};
		if (status != null) {
			apply(status);
			return;
		}
		api.getStatus().then((s) => this.badges(root, s, true)).catch(() => {
			const badge = root.querySelector('#svcBadge'), dot = root.querySelector('#svcDot'), txt = root.querySelector('#svcTxt');
			if (badge) badge.className = badgeRestarting ? 'badge warn' : 'badge err';
			if (dot) dot.className = badgeRestarting ? 'dot warn' : 'dot off';
			if (txt) txt.textContent = badgeRestarting ? _('Restarting') : _('Not running');
		});
	},
	toast(msg) {
		const root = activeRoot || document;
		const el = root.querySelector('#toast');
		if (!el)
			return;
		el.textContent = msg;
		el.classList.add('show');
		if (toastT)
			clearTimeout(toastT);
		toastT = setTimeout(() => el.classList.remove('show'), 1800);
	},
	openConfirm(title, text, okText, cb) {
		const root = activeRoot || document;
		const q = (id) => root.querySelector(id);
		q('#cfTitle').textContent = title;
		q('#cfText').textContent = text;
		q('#cfOk').textContent = okText;
		const cf = q('#confirmOverlay'), ok = q('#cfOk'), cancel = q('#cfCancel');
		const done = (run) => {
			ok.onclick = null;
			cancel.onclick = null;
			cf.classList.remove('open');
			if (run)
				cb();
		};
		ok.onclick = () => done(true);
		cancel.onclick = () => done(false);
		cf.onclick = (e) => { if (e.target === cf) done(false); };
		cf.classList.add('open');
	},
	copy(text, okMsg) {
		const done = () => this.toast(okMsg || _('Copied'));
		if (navigator.clipboard && window.isSecureContext) {
			navigator.clipboard.writeText(text).then(done).catch(() => this.legacyCopy(text, done));
			return;
		}
		this.legacyCopy(text, done);
	},
	legacyCopy(text, done) {
		const ta = document.createElement('textarea');
		ta.value = text;
		ta.style.position = 'fixed';
		ta.style.opacity = '0';
		document.body.appendChild(ta);
		ta.select();
		try {
			document.execCommand('copy');
		}
		catch (e) {}
		document.body.removeChild(ta);
		done();
	}
});

let qrReady = null;
let appRoot = null;
let loginUrlBusy = false;
let loginUrlTimer = null;
let loginPollActive = false;

const login = baseclass.singleton({
	q(id) {
		return appRoot ? appRoot.querySelector(id) : null;
	},
	expiryFmt(s) {
		s = '' + (s || '');
		if (s === '' || s.indexOf('0001') === 0)
			return _('Never expires');
		return s.replace('T', ' ').split('.')[0].split('+')[0];
	},
	ensureQr() {
		if (window.QRCode)
			return Promise.resolve(true);
		if (qrReady)
			return qrReady;
		qrReady = new Promise((resolve) => {
			const sc = document.createElement('script');
			sc.src = L.resource('tailscale/vendor/qrcode.js') + '?v=' + ASSET_VERSION;
			sc.onload = () => resolve(true);
			sc.onerror = () => resolve(false);
			document.head.appendChild(sc);
		});
		return qrReady;
	},
	renderQr(url) {
		const box = this.q('#qrBox');
		if (!box)
			return;
		box.innerHTML = '';
		this.ensureQr().then((ok) => {
			if (!box.isConnected)
				return;
			if (ok && window.QRCode) {
				try {
					new QRCode(box, { text: url, width: 200, height: 200 });
					return;
				}
				catch (e) {}
			}
			box.textContent = url;
		});
	},
	showLogged(s) {
		if (loginUrlTimer) {
			clearTimeout(loginUrlTimer);
			loginUrlTimer = null;
		}
		const ips = (s.tail_ips || []).join(', ');
		this.q('#loginTbl').innerHTML =
			'<tr><th>' + _('Tailnet') + '</th><td>' + main.esc(s.tailnet || '—') + '</td></tr>' +
			'<tr><th>' + _('Hostname') + '</th><td>' + main.esc(s.hostname || '—') + '</td></tr>' +
			'<tr><th>' + _('Tail IPs') + '</th><td>' + main.esc(ips || '—') + '</td></tr>' +
			'<tr><th>' + _('Key expiry') + '</th><td>' + main.esc(this.expiryFmt(s.key_expiry)) + '</td></tr>';
		this.q('#seg-logged').style.display = '';
		this.q('#seg-unlogged').style.display = 'none';
		this.q('#loginOverlay').classList.add('open');
	},
	showUnlogged(url) {
		const hasUrl = !!url;
		this.q('#loginUrl').value = url || '';
		this.q('#authKey').value = '';
		this.q('#copyUrlBtn').style.display = hasUrl ? '' : 'none';
		this.q('#openUrlBtn').style.display = hasUrl ? '' : 'none';
		this.q('#qrCenter').style.display = hasUrl ? '' : 'none';
		this.q('#loginUrlWait').classList.remove('show', 'breathing');
		this.q('#loginUrlWait').querySelector('.spinner').style.display = '';
		this.q('#loginUrlWaitText').textContent = _('Getting login URL');
		if (hasUrl)
			this.renderQr(url);
		else
			this.q('#qrBox').innerHTML = '';
		this.q('#seg-logged').style.display = 'none';
		this.q('#seg-unlogged').style.display = '';
		this.q('#loginOverlay').classList.add('open');
	},
	getLoginUrl(retries, waitForLogout) {
		if (loginUrlBusy)
			return Promise.resolve();
		retries = retries == null ? 80 : retries;
		loginUrlBusy = true;
		const overlay = this.q('#loginOverlay'), wait = this.q('#loginUrlWait'), label = this.q('#loginUrlWaitText');
		wait.classList.add('show', 'breathing');
		wait.querySelector('.spinner').style.display = '';
		label.textContent = _('Getting login URL');
		overlay.classList.add('login-busy');
		let retry = false;
		const fail = () => {
			label.textContent = _('Failed to get login URL');
			wait.querySelector('.spinner').style.display = 'none';
			wait.classList.remove('breathing');
		};
		return api.getLogin().then((o) => {
			o = o || {};
			if (o.ok && o.url) {
				this.showUnlogged(o.url);
				this.pollLogin(200, waitForLogout);
				return;
			}
			if (o.ok && o.pending) {
				retry = true;
				label.textContent = _('Getting login URL');
				this.pollLogin(200, waitForLogout);
				return;
			}
			if (o.ok) {
				return api.getStatus(true).then((s) => {
					if (s && s.logged_in) {
						this.showLogged(s);
						return;
					}
					retry = true;
					this.pollLogin(200, waitForLogout);
				});
			}
			fail();
		}).catch(() => {
			retry = retries > 0;
			if (!retry)
				fail();
		}).then(() => {
			loginUrlBusy = false;
			overlay.classList.remove('login-busy');
			if (retry && this.q('#seg-logged').style.display === 'none') {
				if (retries > 0) {
					if (loginUrlTimer)
						clearTimeout(loginUrlTimer);
					loginUrlTimer = setTimeout(() => {
						loginUrlTimer = null;
						this.getLoginUrl(retries - 1, waitForLogout);
					}, 1500);
				}
				else {
					fail();
				}
			}
		});
	},
	open(status) {
		const request = status == null ? api.getStatus() : Promise.resolve(status);
		return request.then((s) => {
			s = s || {};
			if (!s.running) {
				main.toast(_('Service is stopped, please start it first'));
				return;
			}
			if (s.logged_in) {
				this.showLogged(s);
				return;
			}
			this.showUnlogged('');
			return this.getLoginUrl();
		}).catch(() => main.toast(_('Failed to get status')));
	},
	pollLogin(n, waitForLogout) {
		if (loginPollActive)
			return;
		loginPollActive = true;
		let sawLoggedOut = !waitForLogout;
		const poll = (left) => {
			if (!loginPollActive)
				return;
			if (left <= 0) {
				loginPollActive = false;
				const button = this.q('#authGo');
				if (button) button.disabled = false;
				const wait = this.q('#loginUrlWait');
				if (wait && wait.classList.contains('show')) {
					wait.classList.remove('breathing');
					wait.querySelector('.spinner').style.display = 'none';
					this.q('#loginUrlWaitText').textContent = _('Login timed out, please check the status');
				}
				main.toast(_('Login timed out, please check the status'));
				return;
			}
			let active = true, timer = null, unsubscribe = () => {};
			unsubscribe = main.onStatus((s) => {
				if (!active || !s)
					return;
				if (!s.logged_in) {
					sawLoggedOut = true;
					return;
				}
				if (!sawLoggedOut)
					return;
				active = false;
				loginPollActive = false;
				clearTimeout(timer);
				unsubscribe();
				const button = this.q('#authGo');
				if (button) button.disabled = false;
				main.toast(_('Login successful'));
				const overlay = this.q('#loginOverlay');
				if (overlay && overlay.classList.contains('open'))
					this.showLogged(s);
			});
			timer = setTimeout(() => {
				if (!active)
					return;
				active = false;
				unsubscribe();
				poll(left - 1);
			}, STATUS_POLL_INTERVAL);
		};
		poll(n);
	},
	init(root) {
		appRoot = root || document.getElementById('app');
		if (!appRoot)
			return;
		const ov = this.q('#loginOverlay');
		this.q('#loginClose').addEventListener('click', () => ov.classList.remove('open'));
		ov.addEventListener('click', (e) => { if (e.target === ov) ov.classList.remove('open'); });
		this.q('#copyUrlBtn').addEventListener('click', () => main.copy(this.q('#loginUrl').value));
		this.q('#openUrlBtn').addEventListener('click', () => window.open(this.q('#loginUrl').value, '_blank'));
		this.q('#logoutBtn').addEventListener('click', () => {
			ov.classList.remove('open');
			main.openConfirm(_('Confirm logout?'), _('This host will leave the tailnet and need a new login.'), _('Log out'), () => {
				api.logout().then((o) => {
					if (o && o.ok)
						api.clearKnownAuth();
					main.toast(o && o.ok ? _('Logged out') : _('Logout failed'));
					setTimeout(() => location.reload(), 900);
				}).catch(() => main.toast(_('Logout failed')));
			});
		});
		this.q('#reauthBtn').addEventListener('click', () => {
			api.reauth(false).then((o) => {
				o = o || {};
				if (o.url) {
					this.showUnlogged(o.url);
					this.pollLogin(200, true);
					return;
				}
				if (o.ok === false) {
					main.toast(_('Re-auth failed'));
					return;
				}
				if (o.pending || o.ok) {
					this.showUnlogged('');
					this.getLoginUrl(undefined, true);
					return;
				}
				main.toast(_('Re-auth failed'));
			}).catch(() => main.toast(_('Re-auth failed')));
		});
		this.q('#authForm').addEventListener('submit', (e) => {
			e.preventDefault();
			const k = this.q('#authKey').value.trim();
			const button = this.q('#authGo');
			if (!k) {
				main.toast(_('Please enter an AuthKey'));
				return;
			}
			button.disabled = true;
			api.setConfig('up', { auth_key: k }).then((o) => {
				if (!o || o.ok === false) {
					button.disabled = false;
					main.toast(_('Failed to save AuthKey'));
					return;
				}
				return api.reauth(true).then((r) => {
					r = r || {};
					if (r.ok === false) {
						button.disabled = false;
						main.toast(_('Re-auth failed'));
						return;
					}
					if (r.url)
						this.showUnlogged(r.url);
					const wait = this.q('#loginUrlWait');
					wait.classList.add('show', 'breathing');
					wait.querySelector('.spinner').style.display = '';
					this.q('#loginUrlWaitText').textContent = _('Logging in, please wait');
					main.toast(_('Logging in, please wait'));
					this.pollLogin(200);
				}).catch(() => {
					button.disabled = false;
					main.toast(_('Re-auth failed'));
				});
			}).catch(() => {
				button.disabled = false;
				main.toast(_('Failed to save AuthKey'));
			});
		});
	}
});

return baseclass.extend({
	api: api,
	icons: icons,
	login: login,
	main: main,
	theme: theme
});
