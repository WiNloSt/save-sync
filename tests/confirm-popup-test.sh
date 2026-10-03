#!/usr/bin/env bash
# The destructive-confirmation popup (QML), off-screen: safe button on the left
# and focused, destructive on the right; Escape, the close button, Return on the
# focused button and B (Escape) are safe; only picking the right button does it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
/usr/bin/python3 - "$REPO/bin/savesync" "$T/confirm.qml" <<'PY'
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("ss", sys.argv[1])
spec = importlib.util.spec_from_loader("ss", l); ss = importlib.util.module_from_spec(spec); l.exec_module(ss)
open(sys.argv[2], "w").write(ss.CONFIRM_QML_SRC)
PY
cat > "$T/tst_confirm.qml" <<'QML'
import QtQuick
import QtTest

TestCase {
    name: "confirm"
    when: windowShown
    function open() {
        const c = Qt.createComponent(Qt.resolvedUrl("confirm.qml"))
        verify(c.status === Component.Ready, c.errorString())
        const w = c.createObject(null, {exitOnDecide: false, arg: ["save-sync: Sim Game",
            "Stop syncing ~/.config/SimCo/Saves?", "Its files stay where they are, and backups made so far are kept.",
            "Keep it", "Stop syncing"]})
        const spy = createTemporaryObject(sig, this, {target: w})
        w.requestActivate()
        tryVerify(() => w.active)
        tryVerify(() => find(w.contentItem, "safe").activeFocus)
        return [w, spy, find(w.contentItem, "safe"), find(w.contentItem, "danger")]
    }
    function find(item, name) {
        if (item.objectName === name) return item
        for (const c of item.children) { const r = find(c, name); if (r) return r }
        return null
    }
    Component { id: sig; SignalSpy { signalName: "decided" } }
    function decided(spy) { tryCompare(spy, "count", 1); return spy.signalArguments[0][0] }

    function test_layout_and_focus() {
        const [w, spy, safe, danger] = open()
        verify(safe.mapToItem(null, 0, 0).x < danger.mapToItem(null, 0, 0).x, "safe left, destructive right")
        verify(safe.activeFocus, "safe button focused")
        w.destroy()
    }
    function test_escape_is_safe() { const [w, spy] = open(); keyClick(Qt.Key_Escape); compare(decided(spy), 1); w.destroy() }
    function test_close_is_safe() { const [w, spy] = open(); w.close(); compare(decided(spy), 1); w.destroy() }
    function test_return_on_default_is_safe() { const [w, spy] = open(); keyClick(Qt.Key_Return); compare(decided(spy), 1); w.destroy() }
    function test_space_on_default_is_safe() { const [w, spy] = open(); keyClick(Qt.Key_Space); compare(decided(spy), 1); w.destroy() }
    function test_right_then_a_does_it() { const [w, spy] = open(); keyClick(Qt.Key_Right); keyClick(Qt.Key_Space); compare(decided(spy), 10); w.destroy() }
    function test_right_left_back_to_safe() { const [w, spy] = open(); keyClick(Qt.Key_Right); keyClick(Qt.Key_Left); keyClick(Qt.Key_Space); compare(decided(spy), 1); w.destroy() }
}
QML
cd "$T"
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=org.kde.desktop /usr/lib/qt6/bin/qmltestrunner -input tst_confirm.qml
