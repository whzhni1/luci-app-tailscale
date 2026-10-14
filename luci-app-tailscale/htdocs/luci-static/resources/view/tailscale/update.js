'use strict';
'require view';
'require tailscale.common as common';
'require rpc';

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
			common.api.getConfig().then((o) => (o && o.config) || {}).catch(() => ({})),
			common.api.getStatus(true).then((s) => s || {}).catch(() => ({}))
		]);
	},
	normTag(t) {
		t = '' + (t || '');
		return t.charAt(0) === 'v' ? t.slice(1) : t;
	},
	cmpVer(a, b) {
		const pa = this.normTag(a).split('.'), pb = this.normTag(b).split('.');
		for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
			const x = parseInt(pa[i] || '0', 10) || 0, y = parseInt(pb[i] || '0', 10) || 0;
			if (x !== y)
				return x < y ? -1 : 1;
		}
		return 0;
	},
	render(data) {
		const cfg = data[0] || {}, st = data[1] || {};
		const Up = cfg.update || {}, M = cfg.main || {};
		const on = (v) => v === '1' || v === 1 || v === true;
		const val = (v) => common.main.esc(v == null ? '' : v);
		const ver = st.version ? ('' + st.version).split(/[ \n]/)[0] : '';
		const sourceOptions = ('' + (Up.source_order || 'gitlab r2 github')).split(/\s+/).filter((x, i, a) => ['gitlab', 'r2', 'github'].includes(x) && a.indexOf(x) === i);
		const sourceLabel = (x) => x === 'gitlab' ? _('GitLab') : x === 'r2' ? _('Cloudflare R2') : x === 'github' ? _('GitHub') : x === 'official' ? _('Official Tailscale') : x;
		for (const source of ['gitlab', 'r2', 'github'])
			if (!sourceOptions.includes(source)) sourceOptions.push(source);
		const body =
			'<div class="grid"><div class="grid g2">' +
			'<div class="card glass"><h3>' + common.icons.icon('download') + ' ' + _('Current Tailscale core') + '</h3>' +
			'<div class="stat-v" id="curVer">' + common.main.esc(ver || '—') + '</div>' +
			'<div class="stat-s">' + _('Arch') + ' <b id="curArch">' + val(st.arch || '—') + '</b></div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('refresh') + ' ' + _('Latest version') + '</h3>' +
			'<div class="stat-v" id="newVer">…</div><div class="stat-s" id="newSub"></div>' +
			'<div class="btnrow"><button type="button" class="btn sm" id="checkBtn">' + common.icons.icon('refresh') + ' <span>' + _('Check update') + '</span></button></div></div>' +
			'</div>' +
			'<div class="card glass"><h3>' + common.icons.icon('download') + ' ' + _('Tailscale core update') + '</h3>' +
			'<div class="seg update-tabs" role="tablist"><button type="button" id="onlineTab" class="on" role="tab" aria-selected="true">' + _('Online download') + '</button><button type="button" id="manualTab" role="tab" aria-selected="false">' + _('Manual upload') + '</button></div>' +
			'<div id="onlinePanel" role="tabpanel">' +
			'<div class="frow"><div class="field channel-field"><label>' + _('Update channel') + '</label><select id="dlChannel" class="update-channel-select">' +
			'<option value="custom"' + (Up.channel !== 'official' ? ' selected' : '') + '>' + _('GitHub build (under 10M)') + '</option>' +
			'<option value="official"' + (Up.channel === 'official' ? ' selected' : '') + '>' + _('Official Tailscale') + '</option></select><div class="stat-s space-note" id="channelSpaceHint"></div></div></div>' +
			
			
			'<div class="trow rollback-row"><div class="t"><b>' + _('Automatic rollback on failure') + '</b></div><label class="switch"><input type="checkbox" id="rollbackSw"' + (on(Up.auto_rollback == null ? '1' : Up.auto_rollback) ? ' checked' : '') + '><span class="sw"></span></label></div>' +
			'<div class="stat-s space-note" id="rollbackHint"></div>' +
			'<div id="customFields"><div class="frow">' +
			'<div class="field"><label>' + _('Mirror source') + '</label><select id="dlSrc">' + sourceOptions.map((x, i) => '<option value="' + common.main.esc(x) + '"' + (i === 0 ? ' selected' : '') + '>' + common.main.esc(sourceLabel(x)) + '</option>').join('') + '</select></div>' +
			'<div class="field"><label>' + _('Version') + '</label><select id="dlVer"><option value="">' + _('Loading versions') + '</option></select></div>' +
			'<div class="field"><label>' + _('File list') + '</label><select id="dlFile"><option value="">' + _('Loading files') + '</option></select></div>' +
			'<div class="field"><label>' + _('Arch') + '</label><input id="dlArch" value="' + val(Up.arch || 'auto') + '" placeholder="' + _('Auto') + '"></div></div></div>' +
			'<div class="frow update-action-row"><div class="field"><label>' + _('Install dir') + '</label><input id="dlDir" value="' + val(M.bin_dir || '/usr/sbin') + '"></div>' +
			'<div class="field update-action"><button type="button" class="btn primary install-btn" id="dlBtn">' + common.icons.icon('download') + ' <span>' + _('Download and install') + '</span></button><div class="stat-s space-note" id="dlSpaceHint"></div></div></div>' +
			'<div class="card inset" id="officialInfo" style="display:none"><h4>' + _('Official static Linux update') + '</h4>' +
			'<table class="tbl"><tr><th>' + _('Official architecture') + '</th><td id="officialArch">—</td></tr>' +
			'<tr><th>' + _('Download archive') + '</th><td id="officialDownloadSize">—</td></tr>' +
			'<tr><th>' + _('Current binary footprint') + '</th><td id="officialInstalledSize">—</td></tr>' +
			'<tr><th>' + _('Free space in install filesystem') + '</th><td id="officialFreeBin">—</td></tr>' +
			'<tr><th>' + _('Free space in temporary filesystem') + '</th><td id="officialFreeTmp">—</td></tr>' +
			'<tr><th>' + _('Free space in download cache') + '</th><td id="officialFreeCache">—</td></tr></table>' +
			'<div class="stat-s update-hint" id="officialSpaceHint">' + _('The official binary pair uses about 70 MiB after installation. Space requirements include the download, temporary files, and optional rollback backups.') + '</div></div>' +
			'<div class="progress"><i id="dlBar"></i></div>' +
			'<div class="prow"><span id="dlStep">' + _('Ready') + '</span><span id="dlPct"></span></div>' +
			'<div class="btnrow" id="dlCancelRow" style="display:none"><button type="button" class="btn sm" id="dlCancel">' + _('Cancel task') + '</button></div>' +
			'<details class="tasklog" id="dlDet" style="display:none"><summary>' + _('Task log') + '</summary><pre class="log" id="dlLog"></pre></details></div>' +
			'<div id="manualPanel" role="tabpanel" style="display:none"><div class="stat-s setting-desc">' + _('Choose the extracted tailscaled binary to upload.') + '</div>' +
			'<div class="manual-resources"><div class="btnrow artifact-links"><a class="btn sm" id="githubArtifactLink" href="https://github.com/whzhni1/tailscale/releases" target="_blank" rel="noopener noreferrer">' + _('GitHub artifacts') + '</a><a class="btn sm" id="gitlabArtifactLink" href="https://gitlab.com/whzhni/tailscale/-/releases" target="_blank" rel="noopener noreferrer">' + _('GitLab artifacts') + '</a></div>' +
				'<div class="stat-s cached-download"><a id="matchedDownload" href="#" target="_blank" rel="noopener noreferrer" style="display:none"></a><div id="matchedDownloadHash" style="display:none"></div><span id="matchedDownloadState">' + _('Matching device download link is being resolved') + '</span></div></div>' +
				'<div class="field"><label>' + _('Tailscale daemon binary') + '</label><input id="manualFile" class="manual-file-input" type="file" accept="*/*"><div class="stat-s" id="manualFileInfo"></div></div>' +
			'<div class="stat-s update-hint">' + _('The file is staged in RAM, checked, then written over the installed binary before the service restarts.') + '<br>' + _('Keep a LAN session open during restart; a Tailscale-only session will disconnect.') + '<br>' + _('Manual upload does not change the online update channel.') + '</div>' +
			'<div class="btnrow"><button type="button" class="btn primary" id="manualUploadBtn" disabled>' + common.icons.icon('download') + ' <span>' + _('Upload and install') + '</span></button></div>' +
			'<div class="progress"><i id="manualBar"></i></div><div class="prow"><span id="manualStep">' + _('Ready') + '</span><span id="manualPct"></span></div>' +
			'<div class="btnrow" id="manualCancelRow" style="display:none"><button type="button" class="btn sm" id="manualCancelBtn">' + _('Cancel task') + '</button></div>' +
			'<details class="tasklog" id="manualDet" style="display:none"><summary>' + _('Task log') + '</summary><pre class="log" id="manualLog"></pre></details></div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('download') + ' ' + _('LuCI update') + '</h3>' +
			'<table class="tbl"><tr><th>' + _('Installed version') + '</th><td id="luciCurrent">…</td></tr>' +
			'<tr><th>' + _('Latest version') + '</th><td id="luciTag">…</td></tr>' +
			'<tr><th>' + _('File') + '</th><td id="luciFile">…</td></tr>' +
			'<tr><th>' + _('Project repository') + '</th><td><a class="update-project" href="https://github.com/whzhni1/luci-app-tailscale" target="_blank" rel="noopener noreferrer">github.com/whzhni1/luci-app-tailscale</a></td></tr></table>' +
			'<div class="btnrow"><button type="button" class="btn sm" id="luciCheck">' + common.icons.icon('refresh') + ' <span>' + _('Check update') + '</span></button>' +
			'<button type="button" class="btn sm primary" id="luciBtn">' + common.icons.icon('download') + ' <span>' + _('Download and install') + '</span></button></div>' +
			'<div class="progress"><i id="lpBar"></i></div>' +
			'<div class="prow"><span id="lpStep">' + _('Ready') + '</span><span id="lpPct"></span></div>' +
			'<details class="tasklog" id="lpDet" style="display:none"><summary>' + _('Task log') + '</summary><pre class="log" id="lpLog"></pre></details></div>' +
			'<div class="grid g2"><div class="card glass"><h3>' + common.icons.icon('clock') + ' ' + _('Scheduled update') + '</h3>' +
			'<div class="trow"><div class="t"><b>' + _('Enable scheduled update') + '</b></div>' +
			'<label class="switch"><input type="checkbox" id="cronSw"' + (on(Up.auto_update) ? ' checked' : '') + '><span class="sw"></span></label></div>' +
			'<div class="collapse' + (on(Up.auto_update) ? ' open' : '') + '" id="cronFields"><div class="frow">' +
			'<div class="field"><label>' + _('Every X days') + '</label><input id="cronDays" inputmode="numeric" value="' + val(Up.every_days || '7') + '"></div>' +
			'<div class="field"><label>' + _('At time') + '</label><input id="cronAt" type="time" value="' + val(Up.at_time || '03:30') + '"></div></div></div>' +
			'<div class="stat-s space-note" id="cronSpaceHint"></div></div>' +
			'<div class="card glass"><h3>' + common.icons.icon('info') + ' ' + _('Local environment') + '</h3>' +
			'<table class="tbl"><tr><th>' + _('Arch') + '</th><td id="envArch">' + val(st.arch || '—') + '</td></tr>' +
			'<tr><th>' + _('Binary') + '</th><td>' + val((M.bin_dir || '/usr/sbin') + '/tailscaled') + ' ' +
			(st.binary_ok ? '<span class="pill ok">' + _('Ready') + '</span>' : '<span class="pill warn">' + _('Missing') + '</span>') + '</td></tr>' +
			'<tr><th>' + _('Firewall') + '</th><td>' + val(st.fw_driver === 'none' ? _('None') : st.fw_driver || _('None')) + '</td></tr></table>' +
			'</div></div></div>';
		const d = document.createElement('div');
		d.className = 'cbi-map';
		d.innerHTML = common.main.shell('update', body);
		const root = d.querySelector('#app');
		const self = this;
		const q = (id) => root.querySelector(id);
		let coreSrc = null, luciSrc = null, currentFile = '', currentResolveKey = '', archResolveKey = '', archTimer = null, activeTask = null, taskTimer = null, manualUploadRequest = null, taskBusy = false;
		let spaceData = st.disk_spaces || null;
		let coreRequestId = 0, luciRequestId = 0, matchedLinkRequestId = 0, officialOptionRequest = null;
		const coreSourceCache = {}, luciSourceCache = {};
		const SOURCE_TIMEOUT = 10000;
		const withTimeout = (operation, timeout) => new Promise((resolve, reject) => {
			let settled = false;
			const timer = setTimeout(() => { settled = true; reject(new Error('timeout')); }, timeout);
			Promise.resolve().then(operation).then((value) => {
				if (settled) return;
				clearTimeout(timer);
				resolve(value);
			}, (error) => {
				if (settled) return;
				clearTimeout(timer);
				reject(error);
			});
		});
		const orderOf = () => sourceOptions;
		const sourceList = () => (coreSrc && coreSrc.sources) || [];
		const selectedChannel = () => q('#dlChannel').value === 'official' ? 'official' : 'custom';
		const selectedMirror = () => q('#dlSrc').value || orderOf()[0] || '';
		const selectedSource = () => selectedChannel() === 'official' ? 'official' : selectedMirror();
		const updateArtifactLinks = () => {
			q('#githubArtifactLink').style.display = '';
			q('#gitlabArtifactLink').style.display = '';
		};
		const entryFor = () => sourceList().find((x) => x.name === selectedSource()) || { name: selectedSource(), tags: [], files: {} };
		const optionMarkup = (text) => '<option value="">' + common.main.esc(text) + '</option>';
		const formatBytes = (value) => {
			const bytes = Number(value) || 0;
			return bytes > 0 ? (bytes / 1048576).toFixed(1) + ' MiB' : _('Unavailable');
		};
		const spaceIssue = (channel, rollback) => {
			const spaces = spaceData || {};
			const sources = [spaces.install, spaces.temporary];
			if (channel === 'official') sources.push(spaces.cache);
			const values = sources.map((item) => Number(item && item.free_bytes));
			if (values.some((value) => !Number.isFinite(value) || value <= 0))
				return { ok: false, message: _('Free space could not be determined; update is disabled') };
			const free = Math.min(...values);
			if (rollback == null) rollback = q('#rollbackSw').checked;
			const required = (channel === 'official' ? (rollback ? 200 : 130) : (rollback ? 30 : 10)) * 1048576;
			if (free < required)
				return { ok: false, message: _('Device space is insufficient by') + ' ' + Math.ceil((required - free) / 1048576) + ' MiB', free: free, required: required };
			return { ok: true, free: free, required: required };
		};
		const syncSpaceControls = () => {
			const channel = selectedChannel();
			const rollback = q('#rollbackSw').checked;
			const issue = spaceIssue(channel, rollback);
			const rollbackIssue = spaceIssue(channel, true);
			for (const name of ['custom', 'official']) {
				const option = q('#dlChannel').querySelector('option[value="' + name + '"]');
				option.disabled = !spaceIssue(name, rollback).ok;
			}
			q('#rollbackSw').disabled = !rollback && !rollbackIssue.ok;
			q('#channelSpaceHint').textContent = issue.ok ? '' : issue.message;
			q('#dlSpaceHint').textContent = issue.ok ? '' : issue.message;
			q('#channelSpaceHint').classList.toggle('warn', !issue.ok);
			q('#dlSpaceHint').classList.toggle('warn', !issue.ok);
			const enabledFloor = channel === 'official' ? 200 : 30;
			const disabledFloor = channel === 'official' ? 130 : 10;
			let rollbackMessage = rollback ? _('Automatic rollback is enabled; minimum free space:') + ' ' + enabledFloor + ' MiB' : _('Automatic rollback is off; no update backup will be created; minimum free space:') + ' ' + disabledFloor + ' MiB';
			if (!rollbackIssue.ok) rollbackMessage = rollbackIssue.message + ' · ' + (rollback ? _('Turn off automatic rollback to install without backups') : _('Automatic rollback cannot be enabled'));
			q('#rollbackHint').textContent = rollbackMessage;
			q('#rollbackHint').classList.toggle('warn', !rollbackIssue.ok);
			const cronHint = issue.ok ? '' : _('Scheduled updates are unavailable') + ': ' + issue.message;
			q('#cronSpaceHint').textContent = cronHint;
			q('#cronSpaceHint').classList.toggle('warn', !issue.ok);
			q('#dlBtn').disabled = taskBusy || !issue.ok;
		};
		const setOfficialChannelLabel = (info) => {
			const bytes = Number(info && info.download_bytes) || 0;
			const option = q('#dlChannel').querySelector('option[value="official"]');
			option.textContent = _('Official Tailscale') + (bytes > 0 ? ' (' + (bytes / 1048576).toFixed(1) + ' MiB)' : '');
		};
		const setOfficialLabelFromSources = (data) => {
			const list = data && data.sources || [];
			const official = list.find((item) => item.name === 'official');
			if (official) setOfficialChannelLabel(official.info || {});
		};
		const updateMatchedDownload = () => {
			const id = ++matchedLinkRequestId;
			const link = q('#matchedDownload'), hash = q('#matchedDownloadHash'), state = q('#matchedDownloadState');
			link.style.display = 'none';
			hash.style.display = 'none';
			state.textContent = _('Matching device download link is being resolved');
			if (selectedChannel() === 'official') {
				state.textContent = _('A direct archive link is not available for the official channel');
				return;
			}
			const source = selectedMirror(), version = q('#dlVer').value;
			if (!source || !version) {
				state.textContent = _('No matching cached download is available');
				return;
			}
			common.api.resolveFile('tailscale', source, version, 'auto', 'auto').then((result) => {
				if (id !== matchedLinkRequestId || !root.isConnected) return;
				if (!result || !result.ok || !result.url || !result.file) {
					state.textContent = _('No matching cached download is available');
					return;
				}
				let url;
				try { url = new URL(result.url, window.location.href); } catch (e) { url = null; }
				if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) {
					state.textContent = _('No matching cached download is available');
					return;
				}
				link.href = url.href;
				link.textContent = _('Download matching device') + ' · ' + (st.arch || _('Auto')) + ' · ' + result.file;
				link.style.display = '';
				hash.textContent = _('SHA-256') + ': ' + (result.sha256 || _('Unavailable'));
				hash.style.display = '';
				state.textContent = '';
			}).catch(() => {
				if (id === matchedLinkRequestId) state.textContent = _('No matching cached download is available');
			});
		};
		const updateOfficialInfo = (ent) => {
			const info = ent.info || {};
			q('#officialArch').textContent = info.arch || '—';
			q('#officialDownloadSize').textContent = formatBytes(info.download_bytes);
			q('#officialInstalledSize').textContent = formatBytes(info.installed_bytes);
			q('#officialFreeBin').textContent = formatBytes(info.free_bin_bytes);
			q('#officialFreeTmp').textContent = formatBytes(spaceData && spaceData.temporary && spaceData.temporary.free_bytes);
			q('#officialFreeCache').textContent = formatBytes(info.free_cache_bytes);
			q('#officialSpaceHint').classList.toggle('warn', !spaceIssue('official').ok);
		};
		const updateLatest = (message) => {
			const ent = entryFor(), tags = ent.tags || [];
			if (!ent.name || tags.length === 0) {
				q('#newVer').textContent = '—';
				q('#newSub').textContent = message || (ent.name ? _('No versions available') : _('No sources available'));
				q('#dlVer').innerHTML = optionMarkup(_('No versions available'));
				q('#dlFile').innerHTML = optionMarkup(_('No files available'));
				currentFile = '';
				currentResolveKey = '';
				if (selectedChannel() === 'official') updateOfficialInfo({});
				updateMatchedDownload();
				return;
			}
			const latest = tags[0] || '';
			q('#newVer').textContent = latest || '—';
			const check = ent.check || {};
			const versionComparison = ver && latest ? self.cmpVer(ver, latest) : null;
			const updateAvailable = versionComparison != null && versionComparison < 0;
			const updatePill = ver && latest ? (updateAvailable ? ' · ' + _('Update available') : ' · ' + _('Latest already')) : '';
			const layoutNote = check.channel_mismatch === true ? ' · ' + _('Binary layout will switch to the selected channel') : '';
			q('#newSub').textContent = sourceLabel(ent.name) + updatePill + layoutNote;
			if (ent.name === 'official') setOfficialChannelLabel(ent.info || {});
			if (selectedChannel() === 'official') updateOfficialInfo(ent);
			paintVersions();
			updateMatchedDownload();
		};
		const paintFiles = () => {
			const ent = entryFor(), version = q('#dlVer').value;
			const files = (ent.files || {})[version] || [];
			const fileSelect = q('#dlFile');
			const previous = fileSelect.value;
			fileSelect.innerHTML = files.map((x) => '<option value="' + common.main.esc(x) + '">' + common.main.esc(x) + '</option>').join('');
			let chosen = files.includes(previous) ? previous : '';
			if (!chosen && Up.file && Up.file !== 'auto' && files.includes(Up.file)) chosen = Up.file;
			if (!chosen && currentFile && files.includes(currentFile)) chosen = currentFile;
			const arch = q('#dlArch').value.trim().toLowerCase();
			if (!chosen && arch && arch !== 'auto') chosen = files.find((x) => x.toLowerCase().indexOf(arch) >= 0) || '';
			if (!chosen) chosen = files[0] || '';
			fileSelect.value = chosen;
			if (files.length === 0)
				fileSelect.innerHTML = '<option value="">' + _('No files available') + '</option>';
		};
		const chooseFileForArch = () => {
			const files = (entryFor().files || {})[q('#dlVer').value] || [];
			const source = q('#dlSrc').value, version = q('#dlVer').value;
			const rawArch = q('#dlArch').value.trim();
			const arch = rawArch.toLowerCase();
			clearTimeout(archTimer);
			currentResolveKey = '';
			if (!arch || arch === 'auto') {
				archResolveKey = '';
				if (currentFile && files.includes(currentFile)) q('#dlFile').value = currentFile;
				return;
			}
			const direct = files.find((x) => x.toLowerCase().indexOf(arch) >= 0);
			if (direct) {
				archResolveKey = '';
				currentFile = direct;
				q('#dlFile').value = direct;
				return;
			}
			const key = source + '|' + version + '|' + rawArch;
			archResolveKey = key;
			archTimer = setTimeout(() => withTimeout(() => common.api.resolveFile('tailscale', source, version, 'auto', rawArch), SOURCE_TIMEOUT).then((r) => {
				if (archResolveKey !== key || !root.isConnected) return;
				if (r && r.ok && files.includes(r.file)) {
					currentFile = r.file;
					q('#dlFile').value = r.file;
				}
			}).catch(() => {}), 250);
		};
		const resolveCurrentFile = () => {
			const source = q('#dlSrc').value, version = q('#dlVer').value;
			if (selectedChannel() === 'official' || !source || !version) return;
			clearTimeout(archTimer);
			archResolveKey = '';
			const arch = q('#dlArch').value.trim() || 'auto';
			const key = source + '|' + version + '|' + arch;
			currentResolveKey = key;
			withTimeout(() => common.api.resolveFile('tailscale', source, version, 'auto', arch), SOURCE_TIMEOUT).then((r) => {
				if (currentResolveKey !== key || !root.isConnected) return;
				currentFile = r && r.ok ? r.file : '';
				paintFiles();
			}).catch(() => {});
		};
		const cancelFileResolve = () => {
			clearTimeout(archTimer);
			archResolveKey = '';
			currentResolveKey = '';
		};
		const paintVersions = () => {
			const ent = entryFor(), tags = ent.tags || [];
			const versionSelect = q('#dlVer'), previous = versionSelect.value;
			if (tags.length === 0) {
				versionSelect.innerHTML = optionMarkup(_('No versions available'));
				q('#dlFile').innerHTML = optionMarkup(_('No files available'));
				return;
			}
			versionSelect.innerHTML = tags.map((tag, i) => '<option value="' + common.main.esc(tag) + '">' + common.main.esc(tag) + (i === 0 ? ' (' + _('Latest') + ')' : '') + '</option>').join('');
			const wanted = tags.includes(previous) ? previous : Up.version && Up.version !== 'latest' && tags.includes(Up.version) ? Up.version : tags[0] || '';
			versionSelect.value = wanted;
			paintFiles();
			resolveCurrentFile();
		};
		const paintLuci = (message) => {
			const list = (luciSrc && luciSrc.sources) || [];
			q('#luciCurrent').textContent = luciSrc && luciSrc.installed_version || '—';
			if (list.length === 0) {
				q('#luciTag').textContent = message || '—';
				q('#luciFile').textContent = '—';
				return;
			}
			const tags = list[0].tags || [];
			q('#luciTag').textContent = tags[0] || '—';
			const files = (list[0].files || {})[tags[0]] || [];
			q('#luciFile').textContent = files[0] || '—';
		};
		const requestOfficialSource = (force) => {
			if (!force && coreSourceCache.official) return Promise.resolve(coreSourceCache.official);
			if (!force && officialOptionRequest) return officialOptionRequest;
			const request = withTimeout(() => common.api.getSources('tailscale', 'official'), 35000).then((o) => {
				o = o || { sources: [] };
				if (o.sources && o.sources.length > 0) coreSourceCache.official = o;
				setOfficialLabelFromSources(o);
				return o;
			});
			if (!force) {
				officialOptionRequest = request;
				request.then(() => { if (officialOptionRequest === request) officialOptionRequest = null; }, () => { if (officialOptionRequest === request) officialOptionRequest = null; });
			}
			return request;
		};
		const loadOfficialChannelOption = () => requestOfficialSource(false).catch(() => {});
		const loadCoreSource = (source, force) => {
			if (!source) return Promise.resolve();
			const requestId = ++coreRequestId;
			currentFile = '';
			currentResolveKey = '';
			archResolveKey = '';
			clearTimeout(archTimer);
			if (!force && coreSourceCache[source]) {
				coreSrc = coreSourceCache[source];
				updateLatest();
				return Promise.resolve();
			}
			coreSrc = { sources: [] };
			q('#newVer').textContent = '…';
			q('#newSub').textContent = _('Loading versions');
			q('#dlVer').innerHTML = optionMarkup(_('Loading versions'));
			q('#dlFile').innerHTML = optionMarkup(_('Loading files'));
			const request = source === 'official' ? requestOfficialSource(force) : withTimeout(() => common.api.getSources('tailscale', source), SOURCE_TIMEOUT);
			return request.then((o) => {
				o = o || { sources: [] };
				if (o.sources && o.sources.length > 0)
					coreSourceCache[source] = o;
				if (source === 'official') setOfficialLabelFromSources(o);
				if (requestId !== coreRequestId || source !== selectedSource() || !root.isConnected) return;
				coreSrc = o;
				updateLatest();
			}).catch((e) => {
				if (requestId !== coreRequestId || source !== selectedSource() || !root.isConnected) return;
				coreSrc = { sources: [] };
				updateLatest(e && e.message === 'timeout' ? _('Request timed out') : _('Failed to load sources'));
			});
		};
		const loadLuciSource = (source, force) => {
			if (!source) return Promise.resolve();
			const requestId = ++luciRequestId;
			if (!force && luciSourceCache[source]) {
				luciSrc = luciSourceCache[source];
				paintLuci();
				return Promise.resolve();
			}
			luciSrc = { sources: [] };
			q('#luciTag').textContent = _('Loading versions');
			q('#luciFile').textContent = _('Loading files');
			return withTimeout(() => common.api.getSources('luci-app-tailscale', source), SOURCE_TIMEOUT).then((o) => {
				o = o || { sources: [] };
				if (o.sources && o.sources.length > 0)
					luciSourceCache[source] = o;
				if (requestId !== luciRequestId || source !== selectedMirror() || !root.isConnected) return;
				luciSrc = o;
				paintLuci();
			}).catch((e) => {
				if (requestId !== luciRequestId || source !== selectedMirror() || !root.isConnected) return;
				luciSrc = { sources: [] };
				paintLuci(e && e.message === 'timeout' ? _('Request timed out') : _('Failed to load sources'));
			});
		};
		const fillSources = (force) => {
			const source = selectedSource();
			return Promise.all([loadCoreSource(source, force), loadLuciSource(selectedMirror(), force)]);
		};
		const refreshSource = (proj) => {
			const source = proj === 'tailscale' ? selectedSource() : selectedMirror();
			if (proj === 'tailscale') {
				delete coreSourceCache[source];
				coreSrc = { sources: [] };
				q('#newVer').textContent = '…';
				q('#newSub').textContent = _('Loading versions');
				q('#dlVer').innerHTML = optionMarkup(_('Loading versions'));
				q('#dlFile').innerHTML = optionMarkup(_('Loading files'));
				updateMatchedDownload();
			}
			else {
				delete luciSourceCache[source];
				luciSrc = { sources: [] };
				q('#luciTag').textContent = _('Loading versions');
				q('#luciFile').textContent = _('Loading files');
			}
			const timeout = source === 'official' ? 35000 : SOURCE_TIMEOUT;
			return withTimeout(() => common.api.refreshSources(source, proj), timeout).then((r) => {
				if (!r || !r.ok) throw new Error('refresh');
				if (source !== (proj === 'tailscale' ? selectedSource() : selectedMirror())) return;
				return proj === 'tailscale' ? loadCoreSource(source, true) : loadLuciSource(source, true);
			}).catch((e) => {
				if (source !== (proj === 'tailscale' ? selectedSource() : selectedMirror())) return;
				const message = e && e.message === 'timeout' ? _('Request timed out') : _('Failed to load sources');
				if (proj === 'tailscale') updateLatest(message);
				else paintLuci(message);
			});
		};
		saveAction = () => [
			['main', { bin_dir: q('#dlDir').value.trim() }],
			['update', {
				channel: selectedChannel(),
				arch: q('#dlArch').value.trim() || 'auto',
				auto_rollback: q('#rollbackSw').checked ? '1' : '0',
				auto_update: q('#cronSw').checked ? '1' : '0',
				every_days: q('#cronDays').value.trim() || '7',
				at_time: q('#cronAt').value.trim() || '03:30'
			}]
		];
		const taskView = (proj) => proj === 'manual' ? {
			bar: '#manualBar', step: '#manualStep', pct: '#manualPct', detail: '#manualDet', log: '#manualLog', cancel: '#manualCancelRow', button: '#manualUploadBtn', done: _('Tailscale core uploaded')
		} : proj === 'tailscale' ? {
			bar: '#dlBar', step: '#dlStep', pct: '#dlPct', detail: '#dlDet', log: '#dlLog', cancel: '#dlCancelRow', button: '#dlBtn', done: _('Tailscale core updated')
		} : {
			bar: '#lpBar', step: '#lpStep', pct: '#lpPct', detail: '#lpDet', log: '#lpLog', cancel: null, button: '#luciBtn', done: _('LuCI updated')
		};
		const taskStep = (t) => {
			if (t.msg) return t.msg;
			const map = { begin: _('Starting'), upload: _('Uploading'), resolve: _('Resolving'), download: _('Downloading'), verify: _('Verifying'), extract: _('Extracting'), tryrun: _('Testing binary'), stop: _('Stopping'), install: _('Installing'), restart: _('Restarting'), done: _('Completed'), error: _('Failed'), cancelled: _('Cancelled') };
			return map[t.step] || t.step || '';
		};
		const taskError = (code) => {
			const map = { busy: _('Busy, try later'), no_match: _('No matching files'), no_url: _('Download URL not found'), no_hash: _('Checksum unavailable'), fetch_fail: _('Download failed'), hash_mismatch: _('Checksum mismatch'), extract_fail: _('Extraction failed'), tryrun_fail: _('Binary check failed'), install_fail: _('Install failed'), pkg_fail: _('Package installation failed'), restart_warn: _('Restart warning'), official_update_fail: _('Official update failed'), channel_switch_fail: _('Channel switch failed'), version_ahead: _('Installed version is newer than selected channel; automatic downgrade was refused'), unsupported_version: _('Official channel only supports the latest stable version'), core_missing: _('Tailscale CLI is missing'), backup_fail: _('Could not back up binaries'), rolled_back: _('Update failed; previous state restored'), rollback_fail: _('Update failed and rollback failed; backup files were kept'), update_fail_no_rollback: _('Update failed; automatic rollback is disabled'), space_insufficient: _('Insufficient free space for this update'), invalid_upload: _('Choose the extracted tailscaled binary'), tmpfs_unavailable: _('RAM temporary storage is unavailable'), memory_low: _('Not enough RAM space for this upload'), upload_too_large: _('File exceeds the 32 MiB upload limit'), bad_chunk: _('Upload chunk failed'), upload_incomplete: _('Upload is incomplete'), service_stop_fail: _('Could not stop Tailscale before replacing the binary'), restart_fail: _('Tailscale failed to restart'), cancelled: _('Cancelled') };
			return map[code] || code || _('Unknown error');
		};
		const updateInstalledVersion = (t) => {
			if (t.proj === 'tailscale') {
				if (t.installed_version) q('#curVer').textContent = t.installed_version;
				common.api.getStatus(true).then((cur) => {
					if (cur && cur.disk_spaces) spaceData = cur.disk_spaces;
					if (cur && cur.version) q('#curVer').textContent = ('' + cur.version).split(/[ \n]/)[0];
					if (cur && cur.arch) {
						q('#curArch').textContent = cur.arch;
						q('#envArch').textContent = cur.arch;
					}
					syncSpaceControls();
					common.main.badges(root);
				}).catch(() => common.main.badges(root));
			}
			else if (t.proj === 'luci-app-tailscale') {
				q('#luciCurrent').textContent = t.installed_version || q('#luciTag').textContent;
				if (luciSrc) luciSrc.installed_version = t.installed_version || luciSrc.installed_version;
			}
		};
		const finishTask = (t, task) => {
			if (!activeTask || activeTask.finished) return;
			activeTask.finished = true;
			if (taskTimer) {
				clearInterval(taskTimer);
				taskTimer = null;
			}
			activeTask = null;
			taskBusy = false;
			syncSpaceControls();
			q('#luciBtn').disabled = false;
			q('#manualFile').disabled = false;
			if (task.cancel) q(task.cancel).style.display = 'none';
			const selectedManualFile = q('#manualFile').files[0];
			q('#manualUploadBtn').disabled = !selectedManualFile || selectedManualFile.name !== 'tailscaled' || selectedManualFile.size < 1 || selectedManualFile.size > 33554432;
			const cancelled = t.error === 'cancelled';
			const failed = !!t.error && !cancelled;
			const result = cancelled ? _('Cancelled') : failed ? _('Failed') + ' · ' + taskError(t.error) : task.done;
			q(task.step).textContent = result;
			if (!failed) updateInstalledVersion(t);
			else common.api.getStatus(true).then((cur) => { if (cur && cur.disk_spaces) spaceData = cur.disk_spaces; syncSpaceControls(); }).catch(() => {});
		};
		const pollTask = (id, task) => {
			if (!root.isConnected || !activeTask || activeTask.id !== id || activeTask.finished) return;
			common.api.progress(id).then((t) => {
				t = t || {};
				const transportUploading = activeTask && activeTask.manualUpload && activeTask.transportUploading && t.step === 'upload';
				if (!transportUploading) {
					const progress = Math.max(0, Math.min(100, +t.percent || 0));
					q(task.bar).style.width = progress + '%';
					q(task.pct).textContent = Math.floor(progress) + '%';
					q(task.step).textContent = taskStep(t);
				}
				if (activeTask && activeTask.manualUpload && t.step !== 'upload') q('#manualCancelRow').style.display = 'none';
				if (t.log != null) {
					const el = q(task.log);
					el.textContent = t.log;
					el.scrollTop = el.scrollHeight;
				}
				if (t.done) finishTask(t, task);
			}).catch(() => {});
		};
		const startTask = (proj, source, version, file, arch) => {
			if (activeTask) return;
			const task = taskView(proj);
			q(task.detail).style.display = '';
			q(task.detail).open = true;
			q(task.log).textContent = '';
			q(task.bar).style.width = '0%';
			q(task.pct).textContent = '0%';
			q(task.step).textContent = _('Starting');
			taskBusy = true;
			q('#dlBtn').disabled = true;
			q('#luciBtn').disabled = true;
			q('#manualUploadBtn').disabled = true;
			common.api.download(proj, source, version, file, arch).then((r) => {
				if (!r || !r.task_id) throw new Error('task');
				activeTask = { id: r.task_id, proj: proj, finished: false };
				if (task.cancel) q(task.cancel).style.display = '';
				taskTimer = setInterval(() => pollTask(r.task_id, task), 1000);
				pollTask(r.task_id, task);
			}).catch(() => {
				taskBusy = false;
				syncSpaceControls();
				q('#luciBtn').disabled = false;
				const selectedManualFile = q('#manualFile').files[0];
				q('#manualUploadBtn').disabled = !selectedManualFile || selectedManualFile.name !== 'tailscaled' || selectedManualFile.size < 1 || selectedManualFile.size > 33554432;
				q(task.step).textContent = _('Failed to start task');
			});
		};
		const uploadRawFile = (path, file, onProgress) => new Promise((resolve, reject) => {
			const form = new FormData();
			form.append('sessionid', rpc.getSessionID());
			form.append('filename', path);
			form.append('filedata', file);
			const xhr = new XMLHttpRequest();
			manualUploadRequest = xhr;
			const settle = (fn, value) => {
				if (manualUploadRequest === xhr) manualUploadRequest = null;
				fn(value);
			};
			xhr.upload.addEventListener('progress', onProgress);
			xhr.addEventListener('load', () => {
				let reply = null;
				try { reply = JSON.parse(xhr.responseText); } catch (e) {}
				if (xhr.status < 200 || xhr.status >= 300 || reply == null || reply.failure) {
					const failure = reply && reply.failure;
					const detail = Array.isArray(failure) ? failure[1] : failure;
					settle(reject, new Error(detail || reply && reply.message || 'HTTP ' + xhr.status));
					return;
				}
				settle(resolve, reply);
			});
			xhr.addEventListener('error', () => settle(reject, new Error('Upload network error')));
			xhr.addEventListener('abort', () => settle(reject, new Error('cancelled')));
			xhr.open('POST', `${L.env.cgi_base}/cgi-upload`, true);
			xhr.send(form);
		});
		const uploadManualFile = async () => {
			if (taskBusy || activeTask) return;
			const file = q('#manualFile').files[0];
			if (!file) return;
			if (file.name !== 'tailscaled') {
				q('#manualStep').textContent = taskError('invalid_upload');
				return;
			}
			if (!file.size) {
				q('#manualStep').textContent = taskError('invalid_upload');
				return;
			}
			if (file.size > 33554432) {
				q('#manualStep').textContent = taskError('upload_too_large');
				return;
			}
			const task = taskView('manual');
			let id = '', uploadTask = null;
			q(task.detail).style.display = '';
			q(task.detail).open = true;
			q(task.log).textContent = '';
			q(task.bar).style.width = '0%';
			q(task.pct).textContent = '0%';
			q(task.step).textContent = _('Starting');
			taskBusy = true;
			q('#manualFile').disabled = true;
			q('#manualUploadBtn').disabled = true;
			q('#dlBtn').disabled = true;
			q('#luciBtn').disabled = true;
			try {
				const begun = await common.api.beginManualUpload(file.name, file.size);
				if (!begun || !begun.ok || !begun.task_id) throw new Error(begun && begun.error || 'upload_incomplete');
				id = begun.task_id;
				if (!begun.upload_path) throw new Error('upload_incomplete');
				uploadTask = { id: id, proj: 'tailscale', manualUpload: true, transportUploading: true, cancelRequested: false, finished: false };
				activeTask = uploadTask;
				q(task.cancel).style.display = '';
				taskTimer = setInterval(() => pollTask(id, task), 1000);
				const uploadReply = await uploadRawFile(begun.upload_path, file, (event) => {
					if (!event.lengthComputable) return;
					const sent = Math.min(file.size, event.loaded);
					const pct = Math.max(0, Math.min(70, Math.floor(event.loaded * 70 / event.total)));
					q(task.bar).style.width = pct + '%';
					q(task.pct).textContent = pct + '%';
					q(task.step).textContent = _('Uploading') + ' · ' + common.main.fmtBytes(sent) + ' / ' + common.main.fmtBytes(file.size);
				});
				uploadTask.cgiSize = Number(uploadReply && uploadReply.size);
				if (!Number.isFinite(uploadTask.cgiSize)) throw new Error('CGI response missing file size');
				if (uploadTask.cgiSize !== file.size) throw new Error('CGI file size mismatch · ' + common.main.fmtBytes(uploadTask.cgiSize) + ' / ' + common.main.fmtBytes(file.size));
				if (uploadTask.cancelRequested) return;
				q(task.step).textContent = _('Verifying');
				q(task.cancel).style.display = 'none';
				const finished = await common.api.finishManualUpload(id);
				if (!finished || !finished.ok) {
					if (finished && finished.error === 'upload_incomplete') {
						const received = Number(finished.received_bytes);
						const expected = Number(finished.expected_bytes);
						const got = received >= 0 ? common.main.fmtBytes(received) : 'missing';
						const want = expected >= 0 ? common.main.fmtBytes(expected) : 'unknown';
						const cgi = Number.isFinite(uploadTask.cgiSize) ? common.main.fmtBytes(uploadTask.cgiSize) : 'unknown';
						throw new Error(taskError('upload_incomplete') + ' · ' + got + ' / ' + want + ' · ' + (finished.reason || 'unknown') + ' · CGI ' + cgi);
					}
					throw new Error(finished && finished.error || 'install_fail');
				}
				uploadTask.transportUploading = false;
				pollTask(id, task);
			}
			catch (e) {
				if (uploadTask && uploadTask.cancelRequested) return;
				if (id) {
					if (taskTimer) { clearInterval(taskTimer); taskTimer = null; }
					if (activeTask && activeTask.id === id) activeTask = null;
					common.api.cancelTask(id).catch(() => {});
				}
				taskBusy = false;
				syncSpaceControls();
				q('#luciBtn').disabled = false;
				q('#manualFile').disabled = false;
				const selectedManualFile = q('#manualFile').files[0];
				q('#manualUploadBtn').disabled = !selectedManualFile || selectedManualFile.name !== 'tailscaled' || selectedManualFile.size < 1 || selectedManualFile.size > 33554432;
				const message = taskError(e && e.message || 'upload_incomplete');
				q(task.step).textContent = _('Failed') + ' · ' + message;
			}
		};
		setTimeout(() => {
			if (!root.isConnected)
				return;
			common.main.wire('update', root, null);
			common.login.init(root);
			const showUpdateTab = (manual) => {
				q('#onlinePanel').style.display = manual ? 'none' : '';
				q('#manualPanel').style.display = manual ? '' : 'none';
				q('#onlineTab').classList.toggle('on', !manual);
				q('#manualTab').classList.toggle('on', manual);
				q('#onlineTab').setAttribute('aria-selected', manual ? 'false' : 'true');
				q('#manualTab').setAttribute('aria-selected', manual ? 'true' : 'false');
			};
			q('#onlineTab').addEventListener('click', () => showUpdateTab(false));
			q('#manualTab').addEventListener('click', () => showUpdateTab(true));
			q('#manualFile').addEventListener('change', () => {
				const file = q('#manualFile').files[0];
				if (!file) {
					q('#manualFileInfo').textContent = '';
					q('#manualUploadBtn').disabled = true;
					return;
				}
				q('#manualFileInfo').textContent = file.name + ' · ' + common.main.fmtBytes(file.size);
				q('#manualUploadBtn').disabled = taskBusy || file.name !== 'tailscaled' || file.size < 1 || file.size > 33554432;
			});
			q('#manualUploadBtn').addEventListener('click', uploadManualFile);
			q('#manualCancelBtn').addEventListener('click', () => {
				if (!activeTask || !activeTask.manualUpload) return;
				activeTask.cancelRequested = true;
				if (manualUploadRequest) manualUploadRequest.abort();
				common.api.cancelTask(activeTask.id).catch(() => {});
			});
			const syncChannelView = () => {
				const official = selectedChannel() === 'official';
				q('#customFields').style.display = official ? 'none' : '';
				q('#officialInfo').style.display = official ? '' : 'none';
				updateArtifactLinks();
				syncSpaceControls();
				updateMatchedDownload();
			};
			syncChannelView();
			q('#dlChannel').addEventListener('change', () => {
				syncChannelView();
				loadCoreSource(selectedSource());
				loadLuciSource(selectedMirror());
			});
			q('#rollbackSw').addEventListener('change', (e) => {
				if (e.target.checked && !spaceIssue(selectedChannel(), true).ok) e.target.checked = false;
				syncSpaceControls();
			});
			q('#dlSrc').addEventListener('change', () => {
				updateArtifactLinks();
				updateMatchedDownload();
				loadCoreSource(selectedSource());
				loadLuciSource(selectedMirror());
			});
			q('#dlVer').addEventListener('change', () => { paintFiles(); resolveCurrentFile(); updateMatchedDownload(); });
			q('#dlFile').addEventListener('pointerdown', cancelFileResolve);
			q('#dlFile').addEventListener('keydown', cancelFileResolve);
			q('#dlFile').addEventListener('change', () => {
				cancelFileResolve();
				currentFile = q('#dlFile').value;
			});
			q('#dlArch').addEventListener('input', chooseFileForArch);
			q('#checkBtn').addEventListener('click', () => refreshSource('tailscale'));
			q('#luciCheck').addEventListener('click', () => refreshSource('luci-app-tailscale'));
			q('#dlBtn').addEventListener('click', () => {
				const channel = selectedChannel();
				if (!spaceIssue(channel).ok) {
					syncSpaceControls();
					return;
				}
				const official = channel === 'official';
				const ent = entryFor();
				const source = official ? 'official' : ent.name;
				const version = q('#dlVer').value;
				const file = official ? 'auto' : q('#dlFile').value;
				const arch = official ? 'auto' : q('#dlArch').value.trim() || 'auto';
				if (!source || !version || (!official && !file)) {
					q('#dlStep').textContent = _('No files available');
					return;
				}
				common.api.setConfig('main', { bin_dir: q('#dlDir').value.trim() }).then((saved) => {
					if (!saved || saved.ok === false) throw new Error('save');
					return common.api.setConfig('update', { channel: channel, arch: arch, auto_rollback: q('#rollbackSw').checked ? '1' : '0' });
				}).then((saved) => {
					if (!saved || saved.ok === false) throw new Error('save');
					startTask('tailscale', source, version, file, arch);
				}).catch(() => { q('#dlStep').textContent = _('Failed to save'); });
			});
			q('#dlCancel').addEventListener('click', () => {
				if (!activeTask || activeTask.proj !== 'tailscale') return;
				common.api.cancelTask(activeTask.id).then(() => {}).catch(() => {});
			});
			q('#luciBtn').addEventListener('click', () => startTask('luci-app-tailscale', 'auto', 'latest', 'auto', 'auto'));
			q('#cronSw').addEventListener('change', (e) => {
				if (e.target.checked && !spaceIssue(selectedChannel()).ok) {
					e.target.checked = false;
				}
				q('#cronFields').classList.toggle('open', e.target.checked);
				syncSpaceControls();
			});
			fillSources();
			if (selectedChannel() !== 'official') loadOfficialChannelOption();
		}, 0);
		return d;
	}
});
