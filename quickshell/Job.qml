import QtQuick
import Quickshell.Io

// One-shot process: create with Job.run-style helpers (see Jobs.qml), it calls
// `callback(exitCode, stdout, stderr)` once and destroys itself.
// Exit and end-of-stdout arrive as separate signals in no fixed order, so we
// wait for both (with a short safety timer in case a stream never reports).
Process {
    id: job

    property var callback: null
    property int _code: -1
    property bool _exited: false
    property bool _outDone: false
    property bool _errDone: false
    property bool _fired: false
    property bool _started: false

    // A missing binary never emits `exited`; report it as exit code 127.
    onStarted: _started = true
    onRunningChanged: if (running) startCheck.start()
    Component.onCompleted: startCheck.start()

    stdout: StdioCollector {
        onStreamFinished: { job._outDone = true; job._finish(); }
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

    function _fail(msg) {
        if (_fired) return;
        _fired = true;
        if (callback)
            callback(127, "", msg);
        destroy();
    }

    function _finish(force) {
        if (_fired || !_exited || (!force && !(_outDone && _errDone)))
            return;
        _fired = true;
        if (callback)
            callback(_code, stdout.text, stderr.text);
        destroy();
    }

    property Timer startCheck: Timer {
        interval: 500
        onTriggered: if (!job._started && !job._exited) job._fail(`failed to start: ${job.command[0]}`)
    }

    property Timer safety: Timer {
        interval: 300
        onTriggered: job._finish(true)
    }
}
