// freeze-shot: captura con la pantalla CONGELADA. Toma una foto de todos los monitores al instante,
// la muestra encima a pantalla completa y se elige sobre esa foto (lo que pase debajo, p. ej.
// mensajes nuevos, no cambia la imagen). Resultado → portapapeles (PNG).
//   pasar el mouse = resalta la ventana · clic = esa ventana · clic en la barra de menú = monitor
//   completo · arrastrar = área · Esc = cancelar. Suena el obturador de macOS al capturar.
// Necesita permiso de Grabación de pantalla (lo hereda de quien lo ejecuta, p. ej. skhd).
import AppKit
import ApplicationServices

// ---------- Foto de cada monitor (screencapture -x, un archivo por monitor) ----------
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-shot-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displays, &displayCount)

// Ventanas visibles en el momento de congelar, de adelante hacia atrás (coordenadas globales,
// arriba-izquierda). Solo apps normales: JankyBorders y similares también dibujan ventanas.
struct FrozenWin { let id: CGWindowID; let r: CGRect }
let windowsAtFreeze: [FrozenWin] = {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 40, ht > 40 else { return nil }
        return FrozenWin(id: id, r: CGRect(x: x, y: y, width: wd, height: ht))
    }
}()

let files = (0..<displays.count).map { tmp.appendingPathComponent("d\($0).png").path }
let cap = Process()
cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
cap.arguments = ["-x"] + files            // -x: sin sonido; un archivo por monitor, en el orden de la lista
try? cap.run(); cap.waitUntilExit()

// Cada ventana por separado (screencapture -l: solo esa ventana, sin lo que tenga encima), en
// paralelo y en segundo plano mientras el usuario elige. -o: sin la sombra.
let winDir = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-shot-win-\(getpid())")
try? FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
var winProcs: [CGWindowID: Process] = [:]
for w in windowsAtFreeze {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(w.id), winDir.appendingPathComponent("\(w.id).png").path]
    try? p.run()
    winProcs[w.id] = p
}
func windowImage(_ id: CGWindowID) -> CGImage? {
    winProcs[id]?.waitUntilExit()                       // normalmente ya terminó
    let f = winDir.appendingPathComponent("\(id).png")
    defer { try? FileManager.default.removeItem(at: winDir) }
    guard let src = CGImageSourceCreateWithURL(f as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}

var shots: [CGDirectDisplayID: CGImage] = [:]
for (i, d) in displays.enumerated() {
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: files[i]) as CFURL, nil),
       // cargarla ya (por defecto se decodifica al dibujar, y el archivo se borra enseguida → negro)
       let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
        shots[d] = img
    }
}
try? FileManager.default.removeItem(at: tmp)
if shots.isEmpty {
    FileHandle.standardError.write("freeze-shot: sin permiso de Grabación de pantalla\n".data(using: .utf8)!)
    exit(1)
}

// ---------- Interfaz ----------
let mainH = NSScreen.screens[0].frame.height
var overlays: [NSWindow] = []

let shutter = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

func finish(_ image: CGImage?) {
    try? FileManager.default.removeItem(at: winDir)   // capturas por ventana que no se usaron
    guard let img = image, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { exit(1) }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(png, forType: .png)
    // quitar la foto congelada ya y dejar sonar el obturador (el mismo de las capturas de macOS)
    for o in overlays { o.orderOut(nil) }
    shutter?.play()
    resumeAutoRaise()
    // archivo para poder editarla después (se borran los de más de un día)
    let file = shotsDir.appendingPathComponent("Captura \(stamp()).png")
    try? png.write(to: file)
    showThumbnail(img, file: file)
}

// ---------- Después de capturar: miniatura → Vista Previa con Markup → portapapeles ----------
let shotsDir: URL = {
    // En una carpeta normal (Imágenes): en Caches, Vista Previa no edita el original y obliga a
    // guardar una copia al cerrar
    let d = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("freeze-shot")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
        if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(m) > 86_400 { try? FileManager.default.removeItem(at: f) }
    }
    return d
}()
func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"; return f.string(from: Date())
}
// El script de ⌥⇧S pausa AutoRaise mientras se elige; se reanuda en cuanto se captura (no al cerrar
// el editor). Si EdgeSync lo tenía pausado por su cuenta, se respeta.
func resumeAutoRaise() {
    guard !FileManager.default.fileExists(atPath: "/tmp/edgesync-autoraise-paused") else { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); p.arguments = ["-CONT", "-x", "AutoRaise"]
    try? p.run()
}

