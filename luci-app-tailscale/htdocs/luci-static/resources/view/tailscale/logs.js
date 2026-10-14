'use strict';
'require view';
'require tailscale.common as common';

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
	load() {
		return Promise.resolve({ loading: true });
	},
	render(g) {
		g = g || {};
		const logLoading = g.loading ? _('Loading logs') : '';
		const body =
			'<div class="grid" style="gap:14px">' +
			'<div class="card glass"><h3>' + common.icons.icon('doc') + ' ' + _('Log center') + '</h3>' +
			'<div class="desc">' + _('Runtime and tailnet status') + '</div>' +
			'<div class="seg glass log-seg" id="logSeg"><button type="button" class="on" data-l="run">' + _('Runtime log') + '</button>' +
			'<button type="button" data-l="cmd">' + _('Backend commands') + '</button>' +
			'<button type="button" data-l="st">' + _('Tailnet status') + '</button></div>' +
			'<div class="btnrow" style="margin-top:0">' +
			'<button type="button" class="btn sm" id="logRefresh">' + common.icons.icon('refresh') + ' <span>' + _('Refresh') + '</span></button>' +
			'<button type="button" class="btn sm" id="logClear">' + common.icons.icon('x') + ' <span>' + _('Clear logs') + '</span></button>' +
			'<button type="button" class="btn sm" id="logExport">' + common.icons.icon('download') + ' <span>' + _('Export diag') + '</span></button></div>' +
			'<pre class="log" id="log-run">' + common.main.esc(g.logread || logLoading) + '</pre>' +
			'<pre class="log" id="log-cmd" style="display:none">' + common.main.esc(g.backend_log || '') + '</pre>' +
			'<pre class="log" id="log-st" style="display:none">' + common.main.esc(g.status || '') + '</pre></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('info') + ' ' + _('State collect') + '</h3>' +
			'<div class="desc">' + _('Troubleshooting kit') + '</div>' +
			'<table class="tbl"><tr><th>tailscale --version</th><td id="probeVer">' + common.main.esc((g.version || '').split('\n')[0] || '—') + '</td></tr></table>' +
			'<div class="btnrow"><button type="button" class="btn sm" id="probeStatus">' + _('View full status') + '</button>' +
			'<button type="button" class="btn sm" id="probeExport">' + common.icons.icon('download') + ' <span>' + _('Export diag') + '</span></button></div>' +
			'</div></div>';
		const d = document.createElement('div');
		d.innerHTML = common.main.shell('logs', body);
		const root = d.querySelector('#app');
		let logRequest = 0;
		const paintLogs = (o) => {
			o = o || {};
			root.querySelector('#log-run').textContent = o.logread || '';
			root.querySelector('#log-cmd').textContent = o.backend_log || '';
			root.querySelector('#log-st').textContent = o.status || '';
			root.querySelector('#probeVer').textContent = (o.version || '').split('\n')[0] || '—';
		};
		const fetchLogs = (notify) => {
			const request = ++logRequest;
			return common.api.getLogs(200).then((o) => {
				if (!root.isConnected || request !== logRequest)
					return;
				paintLogs(o);
				if (notify)
					common.main.toast(_('Refreshed'));
			}).catch(() => {
				if (!root.isConnected || request !== logRequest)
					return;
				if (notify)
					common.main.toast(_('Refresh failed'));
				else
					root.querySelector('#log-run').textContent = '';
			});
		};
		setTimeout(() => {
			if (!root.isConnected) return;
			common.main.wire('logs', root);
			common.login.init(root);
			const showSeg = (v) => {
				const btns = root.querySelectorAll('#logSeg button');
				for (let i = 0; i < btns.length; i++)
					btns[i].classList.toggle('on', btns[i].getAttribute('data-l') === v);
				root.querySelector('#log-run').style.display = v === 'run' ? '' : 'none';
				root.querySelector('#log-cmd').style.display = v === 'cmd' ? '' : 'none';
				root.querySelector('#log-st').style.display = v === 'st' ? '' : 'none';
			};
			const btns = root.querySelectorAll('#logSeg button');
			for (let i = 0; i < btns.length; i++)
				btns[i].addEventListener('click', () => showSeg(btns[i].getAttribute('data-l')));
			root.querySelector('#logRefresh').addEventListener('click', () => fetchLogs(true));
			root.querySelector('#logClear').addEventListener('click', () => {
				logRequest++;
				common.api.clearLogs().then((o) => {
					if (!o || !o.ok)
						throw new Error('clear');
					root.querySelector('#log-run').textContent = '';
					root.querySelector('#log-cmd').textContent = '';
					common.main.toast(_('Logs cleared'));
				}).catch(() => common.main.toast(_('Clear logs failed')));
			});
			const doExport = () => {
				common.api.diag().then((o) => {
					const t = (o && o.text) || '';
					if (!t) {
						common.main.toast(_('Empty diag'));
						return;
					}
					const blob = new Blob([t], { type: 'text/plain' });
					const a = document.createElement('a');
					a.href = URL.createObjectURL(blob);
					a.download = 'tailscale-diag.txt';
					document.body.appendChild(a);
					a.click();
					setTimeout(() => {
						URL.revokeObjectURL(a.href);
						document.body.removeChild(a);
					}, 500);
					common.main.toast(_('Diag exported'));
				}).catch(() => common.main.toast(_('Export failed')));
			};
			root.querySelector('#logExport').addEventListener('click', doExport);
			root.querySelector('#probeExport').addEventListener('click', doExport);
			root.querySelector('#probeStatus').addEventListener('click', () => {
				showSeg('st');
				root.querySelector('#log-st').scrollIntoView({ block: 'center' });
			});
			fetchLogs(false);
		}, 0);
		return d;
	}
});
