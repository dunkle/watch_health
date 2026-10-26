import WatchConnectivity
import WatchMindCore

final class WatchReceiver: NSObject, WCSessionDelegate {
    var onSample: ((HeartSample) -> Void)?
    var onTrigger: ((Trigger) -> Void)?
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self; WCSession.default.activate()
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receive(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { receive(userInfo) }
    private func receive(_ payload: [String: Any]) {
        if let data = payload["trigger"] as? Data, let trigger = try? JSONDecoder().decode(Trigger.self, from: data) {
            DispatchQueue.main.async { [weak self] in self?.onTrigger?(trigger) }
        } else if let bpm = payload["bpm"] as? Double, let timestamp = payload["time"] as? Double {
            DispatchQueue.main.async { [weak self] in self?.onSample?(HeartSample(date: Date(timeIntervalSince1970: timestamp), bpm: bpm)) }
        }
    }
}
