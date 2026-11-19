import Darwin

/// Termination also wakes the socket poll when no fan is under manual control.
var terminateRequested: Int32 = 0
private var terminationWriteFD: Int32 = -1

private func requestTermination(_ signalNumber: Int32) {
    terminateRequested = 1
    if terminationWriteFD >= 0 {
        var byte: UInt8 = 1
        _ = write(terminationWriteFD, &byte, 1)
    }
}

func installTerminationHandlers() -> Int32 {
    terminateRequested = 0
    var descriptors: [Int32] = [-1, -1]
    if pipe(&descriptors) == 0 {
        if fcntl(descriptors[1], F_SETFL, O_NONBLOCK) == 0 {
            terminationWriteFD = descriptors[1]
        } else {
            close(descriptors[0])
            close(descriptors[1])
            descriptors[0] = -1
        }
    }
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, requestTermination)
    signal(SIGINT, requestTermination)
    return descriptors[0]
}
