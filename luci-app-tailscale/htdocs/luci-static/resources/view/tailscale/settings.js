'use strict';
'require view';
'require tailscale.common as common';

let saveAction = null;

return view.extend({
	handleSave() {
		return saveAction ? common.main.stageUci(saveAction()) : Promise.resolve();
	},
	handleSaveApply(ev, mode) {
		return this.handleSave(ev).then(() => common.main.applyUci(mode));
	},
	handleReset: null,
	load() {
		return common.api.getConfig().catch(() => ({})).then((o) => {
			const config = (o && o.config) || {};
			config.router_model = (o && o.router_model) || '';
			return [config, common.api.getCachedStatus() || {}, (o && o.local_routes) || []];
		});
	},
	toggle(id, title, on, flag, description) {
		return '<div class="trow"><div class="t"><b>' + title + '</b>' +
			(flag ? '<code class="cli-hint">' + common.main.esc(flag) + '</code>' : '') +
			(description ? '<span class="setting-desc">' + description + '</span>' : '') + '</div>' +
			'<label class="switch"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '><span class="sw"></span></label></div>';
	},
	fieldLabel(title, flag, description) {
		return '<label><span>' + title + '</span>' + (flag ? '<code class="cli-hint">' + common.main.esc(flag) + '</code>' : '') + '</label>' +
			(description ? '<div class="stat-s setting-desc">' + description + '</div>' : '');
	},
	render(data) {
		const cfg = data[0] || {}, st = data[1] || {}, localRoutes = Array.isArray(data[2]) ? data[2] : [];
		const hasStatus = Object.keys(st).length > 0;
		const M = cfg.main || {}, U = cfg.up || {};
		const hostnameValue = (U.hostname == null ? '' : '' + U.hostname).trim() || cfg.router_model || '';
		const hostnamePlaceholder = cfg.router_model || _('e.g. router-01');
		const on = (v) => v === '1' || v === 1 || v === true;
		const val = (v) => common.main.esc(v == null ? '' : v);
		const routes = ('' + (U.advertise_routes || '')).split(',').map((x) => x.trim()).filter((x) => x !== '');
		const routeCandidates = localRoutes.map((route) => {
			const cidr = typeof route === 'string' ? route : route && route.cidr;
			const device = typeof route === 'string' ? '' : route && route.device;
			return cidr ? { cidr: '' + cidr, device: device ? '' + device : '' } : null;
		}).filter((route) => route != null && route.device !== 'lo' && !/^(tailscale|tun|tap|wg|ppp|gre|sit|vti|zt|docker|virbr)/i.test(route.device));
		for (const route of routes) {
			if (!routeCandidates.some((candidate) => candidate.cidr === route))
				routeCandidates.push({ cidr: route, device: _('Saved') });
		}
		const customRoutes = routes.filter((route, index, all) => !routeCandidates.some((candidate) => candidate.cidr === route) && all.indexOf(route) === index);
		const routeChoices = routeCandidates.length > 0 ? routeCandidates.map((route) => {
			const selected = routes.includes(route.cidr);
			return '<div class="route-option-row"><div class="route-option-info"><span class="route-option-cidr">' + val(route.cidr) + '</span>' + (route.device ? '<span class="route-option-device">(' + val(route.device) + ')</span>' : '') + '</div><button type="button" class="route-option-switch' + (selected ? ' is-on' : '') + '" data-route-value="' + val(route.cidr) + '" aria-label="' + _('Advertise subnet routes') + ' ' + val(route.cidr) + '" aria-pressed="' + (selected ? 'true' : 'false') + '"><span class="route-option-switch-knob"></span></button></div>';
		}).join('') : '<div class="route-empty stat-s">' + _('No directly connected LAN subnets found') + '</div>';
		const routeInputRow = (value) => '<input class="route-custom-input" value="' + val(value) + '" placeholder="' + _('e.g. 192.168.1.0/24') + '"><div class="route-custom-actions"><button type="button" class="btn sm route-custom-add" data-route-action="add" title="' + _('Add subnet') + '" aria-label="' + _('Add subnet') + '">+</button><button type="button" class="btn sm route-custom-remove" data-route-action="remove" title="' + _('Remove subnet') + '" aria-label="' + _('Remove subnet') + '">−</button></div>';
		const routeRows = (customRoutes.length > 0 ? customRoutes : ['']).map((route) => '<div class="route-custom-row">' + routeInputRow(route) + '</div>').join('');
		const routeEnabled = routes.length > 0;
		const localRouteCount = routeCandidates.filter((route) => routes.includes(route.cidr)).length;
		const exitNodeEnabled = !!(U.exit_node && U.exit_node !== '0');
		const buildExitOptions = (peers, selectedValue) => {
			let options = '';
			let selectedFound = false;
			for (const p of peers) {
				if (!p.exit_option)
					continue;
				const value = p.ip || p.name || '';
				const selected = !!selectedValue && (selectedValue === value || selectedValue === p.name);
				const optionValue = selected && selectedValue === p.name ? selectedValue : value;
				if (selected)
					selectedFound = true;
				options += '<option value="' + common.main.esc(optionValue) + '"' + (selected ? ' selected' : '') + '>' + common.main.esc((p.name || value) + (p.ip ? ' · ' + p.ip : '')) + '</option>';
			}
			if (selectedValue && !selectedFound)
				options += '<option value="' + common.main.esc(selectedValue) + '" selected>' + common.main.esc(selectedValue) + '</option>';
			if (!options)
				options = '<option value="" disabled selected>' + _('No exit nodes available') + '</option>';
			return options;
		};
		let exits = buildExitOptions(st.peers || [], U.exit_node || '');
		const body =
			'<div class="grid">' +
			'<div class="card glass"><h3>' + common.icons.icon('settings') + ' ' + _('Basic settings') + '</h3><div class="frow">' +
			'<div class="field">' + this.fieldLabel(_('Hostname'), '--hostname', _('The name shown to other tailnet devices and MagicDNS; it does not change the router\'s system hostname.')) + '<input id="f_hostname" value="' + val(hostnameValue) + '" placeholder="' + val(hostnamePlaceholder) + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('UDP port'), '--port', _('UDP port used by tailscaled. Set to 0 to choose a port automatically.')) + '<input id="f_port" value="' + val(M.port === '0' ? '' : M.port) + '" placeholder="' + _('0 for automatic selection') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('SOCKS5'), '--socks5-server', _('Optional upstream SOCKS5 proxy used for Tailscale connections; leave empty to disable.')) + '<input id="f_socks5" value="' + val(M.socks5) + '" placeholder="' + _('e.g. 127.0.0.1:1080') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('Outbound HTTP proxy'), '--outbound-http-proxy-listen', _('Address for Tailscale\'s outbound HTTP proxy listener; leave empty to disable.')) + '<input id="f_http_proxy" value="' + val(M.http_proxy) + '" placeholder="' + _('e.g. 127.0.0.1:8080') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('Operator user'), '--operator', _('Allow this local account to control Tailscale without sudo.')) + '<input id="f_operator" value="' + val(U.operator) + '" placeholder="' + _('e.g. root') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('Login server'), '--login-server', _('Control server for this device. Leave empty for the official Tailscale control plane, or enter a Headscale URL.')) + '<input id="f_login_server" value="' + val(U.login_server) + '" placeholder="' + _('e.g. https://headscale.example.com') + '"></div>' +
			'</div></div>' +
			'<div class="card glass network-card"><h3>' + common.icons.icon('network') + ' ' + _('Tailscale network') + '</h3>' +
			this.toggle('t_accept_dns', _('Accept tailnet DNS'), on(U.accept_dns), '--accept-dns', _('Use DNS settings supplied by the tailnet. This is separate from accepting subnet routes.')) +
			this.toggle('t_accept_routes', _('Accept subnet routes'), on(U.accept_routes), '--accept-routes', _('Allow this device to install subnet routes advertised by other tailnet nodes. The routes must also be approved by an administrator.')) +
			this.toggle('t_ssh', _('Tailscale SSH'), on(U.ssh), '--ssh', _('Allow tailnet peers to connect to this device using Tailscale SSH, subject to the tailnet access policy.')) +
			this.toggle('t_shields_up', _('Shields up'), on(U.shields_up), '--shields-up', _('Reject new incoming connections from other tailnet devices. This can also block access to services on this router.')) +
			this.toggle('t_snat', _('Subnet route SNAT'), on(U.snat_subnet_routes), '--snat-subnet-routes', _('Apply source NAT to traffic forwarded to advertised subnets, so destination LAN devices see the router as the source.')) +
			this.toggle('t_advertise_exit', _('Advertise as exit node'), on(U.advertise_exit_node), '--advertise-exit-node', _('Advertise this device as an internet exit node for other tailnet devices. Approval may be required in the admin console.')) +
			this.toggle('t_exit_allow_lan', _('Allow LAN bypass on exit node'), on(U.exit_node_allow_lan), '--exit-node-allow-lan-access', _('When this device uses an exit node, allow it to access its local LAN directly.')) +
			this.toggle('t_stateful', _('Stateful filtering'), on(U.stateful_filtering), '--stateful-filtering', _('Filter forwarded traffic using connection state tracking.')) +
			'<div class="field netfilter-field"><div class="netfilter-mode-row"><label for="f_netfilter"><span>' + _('Netfilter mode') + '</span><code class="cli-hint">' + common.main.esc('--netfilter-mode') + '</code></label><select id="f_netfilter">' +
			[['on', _('On')], ['nodivert', _('No divert')], ['off', _('Off')]].map((m) => '<option value="' + m[0] + '"' + (U.netfilter_mode === m[0] ? ' selected' : '') + '>' + m[1] + '</option>').join('') + '</select></div>' +
			'<div class="stat-s setting-desc">' + _('On installs and activates Tailscale firewall rules; No divert installs them without activating them, so you must connect the rules manually; Off creates no Tailscale firewall rules. Use No divert or Off only if you manage firewall integration yourself.') + '</div></div>' +
			this.toggle('t_advertise_routes', _('Advertise subnet routes'), routeEnabled, '--advertise-routes', _('Advertise LAN subnets connected to this router. Remote devices also need to accept subnet routes, and each route may need admin approval.')) +
			'<div class="collapse route-settings' + (routeEnabled ? ' open' : '') + '" id="routeFields"><div class="field route-field"><label class="route-select-label">' + _('Choose local subnet') + '</label>' +
			'<div class="route-dropdown" id="routeDropdown"><button type="button" class="btn route-select-trigger" id="routeDropdownToggle" aria-expanded="false"><span>' + _('Choose local subnet') + '</span><b id="routeSelectionCount">' + localRouteCount + '</b><span class="route-select-chevron" aria-hidden="true">⌄</span></button>' +
			'<div class="route-dropdown-menu" id="routeDropdownMenu">' + routeChoices + '</div></div>' +
			'<div class="route-custom-editor"><label>' + _('Additional CIDR routes') + '</label><div id="routeCustomRows" class="route-custom-list">' + routeRows + '</div></div></div></div>' +
			this.toggle('t_use_exit_node', _('Use exit node'), exitNodeEnabled, '--exit-node', _('Route this device\'s internet-bound traffic through the selected peer.')) +
			'<div class="collapse exit-node-settings' + (exitNodeEnabled ? ' open' : '') + '" id="exitNodeFields"><div class="field"><label>' + _('Choose exit node') + '</label><select id="exitSel">' + exits + '</select></div></div>' +
			'</div>' +
			'<div class="card glass"><h3>' + common.icons.icon('shield') + ' ' + _('Guard and advanced') + '</h3><div class="frow">' +
			'<div class="field"><label>' + _('Boot delay') + '</label><input id="f_start_delay" value="' + val(M.start_delay || '0') + '"><div class="stat-s setting-desc">' + _('Delay in seconds; only applied when router uptime is under 120 seconds.') + '</div></div>' +
			'<div class="field"><label>' + _('Respawn threshold') + '</label><input id="f_respawn_threshold" value="' + val(M.respawn_threshold || '3600') + '"><div class="stat-s setting-desc">' + _('Time window in seconds in which repeated daemon exits are counted as crashes.') + '</div></div>' +
			'<div class="field"><label>' + _('Respawn timeout') + '</label><input id="f_respawn_timeout" value="' + val(M.respawn_timeout || '5') + '"><div class="stat-s setting-desc">' + _('Wait time in seconds before restarting the daemon after it exits.') + '</div></div>' +
			'<div class="field"><label>' + _('Respawn retry') + '</label><input id="f_respawn_retry" value="' + val(M.respawn_retry || '5') + '"><div class="stat-s setting-desc">' + _('Maximum number of automatic restarts; 0 means unlimited.') + '</div></div>' +
			'<div class="field">' + this.fieldLabel(_('State directory'), '--state, --statedir', _('Stores this node\'s identity and keys. Keep it persistent across reboots to avoid logging in again.')) + '<input id="f_state_dir" value="' + val(M.state_dir || '/etc/tailscale') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('Daemon socket path'), null, _('Local API socket used by the CLI and LuCI backend; change only if the daemon uses the same path.')) + '<input id="f_socket" value="' + val(M.socket || '') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('Temp dir'), null, _('Directory for temporary files and logs; it must be writable and have enough free space.')) + '<input id="f_tmp_dir" value="' + val(M.tmp_dir || '/tmp/tailscale') + '"></div>' +
			'</div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('doc') + ' ' + _('Log settings') + '</h3>' +
			this.toggle('t_log_enabled', _('Enable daemon and Tailscale command logs'), on(M.log_enabled), null, _('Write daemon and Tailscale command output to the local log.')) +
			'<div class="collapse' + (on(M.log_enabled) ? ' open' : '') + '" id="logFields">' +
			'<div class="field"><label>' + _('Log size limit') + '</label><input id="f_log_limit_kb" inputmode="numeric" value="' + val(M.log_limit_kb || '300') + '"><div class="stat-s setting-desc">' + _('Maximum retained log size in kilobytes; older output is truncated.') + '</div></div>' +
			this.toggle('t_log_errors_only', _('Keep warnings and errors only'), on(M.log_errors_only), null, _('Keep only warnings and errors in the command log.')) + '</div></div>' +
			'</div>';
		const d = document.createElement('div');
		d.className = 'cbi-map';
		d.innerHTML = common.main.shell('settings', body);
		const root = d.querySelector('#app');
		const q = (id) => root.querySelector(id);
		const selectedRouteValues = () => Array.from(q('#routeDropdownMenu').querySelectorAll('.route-option-switch[aria-pressed="true"]')).map((button) => button.getAttribute('data-route-value'));
		const refreshExitOptions = (status) => {
			if (!root.isConnected)
				return;
			const select = q('#exitSel');
			const selected = select.value;
			select.innerHTML = buildExitOptions((status || {}).peers || [], selected);
			select.value = selected;
			if (!selected && select.options.length && !select.options[0].disabled) select.selectedIndex = 0;
		};
		const gather = () => {
			const hostnameInput = q('#f_hostname');
			if (!hostnameInput.value.trim()) hostnameInput.value = cfg.router_model || '';
			const routesEnabled = q('#t_advertise_routes').checked;
			const rs = routesEnabled ? selectedRouteValues() : [];
			if (routesEnabled) {
				for (const input of q('#routeCustomRows').querySelectorAll('.route-custom-input')) {
					const route = input.value.trim();
					if (route && !rs.includes(route)) rs.push(route);
				}
			}
			return [
				['main', {
					port: q('#f_port').value.trim() || '0', socks5: q('#f_socks5').value.trim(), http_proxy: q('#f_http_proxy').value.trim(),
					start_delay: q('#f_start_delay').value.trim(), respawn_threshold: q('#f_respawn_threshold').value.trim(),
					respawn_timeout: q('#f_respawn_timeout').value.trim(), respawn_retry: q('#f_respawn_retry').value.trim(),
					state_dir: q('#f_state_dir').value.trim(), socket: q('#f_socket').value.trim(), tmp_dir: q('#f_tmp_dir').value.trim(),
					log_enabled: q('#t_log_enabled').checked ? '1' : '0', log_limit_kb: q('#f_log_limit_kb').value.trim() || '300',
					log_errors_only: q('#t_log_errors_only').checked ? '1' : '0'
				}],
				['up', {
					hostname: hostnameInput.value.trim(), operator: q('#f_operator').value.trim(), login_server: q('#f_login_server').value.trim(),
					netfilter_mode: q('#f_netfilter').value, accept_dns: q('#t_accept_dns').checked ? '1' : '0',
					accept_routes: q('#t_accept_routes').checked ? '1' : '0', ssh: q('#t_ssh').checked ? '1' : '0',
					shields_up: q('#t_shields_up').checked ? '1' : '0', snat_subnet_routes: q('#t_snat').checked ? '1' : '0',
					advertise_exit_node: q('#t_advertise_exit').checked ? '1' : '0', exit_node_allow_lan: q('#t_exit_allow_lan').checked ? '1' : '0',
					stateful_filtering: q('#t_stateful').checked ? '1' : '0', advertise_routes: rs.join(','), exit_node: q('#t_use_exit_node').checked ? q('#exitSel').value : ''
				}]
			];
		};
		saveAction = () => gather();
		setTimeout(() => {
			if (!root.isConnected)
				return;
			common.main.wire('settings', root, hasStatus ? st : null);
			common.login.init(root);
			q('#t_advertise_routes').addEventListener('change', (e) => q('#routeFields').classList.toggle('open', e.target.checked));
			q('#t_use_exit_node').addEventListener('change', (e) => q('#exitNodeFields').classList.toggle('open', e.target.checked));
			const routeDropdown = q('#routeDropdown'), routeDropdownToggle = q('#routeDropdownToggle');
			const updateRouteSelectionCount = () => { q('#routeSelectionCount').textContent = '' + selectedRouteValues().length; };
			routeDropdownToggle.addEventListener('click', () => {
				const open = routeDropdown.classList.toggle('open');
				routeDropdownToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
			});
			q('#routeDropdownMenu').addEventListener('click', (e) => {
				const button = e.target.closest('.route-option-switch');
				if (!button) return;
				const selected = button.getAttribute('aria-pressed') !== 'true';
				button.setAttribute('aria-pressed', selected ? 'true' : 'false');
				button.classList.toggle('is-on', selected);
				updateRouteSelectionCount();
			});
			root.addEventListener('click', (e) => {
				if (!routeDropdown.contains(e.target)) {
					routeDropdown.classList.remove('open');
					routeDropdownToggle.setAttribute('aria-expanded', 'false');
				}
			});
			root.addEventListener('keydown', (e) => {
				if (e.key === 'Escape') {
					routeDropdown.classList.remove('open');
					routeDropdownToggle.setAttribute('aria-expanded', 'false');
				}
			});
			q('#routeCustomRows').addEventListener('click', (e) => {
				const button = e.target.closest('[data-route-action]');
				if (!button) return;
				const rows = q('#routeCustomRows'), row = button.closest('.route-custom-row');
				if (button.getAttribute('data-route-action') === 'add') {
					const next = document.createElement('div');
					next.className = 'route-custom-row';
					next.innerHTML = routeInputRow('');
					row.after(next);
					next.querySelector('.route-custom-input').focus();
				}
				else if (rows.children.length > 1) row.remove();
				else row.querySelector('.route-custom-input').value = '';
			});
			q('#routeCustomRows').addEventListener('keydown', (e) => {
				if (e.target.matches('.route-custom-input') && e.key === 'Enter') {
					e.preventDefault();
					e.target.closest('.route-custom-row').querySelector('[data-route-action="add"]').click();
				}
			});
			q('#t_log_enabled').addEventListener('change', (e) => {
				q('#logFields').classList.toggle('open', e.target.checked);
			});
			common.api.getStatus(true).then(refreshExitOptions).catch(() => {});
		}, 0);
		return d;
	},

});
