pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import Quickshell
import QtQuick
import QtMultimedia
import Quickshell.Io

Singleton {
    id: root

    readonly property string serverUrl: (Config.options?.music?.serverUrl ?? "").replace(/\/+$/, "")
    readonly property string backendUrl: serverUrl + "/backend"
    readonly property string apiKey: Config.options?.music?.apiKey ?? ""
    readonly property bool canControl: root.apiKey !== ""

    property bool connected: false
    property string serverStatus: "stopped"
    property bool serverPlaying: serverStatus === "playing"
    property var currentTrack: null
    property var queue: []
    property real duration: 0

    property real syncedPosition: 0
    property double lastSyncMs: 0
    property real position: 0
    property double lastDataMs: 0

    property real volume: 0.8
    property bool userPlaying: false
    property bool switching: false
    readonly property bool localPlaying: mediaPlayer.playbackState === MediaPlayer.PlayingState

    property var cachedIds: []
    readonly property int cacheMax: 4

    function trackFile(id) {
        return "/tmp/miu-cache-" + id + ".m4a";
    }

    function isCached(id) {
        return id && root.cachedIds.indexOf(id) !== -1;
    }

    function markCached(id) {
        let order = root.cachedIds.filter(x => x !== id);
        order.push(id);
        while (order.length > root.cacheMax) {
            const old = order.shift();
            if (old !== (root.currentTrack ? root.currentTrack.youtubeId : "")) {
                rmProc.command = ["rm", "-f", root.trackFile(old)];
                rmProc.running = true;
            }
        }
        root.cachedIds = order;
    }

    function fetchScript(id) {
        const b = root.backendUrl;
        const f = root.trackFile(id);
        return "T=$(curl -sS --http1.1 --max-time 20 '" + b + "/api/music/secure-token/" + id
            + "' | sed -n 's/.*\"token\":\"\\([^\"]*\\)\".*/\\1/p'); "
            + "[ -n \"$T\" ] || exit 1; "
            + "curl -sS --http1.1 --max-time 120 -o '" + f + "' '" + b + "/api/music/secure-stream/'\"$T\"";
    }

    function playFile(file) {
        mediaPlayer.stop();
        mediaPlayer.source = "file://" + file;
        mediaPlayer.play();
    }

    function playCurrent() {
        const id = root.currentTrack ? (root.currentTrack.youtubeId ?? "") : "";
        if (id === "")
            return;
        if (root.isCached(id)) {
            root.markCached(id);
            root.playFile(root.trackFile(id));
        } else {
            dlProc.startFor(id);
        }
    }

    function prefetchNext() {
        if (!root.userPlaying)
            return;
        const nid = (root.queue && root.queue.length > 0) ? (root.queue[0].youtubeId ?? "") : "";
        if (nid !== "" && !root.isCached(nid) && !prefetchProc.running && prefetchProc.dlId !== nid)
            prefetchProc.startFor(nid);
    }

    function playAlong() {
        root.userPlaying = true;
        root.switching = true;
        root.playCurrent();
        root.prefetchNext();
        switchGuardTimer.restart();
    }

    function advance() {
        root.switching = true;
        root.playCurrent();
        root.prefetchNext();
        switchGuardTimer.restart();
    }

    function recoverPlayback() {
        const id = root.currentTrack ? (root.currentTrack.youtubeId ?? "") : "";
        if (id === "")
            return;
        root.switching = true;
        dlProc.startFor(id);
        switchGuardTimer.restart();
    }

    function stopAlong() {
        root.userPlaying = false;
        dlProc.running = false;
        mediaPlayer.stop();
    }

    function toggleAlong() {
        if (root.userPlaying)
            root.stopAlong();
        else
            root.playAlong();
    }

    function setVolume(value) {
        root.volume = Math.max(0, Math.min(1, value));
        audioOutput.volume = root.volume;
    }

    function controlScript(path) {
        return "curl -sS --http1.1 --max-time 15 -o /dev/null -X POST '" + root.backendUrl + path
            + "' -H 'Authorization: Bearer " + root.apiKey + "'"
            + " -H 'Content-Type: application/json' -d '{}'";
    }

    function skip() {
        if (!root.canControl)
            return;
        skipProc.command = ["bash", "-c", root.controlScript("/api/music/skip")];
        skipProc.running = true;
    }

    function ban() {
        if (!root.canControl)
            return;
        banProc.command = ["bash", "-c", root.controlScript("/api/music/ban")];
        banProc.running = true;
    }

    function reconnect() {
        root.connected = false;
        sseProc.running = false;
        reconnectTimer.restart();
    }

    function applyState(payload) {
        let data;
        try {
            data = JSON.parse(payload);
        } catch (e) {
            return;
        }
        if (data.status === undefined && data.currentTrack === undefined && data.position === undefined)
            return;

        root.connected = true;

        if (typeof data.status === "string")
            root.serverStatus = data.status;

        if ("currentTrack" in data) {
            const t = data.currentTrack;
            const newId = t ? (t.youtubeId ?? "") : "";
            const oldId = root.currentTrack ? (root.currentTrack.youtubeId ?? "") : "";
            root.currentTrack = t ?? null;
            root.duration = t ? (t.duration ?? 0) : 0;
            if (newId !== oldId && newId !== "" && root.userPlaying)
                advanceTimer.restart();
        }

        if (data.queue !== undefined) {
            root.queue = data.queue;
            root.prefetchNext();
        }

        if (typeof data.position === "number") {
            root.syncedPosition = data.position;
            root.lastSyncMs = Date.now();
            root.position = Math.min(data.position, root.duration || data.position);
        }
    }

    Timer {
        running: root.serverPlaying && root.currentTrack !== null
        interval: 1000
        repeat: true
        onTriggered: {
            const elapsed = (Date.now() - root.lastSyncMs) / 1000;
            const next = root.syncedPosition + elapsed;
            root.position = root.duration > 0 ? Math.min(next, root.duration) : next;
        }
    }

    Timer {
        id: advanceTimer
        interval: 300
        repeat: false
        onTriggered: root.advance()
    }

    Timer { // Staleness watchdog: mark disconnected + reconnect if the stream truly dies
        interval: 15000
        repeat: true
        running: true
        onTriggered: {
            if (root.lastDataMs > 0 && (Date.now() - root.lastDataMs) > 70000)
                root.reconnect();
        }
    }

    Timer { // Periodic graceful refresh so the track never stays stale (no status flash)
        interval: 45000
        repeat: true
        running: true
        onTriggered: sseProc.running = false
    }

    Process {
        id: sseProc
        running: true
        command: ["bash", "-c", "exec stdbuf -oL curl -sS --http1.1 -N -H 'Accept: text/event-stream' '"
            + root.backendUrl + "/api/music/state/live'"]

        stdout: SplitParser {
            onRead: rawLine => {
                root.lastDataMs = Date.now();
                const line = rawLine.replace(/\r$/, "");
                if (line.startsWith("data:")) {
                    const payload = line.slice(5).replace(/^ /, "");
                    if (payload.length > 2)
                        root.applyState(payload);
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            reconnectTimer.restart();
        }
    }

    Timer {
        id: reconnectTimer
        interval: 1000
        repeat: false
        onTriggered: sseProc.running = true
    }

    Timer {
        id: switchGuardTimer
        interval: 1500
        repeat: false
        onTriggered: root.switching = false
    }

    Process { id: rmProc }
    Process { id: skipProc }
    Process { id: banProc }

    Timer {
        id: dlRestartTimer
        interval: 120
        repeat: false
        onTriggered: dlProc.begin()
    }

    Process { // Downloads the CURRENT track then plays it
        id: dlProc
        property string dlId: ""
        function startFor(id) {
            dlProc.dlId = id;
            if (dlProc.running) {
                dlProc.running = false;
                dlRestartTimer.restart();
            } else {
                dlProc.begin();
            }
        }
        function begin() {
            dlProc.command = ["bash", "-c", root.fetchScript(dlProc.dlId)];
            dlProc.running = true;
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && dlProc.dlId !== "") {
                root.markCached(dlProc.dlId);
                if (root.userPlaying && root.currentTrack && (root.currentTrack.youtubeId ?? "") === dlProc.dlId)
                    root.playFile(root.trackFile(dlProc.dlId));
            }
        }
    }

    Process { // Prefetches the NEXT queued track into the cache
        id: prefetchProc
        property string dlId: ""
        function startFor(id) {
            prefetchProc.dlId = id;
            prefetchProc.command = ["bash", "-c", root.fetchScript(id)];
            prefetchProc.running = true;
        }
        onExited: (exitCode, exitStatus) => {
            const ok = exitCode === 0 && prefetchProc.dlId !== "";
            if (ok)
                root.markCached(prefetchProc.dlId);
            prefetchProc.dlId = "";
            if (ok)
                root.prefetchNext();
        }
    }

    Timer {
        id: recoverTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (root.userPlaying)
                root.recoverPlayback();
        }
    }

    MediaPlayer {
        id: mediaPlayer
        audioOutput: AudioOutput {
            id: audioOutput
            volume: root.volume
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.BufferedMedia && seekable && root.position > 0.5) {
                position = root.position * 1000;
            } else if (mediaStatus === MediaPlayer.EndOfMedia && root.userPlaying && !root.switching) {
                const posSec = position / 1000;
                if (root.duration > 0 && posSec < root.duration - 5)
                    recoverTimer.restart();
            }
        }
        onErrorOccurred: (error, errorString) => {
            if (root.userPlaying && !root.switching)
                recoverTimer.restart();
        }
    }
}