final class ThumbView: NSImageView {
    var onClick: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

var thumbWin: NSWindow? = nil
func showThumbnail(_ img: CGImage, file: URL) {
    let mouse = NSEvent.mouseLocation
    let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens[0]
    let maxW: CGFloat = 240, maxH: CGFloat = 160
    let ratio = CGFloat(img.width) / CGFloat(img.height)
    var size = NSSize(width: maxW, height: maxW / ratio)
    if size.height > maxH { size = NSSize(width: maxH * ratio, height: maxH) }
    let vf = scr.visibleFrame
    let frame = NSRect(x: vf.minX + 48, y: vf.minY + 48, width: size.width, height: size.height)   // abajo a la izquierda
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .floating; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
    w.collectionBehavior = [.canJoinAllSpaces, .transient]
    let v = ThumbView(frame: NSRect(origin: .zero, size: size))
    v.image = NSImage(cgImage: img, size: size)
    v.imageScaling = .scaleProportionallyUpOrDown
    v.wantsLayer = true
    v.layer?.cornerRadius = 8; v.layer?.masksToBounds = true
    v.layer?.borderWidth = 1; v.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
    v.onClick = { thumbWin?.orderOut(nil); openInMarkup(file) }
    w.contentView = v
    w.orderFrontRegardless()
    thumbWin = w
    // sin clic en ~5 s: desaparece y termina (la captura ya está en el portapapeles)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        if !editing { thumbWin?.orderOut(nil); exit(0) }
    }
}

var editing = false
let previewID = "com.apple.Preview"

// Abre la captura en Vista Previa con la barra de Markup y, cada vez que se guarda (Vista Previa
// guarda sola al cerrar con Cmd+W), copia la versión editada al portapapeles. Termina cuando
// Vista Previa ya no tiene abierta la captura.
func openInMarkup(_ file: URL) {
    editing = true
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previewID) else { exit(0) }
    NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: cfg) { app, _ in
        guard let pid = app?.processIdentifier else { return }
        // Cmd+Shift+A = mostrar la barra de Markup (cuando la ventana ya esté lista)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)   // A
                e?.flags = [.maskCommand, .maskShift]
                e?.postToPid(pid)
            }
        }
    }
    var lastMod = modDate(file)
    var sawWindow = false
    let started = Date()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
        let m = modDate(file)
        if m != lastMod, let d = try? Data(contentsOf: file), !d.isEmpty {
            lastMod = m
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(d, forType: .png)
        }
        let open = previewHasFile(file)
        if open { sawWindow = true }
        // cerrada (o 30 min sin cerrar): última copia y salir
        if (sawWindow && !open) || Date().timeIntervalSince(started) > 1800 || (!sawWindow && Date().timeIntervalSince(started) > 15) {
            t.invalidate()
            if let d = try? Data(contentsOf: file), !d.isEmpty, modDate(file) != nil {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(d, forType: .png)
            }
            exit(0)
        }
    }
}
func modDate(_ f: URL) -> Date? { try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
// ¿Vista Previa tiene una ventana con este archivo? (atributo AXDocument de sus ventanas)
func previewHasFile(_ file: URL) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: previewID).first else { return false }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement] else { return false }
    let name = file.lastPathComponent
    for w in wins {
        var doc: CFTypeRef?, title: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &doc)
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
        if let d = doc as? String, d.removingPercentEncoding?.hasSuffix(name) == true || d.hasSuffix(name) { return true }
        if let t = title as? String, t.hasPrefix((name as NSString).deletingPathExtension) { return true }
    }
    return false
}

// Cursor en cruz propio: líneas blancas con borde oscuro (se ve sobre cualquier fondo) y un hueco
// en el centro para ver el pixel exacto
let crossCursor: NSCursor = {
    let size: CGFloat = 33, c = size / 2, gap: CGFloat = 3, arm: CGFloat = 14
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        func lines() {
            ctx.move(to: CGPoint(x: c - arm, y: c)); ctx.addLine(to: CGPoint(x: c - gap, y: c))
            ctx.move(to: CGPoint(x: c + gap, y: c)); ctx.addLine(to: CGPoint(x: c + arm, y: c))
            ctx.move(to: CGPoint(x: c, y: c - arm)); ctx.addLine(to: CGPoint(x: c, y: c - gap))
            ctx.move(to: CGPoint(x: c, y: c + gap)); ctx.addLine(to: CGPoint(x: c, y: c + arm))
        }
        ctx.setLineCap(.square)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor); ctx.setLineWidth(3); lines(); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1); lines(); ctx.strokePath()
        return true
    }
    return NSCursor(image: img, hotSpot: NSPoint(x: c, y: c))
}()

final class Overlay: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ShotView: NSView {
    let image: CGImage
    let screenFrame: NSRect          // coordenadas de Cocoa
    var start: NSPoint? = nil
    var current: NSPoint? = nil
    var hover: NSRect? = nil         // ventana bajo el mouse (coordenadas de la vista)

