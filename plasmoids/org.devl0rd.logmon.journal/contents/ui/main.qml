/*
 * Linux-Log-Monitor :: System Log widget
 * Live, colour-coded view of the systemd journal (kernel + every service/app),
 * with a severity filter, full-journal search, smart follow and click-to-expand.
 *
 * Two data modes, same look:
 *   - live tail : reads the tmpfs ring buffer the resident collector keeps fresh.
 *   - search    : runs `journalctl -g` over the WHOLE on-disk journal and shows
 *                 the matches; clearing the box returns to the live tail.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import "lib"

PlasmoidItem {
    id: root

    readonly property color accent: Plasmoid.configuration.accentColor !== ""
        ? Plasmoid.configuration.accentColor : Kirigami.Theme.highlightColor

    // severity filter: combo index -> max journal priority kept (lower = worse)
    readonly property var levelMax: [7, 6, 4, 3]      // All, Info, Warnings, Errors
    property int level: Plasmoid.configuration.defaultLevel
    property string search: ""
    // query the whole on-disk journal whenever there's a search term OR a severity
    // filter; only plain "All" with no search uses the live tmpfs tail
    readonly property bool searchMode: search !== "" || level !== 0
    property bool paused: false
    property double lastT: 0                            // newest record already shown
    property bool atBottom: true                        // view is near the tail
    property bool hasNew: false                         // new lines arrived off-screen

    Plasmoid.title: i18n("System Log")
    Plasmoid.icon: "utilities-log-viewer"
    toolTipMainText: i18n("System Log")
    toolTipSubText: root.searchMode
        ? i18n("Searching journal · %1 matches", logModel.count)
        : (logData.online ? i18n("Journal · %1 lines", logModel.count)
                          : i18n("Collector not running"))
    preferredRepresentation: fullRepresentation

    // ---- live tail source (tmpfs ring buffer) ----
    LogData {
        id: logData
        interval: Plasmoid.configuration.pollInterval
        paused: root.paused || root.searchMode         // live reads pause during search
        onUpdated: if (!root.searchMode) root.ingest()
    }

    // ---- full-journal search (on-demand journalctl, live-refreshed) ----
    // A reset query (-n LIMIT) loads the latest LIMIT *matching* lines; refresh
    // queries (--since lastT) pull only newer matches, so the search view stays
    // live and incremental -- exactly like the tail, just filtered over the whole
    // on-disk journal.
    P5Support.DataSource {
        id: journalQuery
        engine: "executable"
        onNewData: function(source, d) {
            disconnectSource(source)
            if (!root.searchMode)
                return                                 // box cleared while in flight
            var out = (d.stdout || "").trim()
            if (out !== "") {
                var rows = out.split("\n")
                var recs = []
                for (var i = 0; i < rows.length; i++) {
                    var r = root.parseRec(rows[i])
                    if (r) recs.push(r)
                }
                recs.sort(function(a, b) { return a.t - b.t })   // chronological
                for (var k = 0; k < recs.length; k++) {
                    if (recs[k].t > root.lastT) {                // also de-dups the union
                        logModel.append(root.rowFor(recs[k]))
                        root.lastT = recs[k].t
                    }
                }
            }
            var over = logModel.count - Plasmoid.configuration.searchLimit
            if (over > 0)
                logModel.remove(0, over)
        }
    }

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    function escapeRegex(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&") }

    // reset=true: latest LIMIT matches; reset=false: only matches newer than lastT.
    // A search term matches the MESSAGE (journalctl --grep) OR the application name
    // (identifiers whose name contains the term, fed back as -t filters); the two
    // result sets are unioned and de-duplicated client-side in onNewData.
    function runSearch(reset) {
        if (!root.searchMode)
            return
        var lv = root.levelMax[root.level]
        var prio = lv < 7 ? " -p " + lv : ""           // journalctl: -p N = N and worse
        var window = (reset || root.lastT === 0)
            ? " -n " + Plasmoid.configuration.searchLimit
            : " --since @" + Math.floor(root.lastT / 1000000)
        var cmd
        if (root.search === "") {
            cmd = "journalctl -o json --no-pager" + prio + window
        } else {
            var reArg = shq(escapeRegex(root.search))  // --grep: message (regex)
            var fxArg = shq(root.search)               // grep -iF: app name (substring)
            cmd = "TIDS=$(journalctl -F SYSLOG_IDENTIFIER --no-pager 2>/dev/null"
                + " | grep -iF -- " + fxArg + " | sed 's/.*/-t &/' | tr '\\n' ' '); "
                + "{ journalctl -o json --no-pager --grep " + reArg + prio + window + " 2>/dev/null; "
                + "[ -n \"$TIDS\" ] && journalctl -o json --no-pager $TIDS" + prio + window + " 2>/dev/null; }"
        }
        journalQuery.connectSource(cmd)
    }
    Timer { id: searchDebounce; interval: 300; onTriggered: root.applyMode() }
    Timer {                                            // keep search results live
        interval: Math.max(1500, Plasmoid.configuration.pollInterval)
        repeat: true
        running: root.searchMode && !root.paused
        onTriggered: root.runSearch(false)
    }

    // (re)enter a mode after the search box or severity changes
    function applyMode() {
        logModel.clear()
        root.lastT = 0
        root.hasNew = false
        if (root.searchMode)
            runSearch(true)                            // latest LIMIT matching lines
        else
            ingest()                                   // back to the live tail
    }
    onSearchChanged: searchDebounce.restart()
    onLevelChanged: searchMode ? searchDebounce.restart() : rebuild()

    // ---- model helpers (never touch the view, so they're load-order safe) ----
    function matches(r) {
        if (r.p > root.levelMax[root.level])
            return false
        if (root.search === "")
            return true
        var q = root.search.toLowerCase()
        return r.m.toLowerCase().indexOf(q) >= 0 || r.id.toLowerCase().indexOf(q) >= 0
    }

    function rowFor(r) {
        var d = new Date(r.t / 1000)        // micros -> ms
        var hh = ("0" + d.getHours()).slice(-2)
        var mm = ("0" + d.getMinutes()).slice(-2)
        var ss = ("0" + d.getSeconds()).slice(-2)
        return { key: r.t, time: hh + ":" + mm + ":" + ss, app: r.id, pid: r.pid,
                 msg: r.m, prio: r.p, expanded: false }
    }

    // parse one `journalctl -o json` line (mirrors the collector's Python parse)
    function parseRec(line) {
        var j
        try { j = JSON.parse(line) } catch (e) { return null }
        var m = j.MESSAGE
        if (Array.isArray(m)) {             // binary message -> bytes
            var s = ""
            for (var i = 0; i < m.length; i++) s += String.fromCharCode(m[i])
            m = s
        }
        var unit = j._SYSTEMD_UNIT || j.UNIT || ""
        var id = j.SYSLOG_IDENTIFIER || j._COMM
        if (!id)
            id = (j._TRANSPORT === "kernel") ? "kernel"
               : (unit.indexOf(".service") >= 0 ? unit.replace(".service", "") : (unit || "?"))
        return { t: parseInt(j.__REALTIME_TIMESTAMP || 0),
                 p: parseInt(j.PRIORITY !== undefined ? j.PRIORITY : 6),
                 id: String(id).slice(0, 40),
                 u: unit, pid: String(j._PID || j.SYSLOG_PID || ""), m: String(m || "") }
    }

    // append only records newer than the last one shown (live mode)
    function ingest() {
        var a = logData.lines
        if (a.length === 0)
            return
        for (var i = 0; i < a.length; i++) {
            var r = a[i]
            if (r.t > root.lastT && matches(r))
                logModel.append(rowFor(r))
        }
        root.lastT = a[a.length - 1].t
        var over = logModel.count - Plasmoid.configuration.maxRows
        if (over > 0)
            logModel.remove(0, over)
    }

    // filter/severity changed in live mode -> reshow the whole ring buffer
    function rebuild() {
        logModel.clear()
        root.lastT = 0
        ingest()
    }

    // expansion lives in the model row itself -- ListModel.setProperty fires a
    // proper change notification, unlike mutating a shared JS object in place
    function toggleExpand(index) {
        if (index < 0 || index >= logModel.count)
            return
        logModel.setProperty(index, "expanded", !logModel.get(index).expanded)
    }

    // clipboard + actions. copyText fires lineCopied() rather than touching the
    // toast directly, so these stay root-scoped and load-order safe.
    signal lineCopied()
    function copyText(text) {
        clip.text = text
        clip.selectAll()
        clip.copy()
        root.lineCopied()
    }
    function copyAll() {
        var out = []
        for (var i = 0; i < logModel.count; i++) {
            var m = logModel.get(i)
            out.push(m.time + "  " + m.app + (m.pid ? "[" + m.pid + "]" : "") + ": " + m.msg)
        }
        copyText(out.join("\n"))
    }
    function askClaude(time, app, pid, msg, prio) {
        var ctx = "I saw this entry in my systemd journal (journalctl):\n"
                + "time: " + time + "\napp: " + app + (pid ? " (pid " + pid + ")" : "")
                + "\npriority: " + prio + "\nmessage: " + msg
                + "\n\nWhat does it mean, and is there anything I should do about it?"
        launcher.connectSource("konsole --workdir \"$HOME\" -e claude " + shq(ctx))
    }
    TextEdit { id: clip; visible: false }              // hidden clipboard helper
    P5Support.DataSource {                             // fire-and-forget launcher
        id: launcher
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }

    ListModel { id: logModel }

    // start in whatever mode the default severity implies (live tail or query)
    Component.onCompleted: if (root.searchMode) applyMode()

    function prioColor(p) {
        if (p <= 3) return Kirigami.Theme.negativeTextColor      // err/crit/alert/emerg
        if (p === 4) return Kirigami.Theme.neutralTextColor      // warning
        return Kirigami.Theme.textColor                          // notice/info/debug
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        implicitWidth: Kirigami.Units.gridUnit * 30
        implicitHeight: Kirigami.Units.gridUnit * 22

        StatusOverlay { anchors.fill: parent; online: logData.online || root.searchMode }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // header: title + filter + search + pause
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: "utilities-log-viewer"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                PlasmaComponents.Label { text: i18n("System Log"); font.weight: Font.Bold }

                Item { Layout.fillWidth: true }

                QQC2.ComboBox {
                    id: levelCombo
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                    model: [i18n("All"), i18n("Info"), i18n("Warnings"), i18n("Errors")]
                    currentIndex: root.level
                    onActivated: root.level = currentIndex
                }
                QQC2.TextField {
                    id: searchField
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                    placeholderText: i18n("Search journal…")
                    text: root.search
                    onTextChanged: root.search = text
                    QQC2.ToolButton {
                        visible: searchField.text !== ""
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        flat: true; icon.name: "edit-clear"
                        onClicked: searchField.clear()
                    }
                }
                QQC2.ToolButton {
                    flat: true
                    enabled: !root.searchMode
                    icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
                    onClicked: root.paused = !root.paused
                    QQC2.ToolTip.text: root.paused ? i18n("Resume (follow)") : i18n("Pause")
                    QQC2.ToolTip.visible: hovered
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // the log
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                ListView {
                    id: view
                    model: logModel
                    reuseItems: true
                    boundsBehavior: Flickable.StopAtBounds

                    // how close to the bottom still counts as "following" the tail
                    readonly property real stickPx: Math.max(0, Plasmoid.configuration.stickLines)
                        * (Kirigami.Theme.smallFont.pixelSize * 1.4 + Kirigami.Units.smallSpacing)
                    property real lastContentHeight: 0
                    // atBottom changes only on USER scrolling / viewport resize --
                    // never on content growth -- so following the tail is stable
                    function updateFollowing() {
                        root.atBottom = (contentHeight <= height)
                            || (contentY >= contentHeight - height - stickPx)
                        if (root.atBottom) root.hasNew = false
                    }
                    onContentYChanged: updateFollowing()
                    onHeightChanged: updateFollowing()
                    onContentHeightChanged: {
                        if (!root.paused) {
                            if (root.atBottom)
                                Qt.callLater(positionViewAtEnd)            // stay pinned
                            else if (contentHeight > lastContentHeight)
                                root.hasNew = true                         // new lines off-screen
                        }
                        lastContentHeight = contentHeight
                    }
                    Component.onCompleted: { updateFollowing(); Qt.callLater(positionViewAtEnd) }

                    delegate: Rectangle {
                        id: row
                        width: view.width
                        readonly property bool isExpanded: model.expanded === true
                        readonly property bool wrap: isExpanded || Plasmoid.configuration.wrapMessages
                        function lineText() {
                            return model.time + "  " + model.app
                                + (model.pid ? "[" + model.pid + "]" : "") + ": " + model.msg
                        }
                        height: contentRow.implicitHeight + Kirigami.Units.smallSpacing
                        color: ma.containsMouse ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                                                : (index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03) : "transparent")

                        RowLayout {
                            id: contentRow
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            // disclosure chevron — fades in when there's more to reveal
                            Kirigami.Icon {
                                source: row.isExpanded ? "go-down-symbolic" : "go-next-symbolic"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.alignment: Qt.AlignTop
                                opacity: (msgLabel.truncated || row.isExpanded) ? 0.6 : 0.0
                            }
                            PlasmaComponents.Label {
                                text: model.time
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.55
                                Layout.leftMargin: Kirigami.Units.smallSpacing
                                Layout.alignment: Qt.AlignTop
                            }
                            PlasmaComponents.Label {
                                visible: Plasmoid.configuration.showApp
                                text: model.app
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.weight: Font.DemiBold
                                color: root.accent
                                elide: Text.ElideRight
                                Layout.leftMargin: Kirigami.Units.smallSpacing
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                                Layout.alignment: Qt.AlignTop
                            }
                            PlasmaComponents.Label {
                                id: msgLabel
                                text: model.msg
                                color: root.prioColor(model.prio)
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                wrapMode: row.wrap ? Text.WrapAnywhere : Text.NoWrap
                                elide: row.wrap ? Text.ElideNone : Text.ElideRight
                                Layout.leftMargin: Kirigami.Units.smallSpacing
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                            }
                        }

                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function(mouse) {
                                if (mouse.button === Qt.RightButton)
                                    ctxMenu.popup()
                                else
                                    root.toggleExpand(index)
                            }
                        }

                        QQC2.Menu {
                            id: ctxMenu
                            QQC2.MenuItem {
                                text: i18n("Copy line"); icon.name: "edit-copy"
                                onTriggered: root.copyText(row.lineText())
                            }
                            QQC2.MenuItem {
                                text: i18n("Copy all"); icon.name: "edit-copy-all"
                                onTriggered: root.copyAll()
                            }
                            QQC2.MenuSeparator {}
                            QQC2.MenuItem {
                                text: i18n("Ask Claude"); icon.name: "help-hint"
                                onTriggered: root.askClaude(model.time, model.app, model.pid, model.msg, model.prio)
                            }
                        }
                    }
                }
            }
        }

        // "jump to newest" pill — shown only when new lines land off-screen
        QQC2.Button {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Kirigami.Units.largeSpacing
            visible: root.hasNew && !root.paused
            text: i18n("New logs")
            icon.name: "go-down"
            onClicked: { view.positionViewAtEnd(); root.hasNew = false }
        }

        // brief "copied" confirmation
        Rectangle {
            id: copyToast
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Kirigami.Units.largeSpacing
            radius: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.backgroundColor
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)
            border.width: 1
            width: toastLabel.implicitWidth + Kirigami.Units.largeSpacing * 2
            height: toastLabel.implicitHeight + Kirigami.Units.smallSpacing * 2
            opacity: 0
            visible: opacity > 0
            function show() { fade.restart() }
            Connections { target: root; function onLineCopied() { copyToast.show() } }
            PlasmaComponents.Label {
                id: toastLabel; anchors.centerIn: parent
                text: i18n("Copied to clipboard"); font: Kirigami.Theme.smallFont
            }
            SequentialAnimation {
                id: fade
                NumberAnimation { target: copyToast; property: "opacity"; to: 1; duration: 120 }
                PauseAnimation { duration: 900 }
                NumberAnimation { target: copyToast; property: "opacity"; to: 0; duration: 300 }
            }
        }
    }
}
