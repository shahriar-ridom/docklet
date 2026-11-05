import QtQuick
import Quickshell.Io

// Long-running process whose stdout is read line by line as it arrives
// (progress updates). Calls `onLine(line)` per line and `callback(exitCode,
// lastLine, stderr)` once at the end, then destroys itself. Set
// `running = false` to cancel (sends SIGTERM).
Process {
    id: job

    property var onLine: null
    property var callback: null
    property string _last: ""
    property bool _exited: false
    property bool _errDone: false
    property bool _fired: false
    property int _code: -1
    property bool _started: false

    // A missing binary never emits `exited`; report it as exit code 127.
    onStarted: _started = true
    Component.onCompleted: startCheck.start()
    property Timer startCheck: Timer {
        interval: 1000
        onTriggered: if (!job._started && !job._exited && !job._fired) {
            job._fired = true;
            if (job.callback) job.callback(127, "", `failed to start: ${job.command[0]}`);
            job.destroy();
        }
    }

    stdout: SplitParser {
        onRead: line => {
            if (!line) return;
            job._last = line;
            if (job.onLine) job.onLine(line);
        }
    }
    stderr: StdioCollector {
        onStreamFinished: { job._errDone = true; job._finish(); }
    }

    onExited: code => {
        _code = code;
        _exited = true;
        safety.start();
        _finish();
    }

    function _finish(force) {
        if (_fired || !_exited || (!force && !_errDone)) return;
        _fired = true;
        if (callback) callback(_code, _last, stderr.text);
        destroy();
    }

    property Timer safety: Timer { interval: 300; onTriggered: job._finish(true) }
}