    init(image: CGImage, screenFrame: NSRect) {
        self.image = image; self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: crossCursor) }
    override func cursorUpdate(with event: NSEvent) { crossCursor.set() }
    // mouseMoved en todos los monitores, no solo en la ventana que tiene el teclado
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    var dragging: Bool {
        guard let s = start, let c = current else { return false }
        return abs(c.x - s.x) > 4 || abs(c.y - s.y) > 4
    }
    var selection: NSRect? {
        if dragging, let s = start, let c = current {
            return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
        }
        return hover
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        if let sel = selection {
            ctx.addRect(bounds); ctx.addRect(sel)
            ctx.fillPath(using: .evenOdd)              // oscurece todo menos la selección
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(dragging ? 1 : 2)
            ctx.stroke(sel.insetBy(dx: 1, dy: 1))
        } else {
            ctx.fill(bounds)
        }
    }

    // vista (Cocoa, origen abajo-izq) → recorte en píxeles de la foto (Retina = 2×)
    func crop(_ r: NSRect) -> CGImage? {
        let sx = CGFloat(image.width) / bounds.width, sy = CGFloat(image.height) / bounds.height
        let px = CGRect(x: r.minX * sx, y: (bounds.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy).integral
        return image.cropping(to: px)
    }

    // Alto de la barra de menú (la mayor entre monitores: a veces un secundario dice que no tiene)
    var menuBarHeight: CGFloat {
        NSScreen.screens.map { $0.frame.maxY - $0.visibleFrame.maxY }.max() ?? 0
    }
    // Sobre la barra de menú → el monitor completo; si no, la ventana bajo el mouse
    func targetAt(_ p: NSPoint) -> NSRect? {
        if p.y >= bounds.height - max(menuBarHeight, 24) { return bounds }
        return windowAt(p)
    }

    func windowAt(_ p: NSPoint) -> NSRect? {
        let g = CGPoint(x: screenFrame.minX + p.x, y: mainH - (screenFrame.minY + p.y))   // global arriba-izq
        guard let w = windowsAtFreeze.first(where: { $0.r.contains(g) })?.r else { return nil }
        let r = NSRect(x: w.minX - screenFrame.minX, y: (mainH - w.maxY) - screenFrame.minY, width: w.width, height: w.height)
        return r.intersection(bounds)                  // solo la parte de este monitor
    }

    func setHover(_ p: NSPoint) {
        let h = targetAt(p)
        if h != hover { hover = h; needsDisplay = true }
        for o in overlays where o != window {          // los otros monitores sin resaltado
            if let v = o.contentView as? ShotView, v.hover != nil { v.hover = nil; v.needsDisplay = true }
        }
    }

    // el cursor se fija en cada movimiento: en ventanas sin foco macOS volvería a la flecha
    override func mouseMoved(with e: NSEvent) { crossCursor.set(); setHover(convert(e.locationInWindow, from: nil)) }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        start = p; current = p
    }
    override func mouseDragged(with e: NSEvent) {
        crossCursor.set()
        current = convert(e.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        if dragging, let sel = selection { finish(crop(sel)); return }
        // clic sin arrastrar: la ventana bajo el mouse (su captura aislada, sin lo que tenga encima),
        // o el monitor entero si es sobre la barra de menú
        let p = current!
        if let r = targetAt(p) {
            if r == bounds { finish(crop(r)); return }
            let g = CGPoint(x: screenFrame.minX + p.x, y: mainH - (screenFrame.minY + p.y))
            if let w = windowsAtFreeze.first(where: { $0.r.contains(g) }), let img = windowImage(w.id) { finish(img); return }
            finish(crop(r))                            // si falló la captura aislada: recorte de la foto
        }
        start = nil; current = nil; needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { finish(nil) }             // Esc
    }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

for scr in NSScreen.screens {
    guard let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let img = shots[CGDirectDisplayID(num.uint32Value)] else { continue }
    let w = Overlay(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .screenSaver
    w.isOpaque = true
    w.hasShadow = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let v = ShotView(image: img, screenFrame: scr.frame)
    w.contentView = v
    w.setFrame(scr.frame, display: true)
    overlays.append(w)
}

// Teclado (Esc) en el monitor del mouse; resaltar ya la ventana que está bajo el mouse
let mouse = NSEvent.mouseLocation
let keyOverlay = overlays.first { NSMouseInRect(mouse, $0.frame, false) } ?? overlays.first
for o in overlays { o.orderFrontRegardless() }
app.activate(ignoringOtherApps: true)
keyOverlay?.makeKeyAndOrderFront(nil)
crossCursor.set()
if let v = keyOverlay?.contentView as? ShotView {
    keyOverlay?.makeFirstResponder(v)
    v.setHover(v.convert(keyOverlay!.mouseLocationOutsideOfEventStream, from: nil))
}
app.run()
