#if os(macOS)
import Foundation
import SingCore

extension HostController {
    /// The speakers went away or changed: fall back to what is available, keep the song going, and tell the room.
    func outputChanged() {
        let missing = outputDeviceUID.map { AudioDevices.device(uid: $0) == nil } ?? false
        playback.recoverOutput()
        if missing {
            lastError = "The chosen speakers were disconnected; playing on the Mac's default output until they come back."
            logError("output device disconnected")
            Task { await server?.broadcast(.toast(.init(message: "Speakers disconnected: playing on the Mac for now"))) }
        }
        if mic.isRunning, AudioDevices.device(uid: inputDeviceUID) == nil, inputDeviceUID != nil {
            mic.stop()
            Task { await startMic() }
        }
    }
}
#endif
