import Foundation
import SingCore

/// Advertises `_sing._tcp` so pads find the Mac without typing an address.
@MainActor
public final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    public func start(name: String, port: Int) {
        stop()
        let s = NetService(domain: "local.", type: SingProtocol.bonjourType + ".", name: name, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: ["v": Data(String(SingProtocol.version).utf8)]))
        s.delegate = self
        s.publish()
        service = s
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}
