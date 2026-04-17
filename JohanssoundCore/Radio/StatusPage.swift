import Foundation

/// Static HTML for the public status page served at `GET /`.
///
/// The page polls `/now.json` every 2 seconds and renders the currently
/// broadcasting stations with their now-playing track. It's intentionally
/// a single self-contained HTML blob (inline CSS + JS, no external assets)
/// so the broadcaster doesn't need to serve any additional resources — one
/// string, one response.
///
/// Visual language leans dark-mode neutral with a warm amber accent to
/// match the rest of the Johanssound Mac app.
enum StatusPage {
    static let html: String = """
    <!doctype html>
    <html lang="en">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Johanssound — Live Stations</title>
        <style>
            :root {
                color-scheme: dark;
                --bg: #0a0a0a;
                --fg: #e8e8e8;
                --dim: #888;
                --accent: #f0b820;
                --card: #161616;
                --border: #2a2a2a;
            }
            * { box-sizing: border-box; }
            body {
                margin: 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                background: var(--bg); color: var(--fg); padding: 40px 20px; line-height: 1.5;
            }
            .container { max-width: 720px; margin: 0 auto; }
            h1 {
                font-size: 28px; margin: 0 0 8px; letter-spacing: -0.02em;
            }
            .subtitle { color: var(--dim); margin-bottom: 32px; font-size: 14px; }
            .station {
                background: var(--card); border: 1px solid var(--border);
                border-radius: 8px; padding: 20px; margin-bottom: 16px;
                transition: border-color 0.2s;
            }
            .station.live { border-color: var(--accent); }
            .station-header {
                display: flex; align-items: center; gap: 10px;
                margin-bottom: 12px;
            }
            .live-dot {
                width: 8px; height: 8px; border-radius: 50%;
                background: var(--accent); animation: pulse 2s infinite;
            }
            @keyframes pulse {
                0%, 100% { opacity: 1; }
                50% { opacity: 0.4; }
            }
            .station-name { font-size: 18px; font-weight: 600; flex: 1; }
            .listener-count { color: var(--dim); font-size: 13px; }
            .now-playing {
                color: var(--fg); font-size: 15px;
                padding: 10px 12px; background: rgba(255,255,255,0.03);
                border-radius: 6px; margin: 8px 0;
            }
            .now-playing .label {
                font-size: 11px; text-transform: uppercase;
                color: var(--dim); letter-spacing: 0.1em; display: block;
                margin-bottom: 4px;
            }
            .listen-btn {
                display: inline-block; margin-top: 10px;
                padding: 8px 14px; background: var(--accent); color: #000;
                text-decoration: none; border-radius: 6px; font-weight: 600;
                font-size: 14px;
            }
            .listen-btn:hover { opacity: 0.85; }
            .no-stations { color: var(--dim); padding: 40px; text-align: center; }
            footer {
                margin-top: 40px; text-align: center; color: var(--dim);
                font-size: 12px;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Johanssound</h1>
            <p class="subtitle">Personal radio. <span id="status">Loading…</span></p>
            <div id="stations"></div>
            <footer>Refreshes every 2 seconds.</footer>
        </div>
        <script>
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
        </script>
    </body>
    </html>
    """
}
