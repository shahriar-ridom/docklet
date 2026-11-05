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

    function _finish(force) {
        if (_fired || !_exited || (!force && !(_outDone && _errDone)))
            return;
        _fired = true;
        if (callback)
            callback(_code, stdout.text, stderr.text);
        destroy();
    }

    property Timer safety: Timer {
        interval: 300
        onTriggered: job._finish(true)
    }
}
