/*
 * Linux-Log-Monitor :: shared data source.
 *
 * Reads the journal ring buffer kept in tmpfs by the resident `--serve`
 * collector (the systemd --user service), fully IN-PROCESS via XMLHttpRequest
 * (file://) -- no process is spawned per poll. Requires QML_XHR_ALLOW_FILE_READ=1
 * in the Plasma session (set by install.sh). No fallback: if the read can't
 * happen (service down / flag unset) the widget simply shows no data.
 */
import QtQuick
import org.kde.plasma.plasma5support as P5Support

Item {
    id: root

    property int interval: 1000
    property bool paused: false           // when paused, stop reading the file

    property var lines: []                // newest-last array of log records
    property double ts: 0                 // wall clock of the collector's last write
    property bool online: false           // collector alive and fresh
    property bool ready: false
    signal updated()

    property string cachePath: ""

    // one-shot: resolve the runtime cache path (cheap shell echo), then poll via XHR
    P5Support.DataSource {
        id: helper
        engine: "executable"
        onNewData: function(source, d) {
            root.cachePath = (d.stdout || "").trim()
            root.read()
            disconnectSource(source)
        }
    }

    function read() {
        if (!root.cachePath || root.paused)
            return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + root.cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (!xhr.responseText) {
                root.online = false      // no data -> show nothing (no fallback)
                return
            }
            try {
                var parsed = JSON.parse(xhr.responseText)
                root.ts = parsed.ts || 0
                // alive AND fresh: a dead collector leaves a stale `ts` behind
                root.online = parsed.alive !== false
                    && (Date.now() / 1000 - root.ts) < 15
                root.lines = parsed.lines || []
                root.ready = true
                root.updated()
            } catch (e) {}
        }
        xhr.send()
    }

    Timer {
        interval: root.interval
        repeat: true
        running: root.cachePath !== "" && !root.paused
        onTriggered: root.read()
    }

    Component.onCompleted: helper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Log-Monitor/log.json\"")
}
