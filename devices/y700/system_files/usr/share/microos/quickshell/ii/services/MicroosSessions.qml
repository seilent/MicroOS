pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string current: "desktop"
    property list<var> entries: []
    property bool switching: false

    function refresh() {
        menuProc.running = false;
        menuProc.running = true;
    }

    function actionable(entry) {
        return !root.switching && (entry.state === "available" || (entry.state === "not-installed" && entry.install));
    }

    function note(entry) {
        if (root.switching)
            return Translation.tr("a session switch is in progress");
        if (entry.state === "not-installed")
            return entry.install ? Translation.tr("not installed, select to install") : Translation.tr("not installed");
        if (entry.state === "refused")
            return Translation.tr("not reviewed");
        return "";
    }

    function start(args) {
        Quickshell.execDetached(["sh", "-c", 'systemctl "$@" || logger -t ii-session "systemctl $* failed"', "sh", ...args]);
    }

    function select(entry) {
        if (entry.state === "available")
            root.start(["start", "--no-block", `microos-session-switch@${entry.name}.service`]);
        else if (entry.state === "not-installed" && entry.install)
            root.start(["--user", "start", "--no-block", `microos-session-install@${entry.name}.service`]);
    }

    Process {
        id: menuProc
        command: ["sh", "-c", 'microos-session menu "$1"; echo "exit $?"', "sh", root.current]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n").filter(line => line.length > 0);
                const last = lines.pop() ?? "";
                if (!last.startsWith("exit "))
                    return;
                const code = last.slice(5);
                root.switching = code === "3";
                if (code !== "0") {
                    if (code !== "3")
                        console.warn(`microos-session menu ${root.current} exited ${code}`);
                    return;
                }
                root.entries = lines.map(line => line.split("\t"))
                    .filter(f => f.length === 4 && f[0] !== root.current)
                    .map(f => ({ name: f[0], label: f[1], state: f[2], install: f[3] === "yes" }));
            }
        }
    }
}
