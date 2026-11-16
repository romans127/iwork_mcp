import AppKit
import ApplicationServices

struct Failure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func attribute(_ e: AXUIElement, _ key: String) -> Any? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil }
func string(_ e: AXUIElement, _ key: String) -> String { attribute(e,key) as? String ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func role(_ e: AXUIElement) -> String { string(e,kAXRoleAttribute) }
func label(_ e: AXUIElement) -> String { let t = string(e,kAXTitleAttribute); return t.isEmpty ? string(e,kAXDescriptionAttribute) : t }
func walk(_ e: AXUIElement, body: Bool = false, depth: Int = 0, _ predicate: (AXUIElement)->Bool) -> [AXUIElement] {
    if depth > 40 || label(e) == "Formatter" { return [] }
    return (predicate(e) ? [e] : []) + children(e).flatMap { walk($0, body: body, depth: depth + 1, predicate) }
}
func set(_ e: AXUIElement, _ key: String, _ value: CFTypeRef) throws { guard AXUIElementSetAttributeValue(e,key as CFString,value) == .success else { throw Failure("Cannot set \(key); no further action performed.") } }
func press(_ e: AXUIElement) throws { guard AXUIElementPerformAction(e,kAXPressAction as CFString) == .success else { throw Failure("Cannot press control \(label(e)).") }; RunLoop.current.run(until:Date(timeIntervalSinceNow:0.2)) }
func buttons(_ root: AXUIElement, _ name: String) -> [AXUIElement] { walk(root) { role($0) == "AXButton" && label($0).trimmingCharacters(in:.whitespaces) == name } }
func groups(_ root: AXUIElement) -> [AXUIElement] { walk(root) { role($0) == "AXUnknown" && string($0,kAXDescriptionAttribute).hasPrefix("Comment from ") } }
func text(_ group: AXUIElement) -> String { walk(group) { role($0) == "AXTextArea" }.map { string($0,kAXValueAttribute) }.joined(separator:"\n") }
func record(_ group: AXUIElement) -> [String:Any] { ["description":string(group,kAXDescriptionAttribute), "text":text(group), "messages":walk(group) { role($0) == "AXTextArea" }.map { string($0,kAXValueAttribute) }, "metadata":walk(group) { role($0) == "AXStaticText" }.map { e in ["text":string(e,kAXValueAttribute),"help":string(e,kAXHelpAttribute)] }, "canReply": !buttons(group,"Reply").isEmpty] }
func main() throws -> [String:Any] {
    guard CommandLine.arguments.count == 2, let p = try JSONSerialization.jsonObject(with:Data(CommandLine.arguments[1].utf8)) as? [String:String] else { throw Failure("Expected one JSON argument containing string parameters.") }
    func required(_ key: String) throws -> String { guard let v = p[key], !v.isEmpty else { throw Failure("Missing \(key)") }; return v }
    guard AXIsProcessTrusted() else { throw Failure("Accessibility access is required for the host running iwork-mcp.") }
    let bundleID = try required("bundleID"), name = try required("documentName"), op = try required("operation")
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first(where: { $0.bundleURL?.lastPathComponent == (p["appName"] ?? "") + ".app" }) else { throw Failure("App is not running.") }
    let process = AXUIElementCreateApplication(app.processIdentifier)
    let windows = attribute(process,kAXWindowsAttribute) as? [AXUIElement] ?? []
    let matching = windows.filter { let title = string($0,kAXTitleAttribute); return title == name || title == (name as NSString).deletingPathExtension }
    guard matching.count == 1 else { throw Failure("Cannot uniquely identify the document window.") }
    let win = matching[0]
    let frontWindow = attribute(process,kAXFocusedWindowAttribute)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier || frontWindow == nil || !CFEqual(frontWindow! as CFTypeRef,win) {
        app.activate(options:[]); AXUIElementPerformAction(win,kAXRaiseAction as CFString)
    }
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.2))
    func verifyWindow() throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let front = attribute(process,kAXFocusedWindowAttribute), CFEqual(front as CFTypeRef,win) else { throw Failure("Active document changed; stopped. Keep the target document in front while the tool runs.") }
    }
    func showSidebar() throws {
        let sidebarVisible = !walk(win) { role($0) == "AXButton" && string($0,kAXHelpAttribute).contains("sort order and visibility for comments") }.isEmpty
        if !sidebarVisible, let toggle = walk(win, { role($0) == "AXButton" && string($0,kAXHelpAttribute).contains("show or hide the Comments") }).first { try press(toggle) }
    }
    func currentGroups() -> [AXUIElement] {
        var result = groups(win)
        func addAncestors(_ element: AXUIElement) {
            var e = element
            var candidates: [AXUIElement] = []
            var belongsToWindow = false
            for _ in 0..<20 {
                if CFEqual(e,win) { belongsToWindow = true; break }
                if role(e) == "AXUnknown" && string(e,kAXDescriptionAttribute).hasPrefix("Comment from ") { candidates.append(e) }
                if role(e) == "AXPopover" { candidates.append(contentsOf:groups(e)) }
                guard let parent = attribute(e,kAXParentAttribute) else { break }; e = parent as! AXUIElement
            }
            if belongsToWindow { for group in candidates where !result.contains(where:{ CFEqual($0,group) }) { result.append(group) } }
        }
        if let focused = attribute(process,kAXFocusedUIElementAttribute) { addAncestors(focused as! AXUIElement) }
        // Numbers omits cell-comment popovers from AXChildren. Hit-testing their
        // surroundings still exposes the native comment group and its controls.
        if bundleID.contains("Numbers") && result.isEmpty {
            let selected = walk(win) { role($0) == "AXCell" && attribute($0,kAXSelectedAttribute) as? Bool == true && label($0).contains("comment") }
            for cell in selected {
                guard let raw = attribute(cell,"AXFrame") else { continue }
                var frame = CGRect.zero
                guard AXValueGetValue(raw as! AXValue,.cgRect,&frame) else { continue }
                outer: for dy in [0,40,-40,80,-80,120,-120,160,-160,200,-200,240,280,320] {
                    for dx in [80,120,160,200,240,280,320,360,400,40,0,-40,-80,-120,-160,-200,-240,-280,-320] {
                        var hit: AXUIElement?
                        if AXUIElementCopyElementAtPosition(process,Float(frame.midX + CGFloat(dx)),Float(frame.midY + CGFloat(dy)),&hit) == .success, let hit = hit { addAncestors(hit) }
                        if !result.isEmpty { break outer }
                    }
                }
            }
        }
        return result
    }
    try verifyWindow(); try showSidebar()
    if op == "list" {
        if bundleID.contains("Numbers") {
            let cells = walk(win) { role($0) == "AXCell" && attribute($0,kAXSelectedAttribute) as? Bool == true && label($0).contains("comment") }
            if let cell = cells.first { AXUIElementPerformAction(cell,"TSAccessibilityShowCommentAction" as CFString); RunLoop.current.run(until:Date(timeIntervalSinceNow:0.2)) }
        }
        return ["documentName":name,"comments":currentGroups().map(record),"complete":false,"scope":bundleID.contains("Numbers") ? "The selected cell’s accessible comment thread only; other cells and sheets are not included." : "Accessible comments in the current window; hidden, filtered, or unloaded threads may be omitted."]
    }
    guard (buttons(win,"Done") + currentGroups().flatMap { buttons($0,"Done") }).isEmpty else { throw Failure("A comment draft is already open. Finish or cancel it before continuing.") }
    if op == "prepare" { return ["ready":true] }
    let message = try required("text")
    let before = currentGroups().flatMap { walk($0) { role($0) == "AXTextArea" } }.filter { string($0,kAXValueAttribute) == message }.count
    if op == "add" {
        if let target = p["targetText"] {
            let bodies = walk(win,body:true) { role($0) == "AXTextArea" && string($0,kAXDescriptionAttribute) == "Body" }
            guard let body = bodies.first(where:{string($0,kAXValueAttribute).contains(target)}) else { throw Failure("Target passage is not accessible. Scroll it into view first.") }
            let contents = string(body,kAXValueAttribute) as NSString
            let range = contents.range(of:target)
            let remainder = NSRange(location:range.location + range.length,length:contents.length-range.location-range.length)
            guard contents.range(of:target,range:remainder).location == NSNotFound else { throw Failure("Target passage is ambiguous; supply longer unique text.") }
            try set(body,kAXFocusedAttribute,kCFBooleanTrue)
            var cfRange = CFRange(location:range.location,length:range.length)
            guard let selection = AXValueCreate(.cfRange,&cfRange) else { throw Failure("Cannot construct selection.") }
            try set(body,kAXSelectedTextRangeAttribute,selection)
            guard string(body,kAXSelectedTextAttribute) == target else { throw Failure("Selected passage could not be verified.") }
        }
        try verifyWindow()
        let controls = walk(win) { role($0) == "AXButton" && string($0,kAXIdentifierAttribute) == "ToolbarItemComment" }
        guard controls.count == 1 else { throw Failure("Comment toolbar button unavailable.") }
        try press(controls[0]); try showSidebar()
    } else if op == "reply" {
        let target = try required("commentText")
        let matches = currentGroups().filter { text($0) == target }
        guard matches.count == 1, let reply = buttons(matches[0],"Reply").first else { throw Failure("Comment must match exactly one accessible replyable thread; list again.") }
        try verifyWindow(); try press(reply)
    } else { throw Failure("Unknown operation") }
    let editorGroups = currentGroups()
    let editors = editorGroups.flatMap { walk($0) { role($0) == "AXTextArea" && (attribute($0,kAXFocusedAttribute) as? Bool == true) } }
    guard editors.count == 1 else { throw Failure("Cannot uniquely identify comment editor; inspect the app before retrying.") }
    try set(editors[0],kAXValueAttribute,message as CFString)
    RunLoop.current.run(until:Date(timeIntervalSinceNow:0.1))
    let done = editorGroups.flatMap { buttons($0,"Done") }.filter { attribute($0,kAXEnabledAttribute) as? Bool == true }
    guard done.count == 1 else { throw Failure("Cannot uniquely identify Done; draft left open.") }
    try verifyWindow(); try press(done[0])
    return ["documentName":name,"submitted":true,"text":message,"beforeCount":before]

}
do { let result = try main(); print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!) }
catch { fputs("\(error)\n",stderr); exit(1) }
