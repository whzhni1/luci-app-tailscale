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
		return Promise.all([
			common.api.getConfig('network').then((o) => (o && o.config) || {}).catch(() => ({})),
			common.api.getConfig('main').then((o) => (o && o.config) || {}).catch(() => ({})),
			common.api.getStatus().then((s) => s || {}).catch(() => ({}))
		]);
	},
	toggle(id, title, on, description) {
		return '<div class="trow"><div class="t"><b>' + title + '</b>' +
			(description ? '<span class="setting-desc">' + description + '</span>' : '') + '</div>' +
			'<label class="switch"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '><span class="sw"></span></label></div>';
	},
	fieldLabel(title, description) {
		return '<label>' + title + '</label>' + (description ? '<div class="stat-s setting-desc">' + description + '</div>' : '');
	},
	render(data) {
		const N = data[0] || {}, M = data[1] || {}, st = data[2] || {};
		const on = (v) => v === '1' || v === 1 || v === true;
		const val = (v) => common.main.esc(v == null ? '' : v);
		const fa = st.fw_apply || null;
		const body =
			'<div class="grid">' +
			'<div class="card glass"><h3>' + common.icons.icon('link') + ' ' + _('Network interface') + '</h3>' +
			'<div class="tbl-scroll"><table class="tbl"><tr><th>' + _('Interface') + '</th><td>' + val(N.iface_name || 'tailscale') + '</td><th>' + _('Protocol') + '</th><td>' + _('Unmanaged') + '</td></tr>' +
			'<tr><th>' + _('Device') + '</th><td>' + val(M.tun || 'tailscale0') + '</td><th>' + _('Status') + '</th><td id="ifaceSt">' +
			(st.fw_iface ? '<span class="pill ok">' + _('Exists') + '</span>' : '<span class="pill">' + _('Missing') + '</span>') + '</td></tr></table></div>' +
			this.toggle('t_iface_enabled', _('Enable network interface'), on(N.iface_enabled), _('Create a netifd interface for the Tailscale tunnel device so it can be used by firewall zones.')) +
			this.toggle('t_reload_network_stop', _('Reload network configuration on stop'), N.reload_network_on_stop == null || on(N.reload_network_on_stop), _('Disable this if the WAN port flickers when stopping Tailscale.')) +
			'<div class="frow"><div class="field">' + this.fieldLabel(_('Interface name'), _('OpenWrt logical interface name used to reference the Tailscale link.')) + '<input id="f_iface_name" value="' + val(N.iface_name || 'tailscale') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('TUN interface name'), _('Name of the tunnel device created by tailscaled; the OpenWrt network device follows this name automatically.')) + '<input id="f_tun" value="' + val(M.tun || 'tailscale0') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('Network mode'), _('TUN creates a kernel network device for normal routing; Userspace uses a userspace network stack and does not create that device.')) + '<select id="f_mode">' +
			'<option value="tun"' + (M.mode !== 'userspace' ? ' selected' : '') + '>' + _('TUN') + '</option>' +
			'<option value="userspace"' + (M.mode === 'userspace' ? ' selected' : '') + '>' + _('Userspace') + '</option></select></div></div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('shield') + ' ' + _('Firewall zone') + '</h3>' +
			'<div class="stat-s fw-state">' + common.main.esc(st.fw_driver === 'none' ? _('None') : st.fw_driver || _('None')) + ' · ' +
			(st.fw_zone ? '<span class="pill ok">' + _('Exists') + '</span>' : '<span class="pill">' + _('Missing') + '</span>') + '</div>' +
			'<div class="frow"><div class="field">' + this.fieldLabel(_('Zone name'), _('Firewall zone associated with the Tailscale interface and its input, output, and forwarding policies.')) + '<input id="f_zone_name" value="' + val(N.zone_name || 'tailscale') + '"></div>' +
			'<div class="field">' + this.fieldLabel(_('On conflict with existing Zone'), _('Choose whether applying settings replaces a zone with the same name or leaves the existing zone unchanged.')) + '<select id="f_conflicts">' +
			'<option value="overwrite"' + (N.conflicts !== 'skip' ? ' selected' : '') + '>' + _('Overwrite') + '</option>' +
			'<option value="skip"' + (N.conflicts === 'skip' ? ' selected' : '') + '>' + _('Skip') + '</option></select></div></div>' +
			this.toggle('t_masq', _('Masquerade'), on(N.masq), _('Translate source addresses on forwarded traffic so return packets can get back through this router when the destination network has no route to the tailnet.')) +
			this.toggle('t_mss', _('MSS clamping'), on(N.mss), _('Adjust TCP maximum segment size to reduce path-MTU problems across the tunnel.')) +
			'<div class="stat-s" id="applySt">' + (fa ? _('Result code') + ' ' + common.main.esc(fa.rc) + ' · ' + common.main.esc(fa.at || '') : '') + '</div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('network') + ' ' + _('Firewall forwarding') + '</h3>' +
			this.toggle('t_ts_lan', _('Tailscale to LAN'), on(N.fwd_ts_lan), _('Allow tailnet devices to initiate connections to devices on this router\'s LAN.')) +
			this.toggle('t_lan_ts', _('LAN to Tailscale'), on(N.fwd_lan_ts), _('Allow devices on this router\'s LAN to initiate connections to tailnet peers.')) +
			this.toggle('t_ts_wan', _('Tailscale to WAN'), on(N.fwd_ts_wan), _('Allow tailnet devices to forward internet-bound traffic through this router.')) +
			this.toggle('t_wan_ts', _('WAN to Tailscale'), on(N.fwd_wan_ts), _('Allow forwarding from the WAN toward Tailscale. This increases exposure and should only be enabled with an explicit firewall policy.')) +
			'</div></div>';
		const d = document.createElement('div');
		d.className = 'cbi-map';
		d.innerHTML = common.main.shell('network', body);
		const root = d.querySelector('#app');
		const q = (id) => root.querySelector(id);
		const gatherMain = () => ({ tun: q('#f_tun').value.trim(), mode: q('#f_mode').value });
		const gatherNetwork = () => ({
			iface_enabled: q('#t_iface_enabled').checked ? '1' : '0',
			iface_name: q('#f_iface_name').value.trim(),
			zone_name: q('#f_zone_name').value.trim(), zone_enabled: '1', conflicts: q('#f_conflicts').value,
			reload_network_on_stop: q('#t_reload_network_stop').checked ? '1' : '0',
			masq: q('#t_masq').checked ? '1' : '0', mss: q('#t_mss').checked ? '1' : '0',
			fwd_ts_lan: q('#t_ts_lan').checked ? '1' : '0', fwd_lan_ts: q('#t_lan_ts').checked ? '1' : '0',
			fwd_ts_wan: q('#t_ts_wan').checked ? '1' : '0', fwd_wan_ts: q('#t_wan_ts').checked ? '1' : '0'
		});
		saveAction = () => [
			['main', gatherMain()],
			['network', gatherNetwork()]
		];
		setTimeout(() => {
			if (!root.isConnected)
				return;
			common.main.wire('network', root, null);
			common.login.init(root);
		}, 0);
		return d;
	}
});
