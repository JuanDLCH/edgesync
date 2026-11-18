// win-grid: reparte en partes iguales las ventanas (no flotantes) del monitor bajo el mouse,
// según dónde está cada una. 1 → pantalla, 2 → mitades, 3 → izquierda + dos apiladas a la
// derecha, 4 → dwindle (izquierda, arriba-derecha, abajo-derecha partido en dos). Con más de 4 no hace nada.
// Lo ejecuta skhd (Option+G) y usa su permiso de Accesibilidad.
import AppKit
import ApplicationServices

if FileManager.default.fileExists(atPath: "/tmp/edgesync.debug") {
    let l = "\(Date()) win-grid ejecutado (ppid \(getppid()))\n"
    if let h = FileHandle(forWritingAtPath: "/tmp/win-grid.log") { h.seekToEndOfFile(); h.write(l.data(using: .utf8)!) }
    else { FileManager.default.createFile(atPath: "/tmp/win-grid.log", contents: l.data(using: .utf8)) }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let gap: CGFloat = 10, margin: CGFloat = 8
let floating: Set<String> = ["com.apple.systempreferences", "com.apple.calculator", "com.apple.ActivityMonitor",
                             "com.apple.archiveutility", "com.apple.screencaptureui", "com.apple.SecurityAgent"]

struct W { let id: CGWindowID; let pid: pid_t; let r: CGRect }

// ---------- win-grid max: ampliar la ventana enfocada sobre las demás / devolverla ----------
// No es pantalla completa de macOS: la ventana ocupa el área útil de su monitor (con márgenes),
// encima de las otras. Otra vez → vuelve a donde estaba (se guarda en /tmp/win-grid-max).
func setFrame(_ a: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(a, kAXSizeAttribute as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(a, kAXPositionAttribute as CFString, pv) }
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(a, kAXSizeAttribute as CFString, sv) }
}
func frameOf(_ a: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(a, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(a, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
// ---------- win-grid focus left|right|up|down: foco a la ventana más cercana en esa dirección ----------
// Entre todas las ventanas visibles de todos los monitores (así cruza de pantalla). El mouse salta
// al centro de la ventana nueva (si no, AutoRaise devolvería el foco a la que está bajo el mouse).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "focus" {
    let dir = CommandLine.arguments[2]
    let mh = NSScreen.screens[0].frame.height
    // ventana enfocada (si no hay, se parte de la posición del mouse)
    var from = CGRect(x: NSEvent.mouseLocation.x, y: mh - NSEvent.mouseLocation.y, width: 1, height: 1)
    var fromId: CGWindowID = 0
    if let front = NSWorkspace.shared.frontmostApplication {
        var win: CFTypeRef?
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win {
            let a = w as! AXUIElement
            if let f = frameOf(a) { from = f }
            _ = _AXUIElementGetWindow(a, &fromId)
        }
    }
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: (id: CGWindowID, pid: pid_t, r: CGRect, score: CGFloat)? = nil
    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let id = w[kCGWindowNumber as String] as? CGWindowID, id != fromId,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 80, ht > 80 else { continue }
        let r = CGRect(x: x, y: y, width: wd, height: ht)
        let dx = r.midX - from.midX, dy = r.midY - from.midY
        // en la dirección pedida (centro más allá del centro actual) y puntaje: distancia en esa
        // dirección + el doble del desvío lateral (prefiere la que está "enfrente")
        let along: CGFloat, side: CGFloat
        switch dir {
        case "left":  along = -dx; side = abs(dy)
        case "right": along = dx;  side = abs(dy)
        case "up":    along = -dy; side = abs(dx)
        default:      along = dy;  side = abs(dx)
        }
        guard along > 20 else { continue }
        let score = along + 2 * side
        if best == nil || score < best!.score { best = (id, pid, r, score) }
    }
    guard let t = best else { exit(0) }
    // Un proceso de fondo no puede activar apps con NSRunningApplication.activate() (macOS lo
    // ignora); por Accesibilidad sí: la app pasa al frente y luego se elige su ventana
    let tApp = AXUIElementCreateApplication(t.pid)
    AXUIElementSetAttributeValue(tApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(tApp, kAXWindowsAttribute as CFString, &v) == .success,
       let wins = v as? [AXUIElement],
       let a = wins.first(where: { var wid: CGWindowID = 0; return _AXUIElementGetWindow($0, &wid) == .success && wid == t.id }) {
        AXUIElementPerformAction(a, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(a, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(a, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    CGWarpMouseCursorPosition(CGPoint(x: t.r.midX, y: t.r.midY))
    CGAssociateMouseAndMouseCursorPosition(1)
    exit(0)
}

if CommandLine.arguments.contains("max") {
    // App al frente → su ventana enfocada (o la principal)
    func fail(_ m: String) -> Never { FileHandle.standardError.write("win-grid max: \(m)\n".data(using: .utf8)!); exit(1) }
    guard let front = NSWorkspace.shared.frontmostApplication else { fail("sin app al frente") }
    let appEl = AXUIElementCreateApplication(front.processIdentifier)
    var win: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) != .success || win == nil {
        guard AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &win) == .success, win != nil else {
            fail("\(front.localizedName ?? "?") no tiene ventana enfocada (¿permiso de Accesibilidad?)")
        }
    }
    let a = win as! AXUIElement
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(a, &id) == .success, let cur = frameOf(a) else { exit(1) }
    // Área útil del monitor donde está la ventana (misma regla de márgenes que el resto)
    let mh = NSScreen.screens[0].frame.height
    let c = NSPoint(x: cur.midX, y: mh - cur.midY)
    let scr = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.screens[0]
    let barH = NSScreen.screens.map { $0.frame.maxY - $0.visibleFrame.maxY }.max() ?? 0
    let t = mh - scr.frame.maxY + max(barH, scr.frame.maxY - scr.visibleFrame.maxY)
    let b = mh - scr.visibleFrame.minY
    let area = CGRect(x: scr.visibleFrame.minX + margin, y: t, width: scr.visibleFrame.width - 2 * margin, height: b - margin - t)

    let file = "/tmp/win-grid-max"
    var saved: [CGWindowID: CGRect] = [:]
    for l in ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n") {
        let f = l.split(separator: " ").compactMap { Double($0) }
        if f.count == 5 { saved[CGWindowID(f[0])] = CGRect(x: f[1], y: f[2], width: f[3], height: f[4]) }
    }
    let isMax = abs(cur.minX - area.minX) < 12 && abs(cur.minY - area.minY) < 12 &&
                abs(cur.width - area.width) < 12 && abs(cur.height - area.height) < 12
    if isMax, let back = saved[id] {
        setFrame(a, back); saved[id] = nil
    } else {
        saved[id] = cur
        setFrame(a, area)
        AXUIElementPerformAction(a, kAXRaiseAction as CFString)
    }
    let out = saved.map { "\($0.key) \($0.value.minX) \($0.value.minY) \($0.value.width) \($0.value.height)" }.joined(separator: "\n")
    try? out.write(toFile: file, atomically: true, encoding: .utf8)
    exit(0)
}

// Monitor bajo el mouse (coordenadas arriba-izquierda)
let mainH = NSScreen.screens[0].frame.height
func tl(_ f: NSRect) -> CGRect { CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height) }
let m = NSEvent.mouseLocation
guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { exit(1) }
let full = tl(screen.frame)
// Área útil: macOS a veces dice que un monitor secundario no tiene barra de menú aunque se ve,
// así que se usa la barra más alta. Pegadas a la barra arriba; `margin` a los lados y abajo.
let bar = NSScreen.screens.map { $0.frame.maxY - $0.visibleFrame.maxY }.max() ?? 0
let top = mainH - screen.frame.maxY + max(bar, screen.frame.maxY - screen.visibleFrame.maxY)
let bottom = mainH - screen.visibleFrame.minY
let vis = CGRect(x: screen.visibleFrame.minX + margin, y: top,
                 width: screen.visibleFrame.width - 2 * margin, height: bottom - margin - top)

// Ventanas visibles de ese monitor
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
// Ventanas que el usuario sacó del mosaico (las guarda EdgeSync): no se tocan
let userFloating = Set(((try? String(contentsOfFile: "/tmp/edgesync-floating", encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { CGWindowID($0) })
var wins: [W] = []
for w in info {
    guard (w[kCGWindowLayer as String] as? Int) == 0,
          let id = w[kCGWindowNumber as String] as? CGWindowID,
          let pid = w[kCGWindowOwnerPID as String] as? pid_t,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 20, ht > 20 else { continue }
    let r = CGRect(x: x, y: y, width: wd, height: ht)
    // solo apps normales (las de JankyBorders y otras sin Dock también son ventanas de nivel 0)
    guard full.contains(CGPoint(x: r.midX, y: r.midY)),
          let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
          !floating.contains(app.bundleIdentifier ?? ""), !userFloating.contains(id) else { continue }
    wins.append(W(id: id, pid: pid, r: r))
}
// -v: solo listar (no mover nada)
if CommandLine.arguments.contains("-v") {
    for w in wins { print(w.id, w.pid, NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "?", w.r) }
    exit(0)
}
guard (1...4).contains(wins.count) else { exit(0) }

// Celdas
let hw = (vis.width - gap) / 2, hh = (vis.height - gap) / 2
let L  = CGRect(x: vis.minX, y: vis.minY, width: hw, height: vis.height)
let R  = CGRect(x: vis.minX + hw + gap, y: vis.minY, width: hw, height: vis.height)
let TL = CGRect(x: vis.minX, y: vis.minY, width: hw, height: hh)
let TR = CGRect(x: vis.minX + hw + gap, y: vis.minY, width: hw, height: hh)
let BL = CGRect(x: vis.minX, y: vis.minY + hh + gap, width: hw, height: hh)
let BR = CGRect(x: vis.minX + hw + gap, y: vis.minY + hh + gap, width: hw, height: hh)

func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }
// Reparto que minimiza lo que se mueven las ventanas (prueba todas las combinaciones, son ≤ 24)
func assign(_ ws: [W], _ cells: [CGRect]) -> [(W, CGRect)] {
    func perms(_ a: [Int]) -> [[Int]] {
        if a.count <= 1 { return [a] }
        var out: [[Int]] = []
        for i in a.indices {
            var rest = a; rest.remove(at: i)
            for p in perms(rest) { out.append([a[i]] + p) }
        }
        return out
    }
    func cost(_ p: [Int]) -> CGFloat {
        var c: CGFloat = 0
        for (i, w) in ws.enumerated() { c += dist(w.r, cells[p[i]]) }
        return c
    }
    let best = perms(Array(cells.indices)).min { cost($0) < cost($1) }!
    return ws.enumerated().map { ($0.element, cells[best[$0.offset]]) }
}

var plan: [(W, CGRect)]
switch wins.count {
case 1: plan = [(wins[0], vis)]
case 2: plan = assign(wins, [L, R])
case 3:
    let left = wins.min { $0.r.midX < $1.r.midX }!
    plan = [(left, L)] + assign(wins.filter { $0.id != left.id }, [TR, BR])
default:
    // dwindle: 1 columna izquierda, 2 arriba a la derecha, 3 y 4 se reparten abajo a la derecha
    let left = wins.min { $0.r.midX < $1.r.midX }!
    let bw = (BR.width - gap) / 2
    let BRa = CGRect(x: BR.minX, y: BR.minY, width: bw, height: BR.height)
    let BRb = CGRect(x: BR.minX + bw + gap, y: BR.minY, width: bw, height: BR.height)
    plan = [(left, L)] + assign(wins.filter { $0.id != left.id }, [TR, BRa, BRb])
}

for (w, r) in plan {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &v) == .success,
          let axs = v as? [AXUIElement],
          let a = axs.first(where: { var id: CGWindowID = 0; return _AXUIElementGetWindow($0, &id) == .success && id == w.id }) else { continue }
    var p = r.origin, s = r.size
    // tamaño → posición → tamaño: algunas apps recortan el tamaño si aún no se han movido
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(a, kAXSizeAttribute as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(a, kAXPositionAttribute as CFString, pv) }
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(a, kAXSizeAttribute as CFString, sv) }
}
