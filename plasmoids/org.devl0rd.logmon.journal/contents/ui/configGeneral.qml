import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrols as KQuickControls

Kirigami.FormLayout {
    property alias cfg_pollInterval: pollSpin.value
    property alias cfg_maxRows: rowsSpin.value
    property alias cfg_defaultLevel: levelCombo.currentIndex
    property alias cfg_showApp: showApp.checked
    property alias cfg_wrapMessages: wrap.checked
    property alias cfg_accentColor: accent.text

    RowLayout {
        Kirigami.FormData.label: i18n("Poll interval:")
        QQC2.SpinBox {
            id: pollSpin
            from: 250; to: 5000; stepSize: 250
            textFromValue: function(v) { return (v / 1000).toFixed(2) + " s" }
            valueFromText: function(t) { return parseFloat(t) * 1000 }
        }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Lines kept:")
        QQC2.SpinBox { id: rowsSpin; from: 100; to: 2000; stepSize: 100 }
    }
    QQC2.ComboBox {
        id: levelCombo
        Kirigami.FormData.label: i18n("Default level:")
        model: [i18n("All"), i18n("Info"), i18n("Warnings"), i18n("Errors")]
    }

    Item { Kirigami.FormData.isSection: true }

    QQC2.CheckBox { id: showApp; Kirigami.FormData.label: i18n("Show:"); text: i18n("Application column") }
    QQC2.CheckBox { id: wrap; text: i18n("Wrap long messages") }

    Item { Kirigami.FormData.isSection: true }

    RowLayout {
        Kirigami.FormData.label: i18n("Accent colour:")
        QQC2.CheckBox {
            id: useAccent; text: i18n("Custom")
            checked: accent.text !== ""
            onToggled: if (!checked) accent.text = ""
        }
        KQuickControls.ColorButton {
            enabled: useAccent.checked
            color: accent.text !== "" ? accent.text : Kirigami.Theme.highlightColor
            onColorChanged: if (useAccent.checked) accent.text = color
        }
        QQC2.Label { id: accent; visible: false; text: "" }
    }
}
