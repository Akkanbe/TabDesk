import AppKit
import ApplicationServices
import Foundation

// 別プロセスのAX情報を読むだけの検証ツール。AXShimをリンクせず、非公開属性も読まない。
@main
@MainActor
struct PublicAXProbe {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4,
                  let pid = Int32(CommandLine.arguments[1]), pid > 0,
                  let samples = Int(CommandLine.arguments[2]), (1...3600).contains(samples),
                  let interval = Double(CommandLine.arguments[3]), (0.05...60).contains(interval) else {
                throw ProbeError.message("Usage: PublicAXProbe <pid> <samples 1...3600> <interval seconds 0.05...60>")
            }
            guard AXIsProcessTrusted() else { throw ProbeError.message("Accessibility permission is unavailable; no prompt was requested.") }
            guard let target = NSRunningApplication(processIdentifier: pid) else { throw ProbeError.message("Target is not running") }
            let store = AXWindowReferenceStore()
            let session = store.beginProcess(pid: pid)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            let observer = try AppWindowObserver(
                pid: pid, requiredNotifications: [],
                optionalNotifications: [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                        kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification],
                messagingTimeout: 0.2
            ) { notification, element in
                let known = store.existingID(for: element, in: session)
                emit(["event": notification, "knownReference": known?.description ?? "unknown"])
                if notification == kAXUIElementDestroyedNotification, let known {
                    store.forget(known, in: session)
                }
            }
            defer { observer.invalidate(); store.endProcess(session) }
            emit(["pid": pid, "unavailableNotifications": observer.unavailableNotifications])
            var watched: Set<WindowReferenceID> = []
            var titleGroups: [String: Int] = [:]
            for sample in 0..<samples {
                guard !target.isTerminated else { emit(["terminated": true]); break }
                do {
                    let windows = try AXAttributes.elements(app, kAXWindowsAttribute)
                    var observations: [[String: Any]] = []
                    for element in windows {
                        AXUIElementSetMessagingTimeout(element, 0.2)
                        // 起動直後に窓一覧がアプリ要素を返すケースを観測した。
                        // 同一IDへの誤集約を防ぐため、窓として確認できない参照は採用しない。
                        guard try AXAttributes.string(element, kAXRoleAttribute) == kAXWindowRole else {
                            emit(["sample": sample, "rejectedNonWindowReference": true])
                            continue
                        }
                        let id = try store.referenceID(for: element, in: session)
                        if !watched.contains(id) {
                            do {
                                try observer.addNotification(kAXUIElementDestroyedNotification, element: element)
                                watched.insert(id)
                            } catch { emit(["destroyedSubscriptionError": String(describing: error)]) }
                        }
                        let title = try? AXAttributes.string(element, kAXTitleAttribute)
                        if let title, titleGroups[title] == nil { titleGroups[title] = titleGroups.count + 1 }
                        var row: [String: Any] = ["reference": id.description, "titleGroup": title.flatMap { titleGroups[$0] } ?? 0]
                        row["position"] = point(element)
                        row["size"] = size(element)
                        row["minimized"] = (try? AXAttributes.bool(element, kAXMinimizedAttribute)).map { String($0) } ?? "unknown"
                        row["positionSettable"] = settable(element, kAXPositionAttribute)
                        row["layoutSuspension"] = WindowLayoutAccess.read(element).suspension.map(String.init) ?? "unknown"
                        row["sizeSettable"] = settable(element, kAXSizeAttribute)
                        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
                            row[attribute] = (try? AXAttributes.string(element, attribute)) ?? "unavailable"
                        }
                        if let value = try? AXAttributes.copy(element, kAXFullScreenButtonAttribute),
                           CFGetTypeID(value) == AXUIElementGetTypeID() {
                            let button = unsafeDowncast(value, to: AXUIElement.self)
                            var attributes: [String: String] = [:]
                            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXSubroleAttribute] {
                                do { attributes[name] = String(describing: try AXAttributes.copy(button, name)) }
                                catch { attributes[name] = "unavailable" }
                            }
                            row["fullScreenButton"] = attributes
                        } else { row["fullScreenButton"] = "unavailable" }
                        observations.append(row)
                    }
                    var focus = "unknown"
                    if let value = try? AXAttributes.copy(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                        focus = store.existingID(for: unsafeDowncast(value, to: AXUIElement.self), in: session)?.description ?? "unknown"
                    }
                    emit(["sample": sample, "focus": focus, "windows": observations])
                } catch { emit(["sample": sample, "error": String(describing: error)]) }
                // メインRunLoopでAX通知を受ける。長時間のツール待機は呼び出し側で行わない。
                RunLoop.current.run(until: Date().addingTimeInterval(interval))
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func emit(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("JSON encoding failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func point(_ element: AXUIElement) -> String {
        guard let p = try? AXAttributes.point(element, kAXPositionAttribute) else { return "unknown" }
        return "\(p.x),\(p.y)"
    }
    static func size(_ element: AXUIElement) -> String {
        guard let s = try? AXAttributes.size(element, kAXSizeAttribute) else { return "unknown" }
        return "\(s.width),\(s.height)"
    }
    static func settable(_ element: AXUIElement, _ attribute: String) -> String {
        var value = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &value)
        return result == .success ? String(value.boolValue) : "error:\(result.rawValue)"
    }
    enum ProbeError: Error { case message(String) }
}
