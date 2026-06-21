/*
 * Linux-Log-Monitor :: System Log widget
 * Live, colour-coded view of the systemd journal (kernel + every service/app),
 * with a severity filter, live search, pause/follow and click-to-copy.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import "lib"

PlasmoidItem {
    id: root

    readonly property color accent: Plasmoid.configuration.accentColor !== ""
        ? Plasmoid.configuration.accentColor : Kirigami.Theme.highlightColor

    // severity filter: combo index -> max journal priority kept (lower = worse)
    readonly property var levelMax: [7, 6, 4, 3]      // All, Info, Warnings, Errors
    property int level: Plasmoid.configuration.defaultLevel
    property string search: ""
    property bool paused: false
    property double lastT: 0                            // newest record already shown

    Plasmoid.title: i18n("System Log")
    Plasmoid.icon: "utilities-log-viewer"
    toolTipMainText: i18n("System Log")
    toolTipSubText: logData.online
        ? i18n("Journal · %1 lines", logModel.count)
        : i18n("Collector not running")
    preferredRepresentation: fullRepresentation

    LogData {
        id: logData
        interval: Plasmoid.configuration.pollInterval
        paused: root.paused
        onUpdated: root.ingest()
    }

    // hidden helper to put text on the clipboard (Qt has no direct QML clipboard)
    TextEdit { id: clip; visible: false }
    function copyLine(text) {
        clip.text = text
        clip.selectAll()
        clip.copy()
        copyToast.show()
    }

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
        return { time: hh + ":" + mm + ":" + ss, app: r.id, pid: r.pid,
                 msg: r.m, prio: r.p }
    }

    // rebuild the whole model (filter/search changed)
    function rebuild() {
        logModel.clear()
        var a = logData.lines
        for (var i = 0; i < a.length; i++)
            if (matches(a[i]))
                logModel.append(rowFor(a[i]))
        root.lastT = a.length ? a[a.length - 1].t : 0
        if (!root.paused)
            Qt.callLater(view.positionViewAtEnd)
    }

    // append only records newer than the last one we showed
    function ingest() {
        var a = logData.lines
        if (a.length === 0)
            return
        var atBottom = view.atYEnd || logModel.count === 0
        for (var i = 0; i < a.length; i++) {
            var r = a[i]
            if (r.t > root.lastT && matches(r))
                logModel.append(rowFor(r))
        }
        root.lastT = a[a.length - 1].t
        var over = logModel.count - Plasmoid.configuration.maxRows
        if (over > 0)
            logModel.remove(0, over)
        if (!root.paused && atBottom)
            Qt.callLater(view.positionViewAtEnd)
    }

    onLevelChanged: rebuild()
    onSearchChanged: rebuild()

    ListModel { id: logModel }

    function prioColor(p) {
        if (p <= 3) return Kirigami.Theme.negativeTextColor      // err/crit/alert/emerg
        if (p === 4) return Kirigami.Theme.neutralTextColor      // warning
        if (p === 5) return Kirigami.Theme.textColor             // notice
        return Kirigami.Theme.textColor                          // info/debug
    }

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        implicitWidth: Kirigami.Units.gridUnit * 30
        implicitHeight: Kirigami.Units.gridUnit * 22

        StatusOverlay { anchors.fill: parent; online: logData.online }

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
                    placeholderText: i18n("Search…")
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
                    icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
                    onClicked: { root.paused = !root.paused; if (!root.paused) Qt.callLater(view.positionViewAtEnd) }
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

                    delegate: Rectangle {
                        width: view.width
                        height: msgLabel.implicitHeight + Kirigami.Units.smallSpacing
                        color: rowHover.hovered ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                                                : (index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03) : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.largeSpacing

                            PlasmaComponents.Label {
                                text: model.time
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.55
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
                                wrapMode: Plasmoid.configuration.wrapMessages ? Text.WrapAnywhere : Text.NoWrap
                                elide: Plasmoid.configuration.wrapMessages ? Text.ElideNone : Text.ElideRight
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                            }
                        }

                        HoverHandler { id: rowHover }
                        TapHandler {
                            onTapped: root.copyLine(model.time + "  " + model.app
                                + (model.pid ? "[" + model.pid + "]" : "") + ": " + model.msg)
                        }
                    }
                }
            }
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
