'use strict';
'require view';
'require tailscale.common as common';

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
	load() {
		return Promise.resolve(common.api.getCachedStatus() || {});
	},
	latMs(s, ip) {
		const dm = s.derp_ms || {};
		if (dm[ip] && dm[ip].ms != null)
			return dm[ip].ms;
		return -2;
	},
	derpText(s) {
		const dm = s.derp_ms || {};
		for (const k in dm) {
			if (dm[k] && dm[k].via && dm[k].via !== 'direct')
				return dm[k].ms + 'ms';
		}
		return '—';
	},
	onlineCount(s) {
		let n = 0;
		for (const p of (s.peers || []))
			if (p.online)
				n++;
		return n;
	},
	topoSvg(s) {
		const self = { name: s.hostname || _('This host'), ms: -2, on: true, me: true };
		const rest = [];
		for (const p of (s.peers || []).slice(0, 7))
			rest.push({ name: p.name || p.ip, ms: p.online ? this.latMs(s, p.ip) : -1, on: !!p.online });
		const all = [self].concat(rest);
		const shortLabel = (value) => {
			const text = '' + (value || '');
			return text.length > 14 ? text.slice(0, 13) + '…' : text;
		};
		const cx = 300, cy = 140, rx = 225, ry = 100;
		let h = '';
		for (let i = 1; i < all.length; i++) {
			const a = -Math.PI / 2 + (i / all.length) * Math.PI * 2;
			const x = (cx + rx * Math.cos(a)).toFixed(0), y = (cy + ry * Math.sin(a)).toFixed(0);
			const ms = all[i].ms;
			const cls = ms === -1 ? ' off' : ms === -2 ? '' : ms <= 100 ? '' : ms <= 250 ? ' warn' : ' err';
			h += '<line class="tlink' + cls + '" x1="' + cx + '" y1="' + cy + '" x2="' + x + '" y2="' + y + '"/>';
		}
		h += '<circle class="me-pulse" cx="' + cx + '" cy="' + cy + '" r="39"><animate attributeName="r" values="36;52" dur="2.2s" repeatCount="indefinite"/></circle>';
		h += '<circle class="tnode me" cx="' + cx + '" cy="' + cy + '" r="35"><title>' + common.main.esc(self.name) + '</title></circle><text class="ttxt" x="' + cx + '" y="' + (cy - 1) + '">' + common.main.esc(shortLabel(self.name)) + '</text><text class="tsub" x="' + cx + '" y="' + (cy + 17) + '">' + _('This host') + '</text>';
		for (let i = 1; i < all.length; i++) {
			const a = -Math.PI / 2 + (i / all.length) * Math.PI * 2;
			const x = (cx + rx * Math.cos(a)).toFixed(0), y = (cy + ry * Math.sin(a)).toFixed(0);
			const sub = !all[i].on ? _('Offline') : all[i].ms === -2 ? _('Online') : all[i].ms + 'ms';
			h += '<circle class="tnode' + (all[i].on ? ' on' : '') + '" cx="' + x + '" cy="' + y + '" r="31"><title>' + common.main.esc(all[i].name) + '</title></circle>';
			h += '<text class="ttxt" x="' + x + '" y="' + (+y - 1) + '">' + common.main.esc(shortLabel(all[i].name)) + '</text>';
			h += '<text class="tsub" x="' + x + '" y="' + (+y + 17) + '">' + common.main.esc(sub) + '</text>';
		}
		return h;
	},

	trafficPath(a, max) {
		let d = '';
		for (let j = 0; j < a.length; j++) {
			const x = (j / (a.length - 1)) * 600, y = 155 - (a[j] / max) * 145;
			d += (j ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1);
		}
		return d;
	},
	render(s) {
		s = s || {};
		const hasInitialStatus = Object.keys(s).length > 0;
		const ips = s.tail_ips || [];
		const initialRun = !hasInitialStatus ? '—' : !s.running ? _('Not running') : s.logged_in ? _('Logged in') : ['Starting', 'NoState'].includes(s.backend_state) ? _('Reconnecting') : _('Not logged in');
		const ring = (id, color, label) => '<div class="ring-box" id="' + id + 'RingBox"><svg width="148" height="148" viewBox="0 0 120 120" class="ring"><circle cx="60" cy="60" r="52" class="ring-bg"/>' +
			'<circle id="' + id + 'Ring" cx="60" cy="60" r="52" class="ring-fg" stroke="' + color + '"/><text x="60" y="56" id="' + id + 'Pct">—</text>' +
			'<text x="60" y="74" class="ring-lab">' + label + '</text><text x="60" y="91" class="ring-sub" id="' + id + 'Abs">—</text></svg></div>';
		const body =
			'<div class="grid" style="gap:14px">' +
			'<div class="card glass core-banner" id="coreBanner" style="display:' + (hasInitialStatus && !s.binary_ok ? '' : 'none') + '"><b>' + common.icons.icon('warn') + ' ' + _('Core missing') + '</b><button type="button" class="btn sm" id="coreInstall">' + _('Click to install core') + '</button></div>' +
			'<div class="grid g4">' +
			'<div class="card glass login-status-card"><div class="login-status-header"><h3>' + _('Login status') + '</h3><div class="stat-v" id="runState">● ' + common.main.esc(initialRun) + '</div></div>' +
			'<div class="login-status-controls"><button type="button" class="run-power-button breathing' + (s.enabled ? ' is-enabled' : ' is-disabled') + '" id="runToggle" title="' + _('Enable or disable Tailscale') + '" aria-label="' + _('Enable or disable Tailscale') + '" aria-pressed="' + (s.enabled ? 'true' : 'false') + '"' + (hasInitialStatus && s.binary_ok ? '' : ' disabled') + '><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 2.5v9"/><path d="M7 5.6a8 8 0 1 0 10 0" stroke-width="3.2"/></svg></button>' +
			'<button type="button" class="iconbtn restart-iconbtn" id="restartBtn" title="' + _('Restart Tailscale service') + '"' + (hasInitialStatus && s.binary_ok ? '' : ' disabled') + '>' + common.icons.icon('refresh') + '</button></div>' +
			'<div class="stat-s" id="runSub"></div><div class="run-transition" id="runTransition"><span class="spinner"></span><span id="transitionText"></span></div></div>' +
			'<div class="card glass" id="verCard"><h3>' + common.icons.icon('download') + ' ' + _('Core version') + '</h3>' +
			'<div class="stat-v" id="verNum">' + common.main.esc(s.version ? ('' + s.version).split(/[ \n]/)[0] : '—') + '</div>' +
			'<div class="stat-s">' + _('Click to manage core') + '</div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('link') + ' ' + _('Tail IP') + '</h3>' +
			'<div class="stat-v" id="ipNum">' + common.main.esc(ips[0] || '—') + '</div>' +
			'<div class="stat-s" id="hostIpSub"><span id="hostName">' + common.main.esc(s.hostname || '') + '</span><span id="copyIpSep" style="display:' + (ips[0] ? '' : 'none') + '"> · </span><a href="#" id="copyIp" style="display:' + (ips[0] ? '' : 'none') + '">' + _('Copy') + '</a></div></div>' +
			'<div class="card glass" id="tailCard"><h3>' + common.icons.icon('network') + ' ' + _('Tailnet') + '</h3>' +
			'<div id="tailOn" style="display:' + (hasInitialStatus && s.logged_in ? '' : 'none') + '"><div class="stat-v" id="tailName">' + common.main.esc(s.tailnet || '—') + '</div>' +
			'<div class="stat-s" id="tailSub"></div></div>' +
			'<div id="tailOff" style="display:' + (hasInitialStatus && !s.logged_in ? '' : 'none') + '"><div class="stat-v tail-off">' + _('Not logged in') + '</div>' +
			'<div class="stat-s">' + _('Click to login') + '</div></div></div></div>' +
			'<div class="grid g2 traffic-row">' +
			'<div class="card glass live-traffic-card"><h3>' + common.icons.icon('network') + ' ' + _('Live traffic') + '</h3><div class="traffic-gauges">' +
			'<div class="traffic-gauge" id="liveGaugeDown" style="--gauge-rgb:76,194,255;--pulse-duration:2.8s" role="group" aria-label="' + _('Download') + '"><div class="traffic-gauge-dial"><span class="traffic-pulse-wave wave-one"></span><span class="traffic-pulse-wave wave-two"></span><span class="traffic-pulse-wave wave-three"></span><div class="traffic-gauge-core"><b class="traffic-gauge-number" id="rateDown">0.0</b><span class="traffic-gauge-unit" id="rateDownUnit">KB/s</span></div></div><div class="traffic-gauge-label"><i class="swd" style="background:#4cc2ff"></i>' + _('Download') + '</div></div>' +
			'<div class="traffic-gauge" id="liveGaugeUp" style="--gauge-rgb:123,97,255;--pulse-duration:2.8s" role="group" aria-label="' + _('Upload') + '"><div class="traffic-gauge-dial"><span class="traffic-pulse-wave wave-one"></span><span class="traffic-pulse-wave wave-two"></span><span class="traffic-pulse-wave wave-three"></span><div class="traffic-gauge-core"><b class="traffic-gauge-number" id="rateUp">0.0</b><span class="traffic-gauge-unit" id="rateUpUnit">KB/s</span></div></div><div class="traffic-gauge-label"><i class="swd" style="background:#7b61ff"></i>' + _('Upload') + '</div></div>' +
			'</div></div>' +
			'<div class="card glass total-traffic-card" id="totalTrafficCard"><h3>' + common.icons.icon('network') + ' ' + _('Total traffic') + '</h3>' +
			'<div class="tlegend traffic-values total-traffic-values"><span><i class="swd" style="background:#4cc2ff"></i><span class="traffic-total-arrow" id="totalDownArrow">↓</span> <b id="totalDown">—</b></span>' +
			'<span><i class="swd" style="background:#7b61ff"></i><span class="traffic-total-arrow" id="totalUpArrow">↑</span> <b id="totalUp">—</b></span></div>' +
			'<svg id="totalTrafficChart" class="traffic-mini-chart" viewBox="0 0 600 160" preserveAspectRatio="none" aria-hidden="true"><g class="traffic-mini-grid"><line x1="0" y1="40" x2="600" y2="40"/><line x1="0" y1="80" x2="600" y2="80"/><line x1="0" y1="120" x2="600" y2="120"/></g>' +
			'<path id="totalDownLine" class="tline" stroke="#4cc2ff"/><path id="totalUpLine" class="tline" stroke="#7b61ff"/><circle id="totalDownHead" class="traffic-mini-head" r="4" fill="#4cc2ff"/><circle id="totalUpHead" class="traffic-mini-head" r="4" fill="#7b61ff"/></svg></div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('dashboard') + ' ' + _('Performance') + '</h3><div class="perf">' +
			ring('cpu', '#4cc2ff', _('Tailscale CPU')) + ring('mem', '#7b61ff', _('Tailscale memory')) +
			ring('install', '#34d399', _('Install filesystem')) + ring('tmp', '#f5a524', _('Temporary filesystem')) + '</div></div>' +
			'<div class="card glass topology-card"><div class="topology-header"><h3>' + common.icons.icon('network') + ' ' + _('Topology') + '</h3>' +
			'<div class="tlegend topology-legend">' +
			'<span><i class="swd" style="background:var(--ok)"></i>≤100ms</span>' +
			'<span><i class="swd" style="background:var(--warn)"></i>100–250ms</span>' +
			'<span><i class="swd" style="background:var(--err)"></i>&gt;250ms</span>' +
			'<span><i class="swd" style="background:var(--muted)"></i>' + _('Offline') + '</span></div></div>' +
			'<svg id="topo" width="600" height="280" viewBox="0 0 600 280">' + this.topoSvg(s) + '</svg>' +
			'<div class="stat-s legend-center" id="topoNote"></div></div></div>';
		const d = document.createElement('div');
		d.innerHTML = common.main.shell('overview', body);
		const root = d.querySelector('#app');
		const self = this;
		let busy = false, loginBusy = false, pendingEnabled = null, current = s, lastCpu = 0, prevCpuSample = null, prevRx = -1, prevTx = -1, prevSample = 0, smoothedDown = 0, smoothedUp = 0;
		const knownAuth = common.api.getKnownAuth() || {};
		let lastKnownLoggedIn = !!s.logged_in || !!knownAuth.logged_in, lastKnownTailnet = s.tailnet || knownAuth.tailnet || '', authGraceUntil = lastKnownLoggedIn ? Date.now() + 90000 : 0;
		let lifecycleTrace = null;
		const coreCount = (st) => {
			const n = Number(st.cpu_cores);
			return Number.isFinite(n) && n > 0 ? n : 1;
		};
		const cpuSample = (st) => {
			const pid = st.tailscale_pid == null ? '' : '' + st.tailscale_pid;
			const proc = Number(st.tailscale_proc_ticks);
			const total = Number(st.cpu_total_ticks);
			const cores = coreCount(st);
			return pid && Number.isFinite(proc) && Number.isFinite(total) && total > 0 ? { pid, proc, total, cores } : null;
		};
		const setRing = (id, frac, pct, abs, title) => {
			root.querySelector('#' + id + 'Ring').style.strokeDashoffset = (326.7 * (1 - Math.max(0, Math.min(1, frac)))).toFixed(1);
			root.querySelector('#' + id + 'Pct').textContent = pct;
			root.querySelector('#' + id + 'Abs').textContent = abs;
			root.querySelector('#' + id + 'RingBox').title = title || '';
		};
		const spaceRing = (id, space) => {
			const free = Number(space && space.free_bytes), total = Number(space && space.total_bytes);
			if (free >= 0 && total > 0)
				setRing(id, free / total, (free / total * 100).toFixed(1) + '%', common.main.fmtBytes(free), space.path);
			else
				setRing(id, 0, '—', _('Unavailable'), '');
		};
		if (s.running)
			prevCpuSample = cpuSample(s);
		const down = [], up = [];
		for (let i = 0; i < 60; i++) {
			down.push(0);
			up.push(0);
		}
		const paintPowerButton = (enabled, waiting) => {
			const button = root.querySelector('#runToggle');
			button.setAttribute('aria-pressed', enabled ? 'true' : 'false');
			button.classList.toggle('is-waiting', !!waiting);
			button.classList.toggle('is-enabled', !!enabled && !waiting);
			button.classList.toggle('is-disabled', !enabled && !waiting);
			button.classList.add('breathing');
		};
		const paintRun = (st) => {
			const el = root.querySelector('#runState'), sub = root.querySelector('#runSub'), toggle = root.querySelector('#runToggle'), restart = root.querySelector('#restartBtn');
			const loggedIn = !!st.display_logged_in, reconnecting = !!st.auth_reconnecting, running = !!st.running;
			el.textContent = '● ' + (!running ? _('Not running') : loggedIn ? _('Logged in') : reconnecting ? _('Reconnecting') : _('Not logged in'));
			el.style.color = !running ? 'var(--muted)' : loggedIn ? 'var(--ok)' : reconnecting ? 'var(--warn)' : 'var(--err)';
			sub.textContent = !st.binary_ok ? _('Core missing') : !running ? '' : reconnecting ? _('Waiting for Tailscale to reconnect') : loggedIn ? '' : _('Running but not logged in, click to login');
			paintPowerButton(pendingEnabled == null ? !!st.enabled : pendingEnabled, reconnecting);
			toggle.disabled = !st.binary_ok || busy;
			restart.disabled = !st.binary_ok || busy;
			const canLogin = !!st.binary_ok && !!st.running && !busy && !reconnecting;
			for (const target of [el, sub]) {
				target.style.cursor = canLogin ? 'pointer' : '';
				if (canLogin) {
					target.setAttribute('role', 'button');
					target.setAttribute('tabindex', '0');
				}
				else {
					target.removeAttribute('role');
					target.removeAttribute('tabindex');
				}
			}
		};
		const updateTrafficTotal = (selector, value) => {
			root.querySelector(selector).textContent = value;
		};
		const updateTrafficGauge = (gaugeSelector, numberSelector, unitSelector, rate, smoothedRate) => {
			const gauge = root.querySelector(gaugeSelector), number = root.querySelector(numberSelector), unit = root.querySelector(unitSelector);
			const parts = rate >= 1024 ? [(rate / 1024).toFixed(1), 'MB/s'] : [rate < 10 ? rate.toFixed(1) : '' + Math.round(rate), 'KB/s'];
			if (number.textContent !== parts[0] || unit.textContent !== parts[1]) {
				number.textContent = parts[0];
				unit.textContent = parts[1];
				number.classList.remove('traffic-gauge-number-pop');
				void number.offsetWidth;
				number.classList.add('traffic-gauge-number-pop');
			}
			const period = Math.max(.65, Math.min(2.8, 2.8 / (1 + Math.log1p(Math.max(0, smoothedRate)) / 2.2)));
			gauge.style.setProperty('--pulse-duration', period.toFixed(2) + 's');
		};
		const paintDyn = (st) => {
			const authRejected = ['NeedsLogin', 'NeedsMachineAuth', 'InUseOtherUser'].includes(st.backend_state);
			if (st.logged_in) {
				lastKnownLoggedIn = true;
				lastKnownTailnet = st.tailnet || lastKnownTailnet;
				authGraceUntil = 0;
			}
			else if (authRejected) {
				lastKnownLoggedIn = false;
				lastKnownTailnet = '';
				authGraceUntil = 0;
			}
			const reconnecting = !!st.running && !st.logged_in && !authRejected && (Date.now() < authGraceUntil || ['Starting', 'NoState'].includes(st.backend_state));
			current = Object.assign({}, st, { display_logged_in: !!st.logged_in || reconnecting && lastKnownLoggedIn, auth_reconnecting: reconnecting });
			root.querySelector('#coreBanner').style.display = st.binary_ok ? 'none' : '';
			root.querySelector('#verNum').textContent = st.version ? ('' + st.version).split(/[ \n]/)[0] : '—';
			if (!busy)
				paintRun(current);
			const ips = Array.isArray(st.tail_ips) ? st.tail_ips : [];
			const ip = ips[0] || '';
			root.querySelector('#ipNum').textContent = ip || '—';
			root.querySelector('#hostName').textContent = st.hostname || '';
			root.querySelector('#copyIpSep').style.display = ip ? '' : 'none';
			root.querySelector('#copyIp').style.display = ip ? '' : 'none';
			root.querySelector('#tailOn').style.display = current.display_logged_in ? '' : 'none';
			root.querySelector('#tailOff').style.display = current.display_logged_in ? 'none' : '';
			root.querySelector('#tailName').textContent = st.tailnet || (current.auth_reconnecting ? lastKnownTailnet : '') || '—';
			root.querySelector('#tailSub').textContent = current.auth_reconnecting ? _('Waiting for Tailscale to reconnect') : _('DERP latency') + ' ' + self.derpText(st) + ' · ' + self.onlineCount(st) + ' ' + _('online units');
			root.querySelector('#tailOff .stat-v').textContent = current.auth_reconnecting ? _('Reconnecting') : _('Not logged in');
			root.querySelector('#tailOff .stat-s').textContent = current.auth_reconnecting ? _('Waiting for Tailscale to reconnect') : _('Click to login');
			root.querySelector('#topo').innerHTML = self.topoSvg(st);
			const n = (st.peers || []).length;
			root.querySelector('#topoNote').textContent = n > 7 ? _('Showing 8 of N nodes, see Nodes page').replace('N', '' + (n + 1)) : _('All N nodes shown').replace('N', '' + (n + 1));
			const rx = +st.rx_bytes || 0, tx = +st.tx_bytes || 0, sampleAt = Date.now();
			const elapsed = prevSample ? Math.max(1, (sampleAt - prevSample) / 1000) : 2;
			let vd = 0, vu = 0;
			if (prevRx >= 0) {
				vd = Math.max(0, (rx - prevRx) / elapsed / 1024);
				vu = Math.max(0, (tx - prevTx) / elapsed / 1024);
			}
			prevRx = rx;
			prevTx = tx;
			prevSample = sampleAt;
			down.push(vd);
			down.shift();
			up.push(vu);
			up.shift();
			smoothedDown = smoothedDown * .68 + vd * .32;
			smoothedUp = smoothedUp * .68 + vu * .32;
			updateTrafficGauge('#liveGaugeDown', '#rateDown', '#rateDownUnit', vd, smoothedDown);
			updateTrafficGauge('#liveGaugeUp', '#rateUp', '#rateUpUnit', vu, smoothedUp);
			let max = 0;
			for (let i = 0; i < 60; i++)
				max = Math.max(max, down[i], up[i]);
			max = max * 1.15 || 1;
			const dD = self.trafficPath(down, max), dU = self.trafficPath(up, max);
			const totalDownLine = root.querySelector('#totalDownLine');
			const totalUpLine = root.querySelector('#totalUpLine');
			const totalDownHead = root.querySelector('#totalDownHead');
			const totalUpHead = root.querySelector('#totalUpHead');
			if (totalDownLine) totalDownLine.setAttribute('d', dD);
			if (totalUpLine) totalUpLine.setAttribute('d', dU);
			if (totalDownHead) {
				totalDownHead.setAttribute('cx', 600);
				totalDownHead.setAttribute('cy', 155 - (down[59] / max) * 145);
			}
			if (totalUpHead) {
				totalUpHead.setAttribute('cx', 600);
				totalUpHead.setAttribute('cy', 155 - (up[59] / max) * 145);
			}
			updateTrafficTotal('#totalDown', common.main.fmtBytes(rx));
			updateTrafficTotal('#totalUp', common.main.fmtBytes(tx));
			updateTrafficTotal('#totalDownArrow', '↓');
			updateTrafficTotal('#totalUpArrow', '↑');
			if (st.running) {
				const sample = cpuSample(st);
				if (sample) {
					if (prevCpuSample && sample.pid === prevCpuSample.pid) {
						if (sample.total > prevCpuSample.total && sample.proc >= prevCpuSample.proc) {
							const pct = Math.round((sample.proc - prevCpuSample.proc) * sample.cores * 1000 / (sample.total - prevCpuSample.total)) / 10;
							if (Number.isFinite(pct))
								lastCpu = Math.max(0, Math.min(100, pct));
						}
						else if (sample.total < prevCpuSample.total || sample.proc < prevCpuSample.proc) {
							lastCpu = 0;
						}
					}
					else {
						lastCpu = 0;
					}
					prevCpuSample = sample;
				}
				else {
					lastCpu = 0;
					prevCpuSample = null;
				}
			}
			else {
				lastCpu = 0;
				prevCpuSample = null;
			}
			setRing('cpu', lastCpu / 100, st.running ? lastCpu.toFixed(1) + '%' : '0%', _('%d cores').format(coreCount(st)));
			const mt = +st.mem_total || 0, rss = +st.tailscale_mem_kb || 0;
			if (mt > 0 && st.running)
				setRing('mem', rss / mt, (Math.max(0, rss / mt) * 100).toFixed(1) + '%', common.main.fmtBytes(rss * 1024));
			else
				setRing('mem', 0, st.running ? '—' : '0%', st.running ? '—' : '0 B');
			const spaces = st.disk_spaces || {};
			spaceRing('install', spaces.install);
			spaceRing('tmp', spaces.temporary);
		};
		const openLogin = () => {
			if (busy || loginBusy)
				return;
			loginBusy = true;
			common.login.open(current).then(() => { loginBusy = false; }, () => { loginBusy = false; });
		};
		const runStatusLogin = (e) => {
			if (e.type === 'keydown') {
				if (e.key !== 'Enter' && e.key !== ' ')
					return;
				e.preventDefault();
			}
			if (!current.binary_ok || !current.running || current.auth_reconnecting)
				return;
			openLogin();
		};
		const showTransition = (text) => {
			busy = true;
			root.querySelector('#transitionText').textContent = text;
			root.querySelector('#runTransition').classList.add('show', 'breathing');
			paintPowerButton(pendingEnabled == null ? !!current.enabled : pendingEnabled, true);
			root.querySelector('#runToggle').disabled = true;
			root.querySelector('#restartBtn').disabled = true;
		};
		const hideTransition = () => {
			busy = false;
			root.querySelector('#runTransition').classList.remove('show', 'breathing');
			paintPowerButton(pendingEnabled == null ? !!current.enabled : pendingEnabled, !!current.auth_reconnecting);
			root.querySelector('#runToggle').disabled = !current.binary_ok;
			root.querySelector('#restartBtn').disabled = !current.binary_ok;
		};
		const recordLifecycleStatus = (trace, st) => {
			st = st || {};
			trace.samples.push({ ms: Date.now() - trace.startedAt, running: !!st.running, logged_in: !!st.logged_in, backend_state: st.backend_state || '', enabled: st.enabled == null ? null : !!st.enabled, pid: st.tailscale_pid || '', fw_iface: !!st.fw_iface, fw_zone: !!st.fw_zone });
		};
		const reportLifecycleTrace = (trace) => {
			if (!trace || trace.reported)
				return;
			trace.reported = true;
			console.info('[Tailscale lifecycle trace]', JSON.stringify({ action: trace.action, elapsed_ms: Date.now() - trace.startedAt, samples: trace.samples }));
			if (lifecycleTrace === trace)
				lifecycleTrace = null;
		};
		const waitState = (want, n, settleAt, checkEnabled, previousProcess, silentTimeout, trace) => {
			if (!root.isConnected)
				return;
			const action = checkEnabled ? (want ? 'start' : 'stop') : 'restart';
			if (!trace) {
				if (lifecycleTrace)
					reportLifecycleTrace(lifecycleTrace);
				trace = { action, startedAt: Date.now(), samples: [], reported: false, observeUntil: 0 };
				lifecycleTrace = trace;
			}
			if (n <= 0) {
				root.querySelector('#restartBtn').classList.remove('is-spinning');
				common.api.getStatus(true).then((cur) => {
					current = cur || {};
					recordLifecycleStatus(trace, current);
					if (pendingEnabled != null && current.enabled != null && !!current.enabled === pendingEnabled)
						pendingEnabled = null;
					hideTransition();
					paintDyn(current);
					common.main.badges(root, current);
					reportLifecycleTrace(trace);
				}).catch((e) => {
					trace.samples.push({ ms: Date.now() - trace.startedAt, error: e && e.message ? e.message : 'status_rpc' });
					hideTransition();
					reportLifecycleTrace(trace);
				});
				if (!silentTimeout)
					common.main.toast(_('Service state timed out'));
				return;
			}
			common.api.getStatus(true).then((cur) => {
				cur = cur || {};
				recordLifecycleStatus(trace, cur);
				const currentStart = +cur.tailscale_start_ticks || 0;
				const pidChanged = !!cur.tailscale_pid && previousProcess && '' + cur.tailscale_pid !== previousProcess.pid;
				const startChanged = !!previousProcess && previousProcess.start != null && currentStart > 0 && currentStart !== previousProcess.start;
				const processChanged = !previousProcess || !previousProcess.pid || pidChanged || startChanged;
				const matched = !!cur.running === want && (!checkEnabled || !!cur.enabled === want) && processChanged;
				if (matched && (!settleAt || Date.now() >= settleAt)) {
					if (checkEnabled)
						pendingEnabled = null;
					hideTransition();
					root.querySelector('#restartBtn').classList.remove('is-spinning');
					current = cur;
					paintDyn(cur);
					common.main.badges(root, cur);
					if (action === 'stop' || cur.logged_in) {
						reportLifecycleTrace(trace);
					}
					else {
						trace.observeUntil = Date.now() + 300000;
					}
					return;
				}
				common.main.badges(root, previousProcess || matched && settleAt ? { restarting: true } : cur);
				setTimeout(() => waitState(want, n - 1, settleAt, checkEnabled, previousProcess, silentTimeout, trace), 1500);
			}).catch((e) => {
				trace.samples.push({ ms: Date.now() - trace.startedAt, error: e && e.message ? e.message : 'status_rpc' });
				setTimeout(() => waitState(want, n - 1, settleAt, checkEnabled, previousProcess, silentTimeout, trace), 1500);
			});
		};

		const setEnabled = (want) => {
			const prev = current.enabled == null ? !!current.running : !!current.enabled;
			const wasRunning = !!current.running;
			const service = (action) => common.api.service(action).then((r) => {
				if (!r || r.accepted === false) {
					const detail = { action, accepted: !!(r && r.accepted), busy: !!(r && r.busy), error: r && r.error || '' };
					console.error('[Tailscale service action rejected]', JSON.stringify(detail));
					throw new Error(detail.busy ? 'busy' : detail.error || 'service');
				}
				return r;
			});
			if (busy || want === prev)
				return;
			if (want && lastKnownLoggedIn)
				authGraceUntil = Date.now() + 90000;
			pendingEnabled = want;
			paintPowerButton(want);
			showTransition(want ? _('Starting service') : _('Stopping service'));
			common.api.setConfig('main', { enabled: want ? '1' : '0' }).then((saved) => {
				if (!saved || saved.ok === false)
					throw new Error(saved && saved.error ? 'config:' + saved.error : 'config');
				if (want)
					return service('enable').then(() => wasRunning ? { accepted: true } : service('start'));
				return (wasRunning ? service('stop') : Promise.resolve({ accepted: true })).then(() => service('disable'));
			}).then((r) => {
				if (!r || r.accepted === false)
					throw new Error('service');
				waitState(want, want ? 40 : 12, null, true);
			}).catch((e) => {
				console.error('[Tailscale service action failed]', e && e.message ? e.message : e);
				pendingEnabled = prev;
				common.api.setConfig('main', { enabled: prev ? '1' : '0' }).catch(() => {}).then(() => service(prev ? 'enable' : 'disable').catch(() => {})).then(() => {
					if (prev && wasRunning)
						return service('start').catch(() => {});
				}).then(() => common.api.getStatus(true)).then((cur) => {
					current = cur || {};
					pendingEnabled = null;
					hideTransition();
					paintDyn(current);
					common.main.badges(root, current);
				}).catch(() => {
					pendingEnabled = null;
					hideTransition();
					paintPowerButton(prev);
				});
				common.main.toast(_('Tailscale service action failed'));
			});
		};
		common.main.wire('overview', root, hasInitialStatus ? s : null);
		common.login.init(root);
		if (hasInitialStatus)
			paintDyn(s);
		root.querySelector('#coreBanner').addEventListener('click', () => { location.href = L.url('admin/vpn/tailscale/update'); });
		root.querySelector('#coreInstall').addEventListener('click', (e) => {
			e.stopPropagation();
			location.href = L.url('admin/vpn/tailscale/update');
		});
		root.querySelector('#verCard').addEventListener('click', () => { location.href = L.url('admin/vpn/tailscale/update'); });
		root.querySelector('#copyIp').addEventListener('click', (e) => {
			e.preventDefault();
			common.main.copy((current.tail_ips || [])[0] || '');
		});
		root.querySelector('#tailCard').addEventListener('click', () => {
			if (current.binary_ok != null && !current.auth_reconnecting)
				openLogin();
		});
		for (const selector of ['#runState', '#runSub']) {
			const target = root.querySelector(selector);
			target.addEventListener('click', runStatusLogin);
			target.addEventListener('keydown', runStatusLogin);
		}
		root.querySelector('#runToggle').addEventListener('click', (e) => setEnabled(e.currentTarget.getAttribute('aria-pressed') !== 'true'));
		root.querySelector('#restartBtn').addEventListener('click', () => {
			if (busy)
				return;
			if (!current.binary_ok) {
				common.main.toast(_('Please install the core first'));
				return;
			}
			if (lastKnownLoggedIn)
				authGraceUntil = Date.now() + 90000;
			const startTicks = +current.tailscale_start_ticks || 0;
			const previousProcess = current.tailscale_pid ? { pid: '' + current.tailscale_pid, start: startTicks > 0 ? startTicks : null } : null;
			showTransition(_('Restarting Tailscale service'));
			common.main.badges(root, { restarting: true });
			root.querySelector('#restartBtn').classList.add('is-spinning');
			common.api.service('restart').then((r) => {
				if (!r || r.accepted === false)
					throw new Error('service');
				waitState(true, 40, Date.now() + 3000, false, previousProcess, true);
			}).catch(() => {
				hideTransition();
				root.querySelector('#restartBtn').classList.remove('is-spinning');
				common.api.getStatus(true).then((cur) => {
					current = cur || {};
					paintDyn(current);
					common.main.badges(root, current);
				});
			});
		});
		let unsubscribeStatus;
		unsubscribeStatus = common.main.onStatus((cur) => {
			if (!root.isConnected) {
				unsubscribeStatus();
				return;
			}
			if (busy || loginBusy || root.querySelector('#loginOverlay').classList.contains('login-busy'))
				return;
			cur = cur || {};
			if (pendingEnabled != null && cur.enabled != null && !!cur.enabled === pendingEnabled)
				pendingEnabled = null;
			if (lifecycleTrace) {
				recordLifecycleStatus(lifecycleTrace, cur);
				if (cur.logged_in || lifecycleTrace.observeUntil && Date.now() >= lifecycleTrace.observeUntil)
					reportLifecycleTrace(lifecycleTrace);
			}
			paintDyn(cur);
		});
		return d;
	}
});
