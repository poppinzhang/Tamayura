import Foundation
import FlutterMacOS
import Darwin

final class LanDiscovery: NSObject, FlutterStreamHandler, NetServiceBrowserDelegate, NetServiceDelegate {
  private var sink: FlutterEventSink?
  private var browser: NetServiceBrowser?
  private var publisher: NetService?
  private var services: [String: NetService] = [:]
  private var known: [String: [String: Any]] = [:]
  private var resolveAttempts: [String: Int] = [:]
  private var selfID = ""
  private static let type = "_tamayura._tcp."

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    known.values.forEach { events($0) }
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

  func start(id: String, name: String, port: Int) throws {
    guard (1...65535).contains(port), id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
      throw PlatformFailure.invalid(.invalidDiscoveryArguments)
    }
    stop()
    selfID = id
    let service = NetService(domain: "local.", type: Self.type, name: "Tamayura-\(id.prefix(54))", port: Int32(port))
    service.delegate = self
    var label = String(name.prefix(100))
    while label.utf8.count > 180 { label.removeLast() }
    service.setTXTRecord(NetService.data(fromTXTRecord: [
      "id": Data(id.utf8), "name": Data(label.utf8), "version": Data("4".utf8),
    ]))
    publisher = service
    service.publish()
    let browser = NetServiceBrowser()
    self.browser = browser
    browser.delegate = self
    browser.searchForServices(ofType: Self.type, inDomain: "local.")
  }

  func stop() {
    browser?.delegate = nil
    browser?.stop()
    browser = nil
    publisher?.delegate = nil
    publisher?.stop()
    publisher = nil
    for service in services.values {
      service.delegate = nil
      service.stopMonitoring()
      service.stop()
    }
    services.removeAll()
    known.removeAll()
    resolveAttempts.removeAll()
  }

  private func key(_ service: NetService) -> String { "\(service.domain)|\(service.type)|\(service.name)" }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard self.browser === browser else { return }
    let key = key(service)
    guard services[key] == nil else { return }
    services[key] = service
    resolveAttempts[key] = 1
    service.delegate = self
    service.resolve(withTimeout: 10)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    guard self.browser === browser else { return }
    let key = key(service)
    resolveAttempts.removeValue(forKey: key)
    if let old = services.removeValue(forKey: key) { old.delegate = nil; old.stopMonitoring(); old.stop() }
    if var event = known.removeValue(forKey: key) { event["type"] = "lost"; sink?(event) }
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard services[key(sender)] === sender else { return }
    resolveAttempts.removeValue(forKey: key(sender))
    sender.startMonitoring()
    found(sender)
  }

  func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { found(sender) }

  private func found(_ service: NetService) {
    let key = key(service)
    guard services[key] === service, let txt = service.txtRecordData() else { return }
    let attributes = NetService.dictionary(fromTXTRecord: txt)
    guard let data = attributes["id"], let id = String(data: data, encoding: .utf8),
          id != selfID, id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
          (1...65535).contains(service.port), let host = service.addresses?.compactMap(Self.ipv4).first else { return }
    let name = attributes["name"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
    let event: [String: Any] = ["type": "found", "id": id, "name": String(name.prefix(128)), "host": host, "port": service.port]
    if NSDictionary(dictionary: known[key] ?? [:]) != NSDictionary(dictionary: event) {
      known[key] = event
      sink?(event)
    }
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    guard sender === publisher else { return }
    error("register", errorDict)
  }
  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard services[key(sender)] === sender else { return }
    let key = key(sender)
    let attempt = resolveAttempts[key] ?? 1
    if attempt < 3 {
      resolveAttempts[key] = attempt + 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak sender] in
        guard let self, let sender, self.services[key] === sender else { return }
        sender.resolve(withTimeout: 10)
      }
    } else {
      error("resolve", errorDict)
      sender.startMonitoring()
    }
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    guard self.browser === browser else { return }
    error("discover", errorDict)
  }
  private func error(_ stage: String, _ info: [String: NSNumber]) {
    sink?(["type": "error", "stage": stage, "code": info[NetService.errorCode]?.intValue ?? -1,
           "message": AppText.text(.discoveryFailed)])
  }

  private static func ipv4(_ data: Data) -> String? {
    guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
    var address = sockaddr_in()
    _ = withUnsafeMutableBytes(of: &address) { data.copyBytes(to: $0) }
    guard address.sin_family == sa_family_t(AF_INET) else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
    let host = String(cString: buffer)
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return nil }
    let isLAN = parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) ||
      (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    return isLAN ? host : nil
  }

  static func localInfo() -> [String: Any] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    var hosts = Set<String>()
    if getifaddrs(&interfaces) == 0 {
      defer { freeifaddrs(interfaces) }
      var item = interfaces
      while let current = item {
        defer { item = current.pointee.ifa_next }
        guard current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
              current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let data = Data(bytes: address, count: MemoryLayout<sockaddr_in>.size)
        if let host = ipv4(data) { hosts.insert(host) }
      }
    }
    return ["name": Host.current().localizedName ?? "Mac", "addresses": hosts.sorted()]
  }
}
