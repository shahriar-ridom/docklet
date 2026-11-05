pragma Singleton

import QtQuick
import Quickshell

// Run external commands without declaring a Process per call site.
//   Jobs.run(["file", "-b", "--", path], (code, out, err) => { ... })
Singleton {
    id: root

    property Component _jobComp: Component {
        Job {}
    }

    property Component _streamComp: Component {
        StreamJob {}
    }

    // Like run(), but `onLine(line)` fires for each stdout line as it comes.
    // Returns the job; set `job.running = false` to cancel it.
    function stream(argv, onLine, callback) {
        const job = _streamComp.createObject(root, { command: argv, onLine: onLine || null, callback: callback || null });
        job.running = true;
        return job;
    }

    function run(argv, callback) {
        const job = _jobComp.createObject(root, { command: argv, callback: callback || null });
        job.running = true;
        return job;
    }

    // Small "sh -c" helper for tiny scripts; args are passed as $1.. so
    // paths never get interpolated into the script text.
    function sh(script, args, callback) {
        return run(["sh", "-c", script, "sh"].concat(args || []), callback);
    }
}
