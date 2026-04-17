// Ratbat web player.
//
// Polls /now.json every few seconds, lets the user pick a station, and
// streams its AAC feed via a plain <audio> element. The stream URL itself
// is returned by the server in /now.json — we never hard-code slugs.
//
// State is deliberately flat; there's no framework. DOM references are
// looked up once on load and mutated in place on each refresh tick.

const state = {
    stations: [],
    activeStationId: null,
    isPlaying: false,
};

const $list = document.getElementById('station-list');
const $playerSection = document.getElementById('player-section');
const $audio = document.getElementById('audio');
const $playPause = document.getElementById('play-pause');
const $volume = document.getElementById('volume');
const $title = document.getElementById('track-title');
const $artist = document.getElementById('track-artist');
const $album = document.getElementById('track-album');
const $stationName = document.getElementById('active-station-name');

async function refresh() {
    try {
        const res = await fetch('/now.json', { cache: 'no-store' });
        const data = await res.json();
        state.stations = data.stations || [];
        renderStations();
        syncActiveTrack();
    } catch (err) {
        $list.innerHTML = '<div class="empty">Can\'t reach the server. Retrying…</div>';
    }
}

function renderStations() {
    if (!state.stations.length) {
        $list.innerHTML = '<div class="empty">No stations broadcasting right now.</div>';
        return;
    }
    $list.innerHTML = state.stations.map(s => `
        <div class="station ${state.activeStationId === s.id ? 'active' : ''}"
             data-station-id="${escapeHtml(s.id)}"
             data-stream-url="${escapeHtml(s.streamURL || '')}"
             data-name="${escapeHtml(s.name)}">
            <div class="dot"></div>
            <span class="name">${escapeHtml(s.name)}</span>
            <span class="listeners">${s.listeners} ${s.listeners === 1 ? 'listener' : 'listeners'}</span>
            <span class="play-icon">▶</span>
        </div>
    `).join('');

    $list.querySelectorAll('.station').forEach(el => {
        el.addEventListener('click', () => selectStation(el.dataset.stationId, el.dataset.streamUrl, el.dataset.name));
    });
}

function selectStation(id, streamURL, name) {
    if (state.activeStationId === id && !$audio.paused) {
        pause();
        return;
    }
    state.activeStationId = id;
    $stationName.textContent = name;
    $audio.src = streamURL;
    $audio.play().then(() => {
        state.isPlaying = true;
        $playPause.textContent = '⏸';
        $playerSection.hidden = false;
        document.querySelectorAll('.station').forEach(el => {
            el.classList.toggle('active', el.dataset.stationId === id);
        });
    }).catch(err => console.warn('play failed', err));
    syncActiveTrack();
}

function syncActiveTrack() {
    if (!state.activeStationId) return;
    const active = state.stations.find(s => s.id === state.activeStationId);
    if (!active) {
        $title.textContent = '—';
        $artist.textContent = 'Station went offline';
        $album.textContent = '';
        return;
    }
    const t = active.currentTrack;
    if (t) {
        $title.textContent = t.title;
        $artist.textContent = t.artist;
        $album.textContent = t.album || '';
    } else {
        $title.textContent = 'Live';
        $artist.textContent = active.name;
        $album.textContent = '';
    }
}

function pause() {
    $audio.pause();
    state.isPlaying = false;
    $playPause.textContent = '▶';
}

$playPause.addEventListener('click', () => {
    if (state.isPlaying) pause();
    else if (state.activeStationId) $audio.play().then(() => {
        state.isPlaying = true;
        $playPause.textContent = '⏸';
    });
});

$volume.addEventListener('input', e => {
    $audio.volume = e.target.value / 100;
});
$audio.volume = 0.8;

function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
}

refresh();
setInterval(refresh, 3000);
