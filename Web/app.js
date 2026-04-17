async function refresh() {
    try {
        const res = await fetch('/now.json', { cache: 'no-store' });
        const data = await res.json();
        render(data);
        document.getElementById('status').textContent =
            `${data.stations.length} station${data.stations.length === 1 ? '' : 's'} live.`;
    } catch (e) {
        document.getElementById('status').textContent = 'Connection lost.';
    }
}
function render(data) {
    const el = document.getElementById('stations');
    if (!data.stations.length) {
        el.innerHTML = '<div class="no-stations">No stations currently broadcasting.</div>';
        return;
    }
    el.innerHTML = data.stations.map(s => `
        <div class="station ${s.broadcasting ? 'live' : ''}">
            <div class="station-header">
                ${s.broadcasting ? '<div class="live-dot"></div>' : ''}
                <span class="station-name">${escapeHtml(s.name)}</span>
                <span class="listener-count">${s.listeners} listener${s.listeners === 1 ? '' : 's'}</span>
            </div>
            ${s.currentTrack ? `
                <div class="now-playing">
                    <span class="label">Now Playing</span>
                    <strong>${escapeHtml(s.currentTrack.title)}</strong>
                    <br><span style="color: var(--dim);">${escapeHtml(s.currentTrack.artist)}</span>
                </div>
            ` : ''}
            <a class="listen-btn" href="${s.streamURL}">▶ Listen</a>
        </div>
    `).join('');
}
function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
}
refresh();
setInterval(refresh, 2000);
