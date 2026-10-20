'use strict';
'require view';
'require tailscale.common as common';

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
	load() {
		return common.api.getConfig('main').then((o) => ({
			status: common.api.getCachedStatus() || {},
			main: (o && o.config) || {}
		})).catch(() => ({ status: common.api.getCachedStatus() || {}, main: {} }));
	},
	latOf(s, ip) {
		const dm = s.derp_ms || {};
		return dm[ip] || null;
	},
	relTime(iso) {
		if (!iso)
			return '—';
		const t = Date.parse(iso);
		if (isNaN(t))
			return '—';
		const sec = Math.max(0, Math.floor((Date.now() - t) / 1000));
		if (sec < 90)
			return _('just now');
		const m = Math.floor(sec / 60);
		if (m < 90)
			return _('N minutes ago').replace('N', '' + m);
		const h = Math.floor(m / 60);
		if (h < 48)
			return _('N hours ago').replace('N', '' + h);
		return _('N days ago').replace('N', '' + Math.floor(h / 24));
	},
	render(data) {
		data = data || {};
		const initial = data.status || {};
		const mainConfig = data.main || {};
		const hasInitialStatus = Object.keys(initial).length > 0;
		const regions = Array.isArray(initial.derp_regions) ? initial.derp_regions : [];
		const rawRegion = '' + (mainConfig.derp_preferred_region || '0');
		const preferredRegion = /^\d{1,9}$/.test(rawRegion) ? '' + parseInt(rawRegion, 10) : '0';
		const buildRegionOptions = (regionList, selectedRegion) => {
			const sortedRegions = regionList.slice().sort((a, b) => {
				const an = (a.name || a.code || '').toLowerCase();
				const bn = (b.name || b.code || '').toLowerCase();
				return an < bn ? -1 : an > bn ? 1 : (+a.id || 0) - (+b.id || 0);
			});
			const knownRegions = {};
			let options = '<option value="0"' + (selectedRegion === '0' ? ' selected' : '') + '>' + _('Auto (Tailscale chooses)') + '</option>';
			for (const region of sortedRegions) {
				const id = '' + parseInt(region.id, 10);
				if (!/^[1-9]\d*$/.test(id) || knownRegions[id])
					continue;
				knownRegions[id] = true;
				const name = region.name || region.code || _('Region') + ' ' + id;
				const code = region.code && region.code.toLowerCase() !== name.toLowerCase() ? ' (' + common.main.esc(region.code) + ')' : '';
				options += '<option value="' + common.main.esc(id) + '"' + (selectedRegion === id ? ' selected' : '') + '>' + common.main.esc(name) + code + ' · #' + common.main.esc(id) + '</option>';
			}
			if (selectedRegion !== '0' && !knownRegions[selectedRegion])
				options += '<option value="' + common.main.esc(selectedRegion) + '" selected>' + _('Region') + ' ' + common.main.esc(selectedRegion) + ' (' + _('not in the current DERP map') + ')</option>';
			return options;
		};
		const regionOptions = buildRegionOptions(regions, preferredRegion);
		const derpHelp = _('Auto lets Tailscale choose. A selected region is preferred only when a connection needs DERP; direct connections remain direct.');
		const mapUnavailableText = _('DERP region list unavailable. Auto can still be selected.');
		const initialMapHint = initial.derp_map_available === false ? mapUnavailableText : '';
		const mapHint = '<div class="stat-s" id="derpMapHint"' + (initialMapHint ? '' : ' style="display:none"') + '>' + common.main.esc(initialMapHint) + '</div>';
		const nodeLoading = hasInitialStatus ? '' : '<div class="stat-s">' + _('Loading nodes') + '</div>';
		const body =
			'<div class="grid"><div class="card glass"><h3>' + common.icons.icon('nodes') + ' ' + _('Node list') + '</h3>' +
			'<div class="field derp-setting"><div class="derp-setting-row"><label for="derpRegion">' + _('Preferred DERP region') + '</label><select id="derpRegion">' + regionOptions + '</select></div>' +
			'<div class="stat-s">' + common.main.esc(derpHelp) + '</div>' + mapHint + '</div>' +
			'<div class="chips" id="nodeChips"></div>' +
			'<div class="field node-search"><input id="nodeSearch" placeholder="' + _('Search name, IP, OS') + '"></div>' +
			'<div class="stat-s" id="subnetHint" style="display:none">' + _('Subnet routes need approval in the admin console') + '</div>' +
			'<div id="nodeRows">' + nodeLoading + '</div>' +
			'<div class="btnrow"><button type="button" class="btn sm" id="pingBtn">' + common.icons.icon('refresh') + ' <span>' + _('Refresh latency') + '</span></button></div>' +
			'</div></div>';
		const d = document.createElement('div');
		d.className = 'cbi-map';
		d.innerHTML = common.main.shell('nodes', body);
		const root = d.querySelector('#app');
		const self = this;
		let cur = initial, f = 'all', q = '', pinging = false;
		let savedRegion = preferredRegion, savingRegion = false;
		const isSub = (p) => (p.approved && p.approved.length > 0) || (p.pending && p.pending.length > 0);
		const routeFor = (p) => {
			const l = self.latOf(cur, p.ip);
			const via = l && l.via ? '' + l.via : '';
			const direct = via ? via === 'direct' : p.direct === true;
			const relay = direct ? '' : via && via !== 'direct' && via !== 'derp' ? via : p.relay || '';
			return { direct, relay };
		};
		const paint = () => {
			const peers = cur.peers || [];
			let cDirect = 0, cDerp = 0, cOff = 0, cSub = 0;
			for (const p of peers) {
				if (!p.online)
					cOff++;
				else if (routeFor(p).direct)
					cDirect++;
				else
					cDerp++;
				if (isSub(p))
					cSub++;
			}
			const chips = [['all', _('All') + ' (' + (peers.length + 1) + ')'], ['direct', _('P2P direct') + ' (' + cDirect + ')'],
				['derp', _('DERP relay') + ' (' + cDerp + ')'], ['off', _('Offline') + ' (' + cOff + ')'],
				['subnet', _('Subnet routes') + ' (' + cSub + ')']];
			let ch = '';
			for (const c of chips)
				ch += '<button type="button" class="chip' + (f === c[0] ? ' on' : '') + '" data-f="' + c[0] + '">' + common.main.esc(c[1]) + '</button>';
			root.querySelector('#nodeChips').innerHTML = ch;
			root.querySelector('#subnetHint').style.display = f === 'subnet' ? '' : 'none';
			const cs = root.querySelectorAll('#nodeChips .chip');
			for (let i = 0; i < cs.length; i++)
				cs[i].addEventListener('click', () => {
					f = cs[i].getAttribute('data-f');
					paint();
				});
			const dot = (p) => {
				if (p.me)
					return 'me';
				if (!p.online)
					return 'off';
				const l = self.latOf(cur, p.ip);
				if (!l || l.ms == null)
					return 'ok';
				return l.ms <= 100 ? 'ok' : l.ms <= 250 ? 'warn' : 'err';
			};
			const connPill = (p) => {
				if (p.me)
					return _('This host');
				if (!p.online)
					return _('Offline');
				return routeFor(p).direct ? _('P2P direct') : _('DERP relay');
			};
			const info = (p) => {
				if (p.me)
					return (cur.tail_ips || []).join(', ') + ' · ' + (cur.hostname || '');
				let t = (p.ip || '') + ' · ' + (p.os || '');
				if (!p.online)
					return t + ' · ' + _('Last seen') + ' ' + self.relTime(p.lastseen);
				const l = self.latOf(cur, p.ip);
				const route = routeFor(p);
				t += ' · ' + _('Latency') + ' ' + (l && l.ms != null ? l.ms + 'ms' : _('Not measured'));
				if (route.relay)
					t += ' · ' + _('Relay') + ' ' + route.relay;
				const r = (p.approved || []).concat(p.pending || []);
				if (r.length > 0)
					t += ' · ' + _('Routes') + ' ' + r.join(',');
				return t;
			};
			const subPills = (p) => {
				let t = '';
				if (p.approved && p.approved.length > 0)
					t += ' <span class="pill ok">' + _('Subnet approved') + '</span>';
				if (p.pending && p.pending.length > 0)
					t += ' <span class="pill warn">' + _('Subnet pending') + '</span>';
				return t;
			};
			let h = '';
			if (f === 'all')
				h += '<div class="nrow"><span class="ndot me"></span><div class="t"><b>' + common.main.esc(cur.hostname || _('This host')) +
					' <span class="pill">' + _('This host') + '</span></b><span class="info">' + common.main.esc(info({ me: true })) + '</span></div>' +
					'<button type="button" class="btn sm" data-act="goto">' + _('Manage my routes') + '</button></div>';
			for (const p of peers) {
				if (f === 'subnet' && !isSub(p)) continue;
				if (f === 'direct' && !(p.online && routeFor(p).direct)) continue;
				if (f === 'derp' && !(p.online && !routeFor(p).direct)) continue;
				if (f === 'off' && p.online) continue;
				if (q && ((p.name || '') + (p.ip || '') + (p.os || '')).toLowerCase().indexOf(q) < 0) continue;
				h += '<div class="nrow"><span class="ndot ' + dot(p) + '"></span><div class="t"><b>' + common.main.esc(p.name || p.ip) +
					' <span class="pill">' + common.main.esc(connPill(p)) + '</span>' + subPills(p) + '</b>' +
					'<span class="info">' + common.main.esc(info(p)) + '</span></div>' +
					'<button type="button" class="btn sm" data-act="copy" data-ip="' + common.main.esc(p.ip || '') + '">' + _('Copy IP') + '</button></div>';
			}
			root.querySelector('#nodeRows').innerHTML = h || '<div class="stat-s empty-nodes">' + _('No matching nodes') + '</div>';
		};
		const doPing = (timeout) => {
			if (pinging || !root.isConnected)
				return;
			pinging = true;
			const button = root.querySelector('#pingBtn');
			button.classList.add('is-spinning');
			return common.api.pingPeers(8, timeout).then((result) => {
				if (!root.isConnected)
					return;
				cur = Object.assign({}, cur, { derp_ms: result && result.latency || {} });
				paint();
			}).catch(() => {}).finally(() => {
				pinging = false;
				if (button.isConnected)
					button.classList.remove('is-spinning');
			});
		};
		setTimeout(() => {
			if (!root.isConnected)
				return;
			common.main.wire('nodes', root, hasInitialStatus ? cur : null);
			common.login.init(root);
			if (hasInitialStatus)
				paint();
			const loadDerpMap = () => common.api.getStatusWithDerp().then((status) => {
				if (!root.isConnected)
					return;
				status = status || {};
				const selector = root.querySelector('#derpRegion');
				const selectedRegion = selector.value || preferredRegion;
				const mapRegions = Array.isArray(status.derp_regions) ? status.derp_regions : [];
				selector.innerHTML = buildRegionOptions(mapRegions, selectedRegion);
				selector.value = selectedRegion;
				const mapAvailable = status.derp_map_available === true;
				const hint = root.querySelector('#derpMapHint');
				hint.textContent = mapAvailable ? '' : mapUnavailableText;
				hint.style.display = mapAvailable ? 'none' : '';
			}).catch(() => {
				if (!root.isConnected)
					return;
				const hint = root.querySelector('#derpMapHint');
				hint.textContent = mapUnavailableText;
				hint.style.display = '';
			});
			const regionSelector = root.querySelector('#derpRegion');
			regionSelector.addEventListener('change', () => {
				const region = regionSelector.value || '0';
				if (savingRegion || region === savedRegion)
					return;
				savingRegion = true;
				regionSelector.disabled = true;
				common.api.setConfig('main', { derp_preferred_region: region }, true).then((result) => {
					if (!result || result.ok === false)
						throw new Error('save');
					savedRegion = result.fallback_auto ? '0' : result.derp_preferred_region || region;
					regionSelector.value = savedRegion;
				}).catch(() => {
					regionSelector.value = savedRegion;
				}).finally(() => {
					savingRegion = false;
					regionSelector.disabled = false;
				});
			});
			root.querySelector('#nodeSearch').addEventListener('input', function () {
				q = this.value.trim().toLowerCase();
				paint();
			});
			root.querySelector('#nodeRows').addEventListener('click', (e) => {
				const b = e.target.closest('button[data-act]');
				if (!b)
					return;
				e.preventDefault();
				e.stopPropagation();
				const act = b.getAttribute('data-act');
				if (act === 'copy')
					common.main.copy(b.getAttribute('data-ip') || '');
				else if (act === 'goto')
					location.href = L.url('admin/vpn/tailscale/settings');
			});
			root.querySelector('#pingBtn').addEventListener('click', () => doPing(2));
			let unsubscribeStatus;
			unsubscribeStatus = common.main.onStatus((st) => {
				if (!root.isConnected) {
					unsubscribeStatus();
					return;
				}
				cur = st || {};
				paint();
			});
			const statusPromise = hasInitialStatus ? Promise.resolve(cur) : common.api.getStatus();
			statusPromise.then(() => {
				if (!root.isConnected)
					return;
				return loadDerpMap().then(() => {
					if (root.isConnected)
						return doPing(1);
				});
			}).catch(() => {
				if (!root.isConnected)
					return;
				if (!hasInitialStatus) {
					cur = {};
					paint();
				}
				const hint = root.querySelector('#derpMapHint');
				hint.textContent = mapUnavailableText;
				hint.style.display = '';
			});
		}, 0);
		return d;
	}
});
