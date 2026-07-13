import SwiftUI
import MetalKit
import UIKit

/// MTKView that pulls BGRA frames from Rust soft-render buffer and owns
/// hardware-keyboard capture, soft keyboard, touch, pan/zoom.
struct MetalRemoteView: UIViewRepresentable {
    @ObservedObject var session: SessionController
    var onSize: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    /// Matches SwiftUI card radius; CAMetalLayer ignores clipShape without this.
    static let cornerRadius: CGFloat = 14

    func makeUIView(context: Context) -> TouchMetalView {
        let v = TouchMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.coordinator = context.coordinator
        v.session = session
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.delegate = context.coordinator
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.preferredFramesPerSecond = 60
        v.isMultipleTouchEnabled = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // MTKView / CAMetalLayer: SwiftUI clipShape alone does nothing — need layer mask.
        v.layer.cornerRadius = Self.cornerRadius
        v.layer.cornerCurve = .continuous
        v.layer.masksToBounds = true
        v.clipsToBounds = true
        context.coordinator.attach(view: v)
        DispatchQueue.main.async {
            _ = v.becomeFirstResponder()
        }
        return v
    }

    func updateUIView(_ uiView: TouchMetalView, context: Context) {
        context.coordinator.session = session
        uiView.session = session
        uiView.captureSystemShortcuts = session.captureSystemShortcuts
        uiView.setSoftKeyboard(session.softKeyboardVisible)
        uiView.layer.cornerRadius = Self.cornerRadius
        uiView.layer.cornerCurve = .continuous
        uiView.layer.masksToBounds = true
        uiView.clipsToBounds = true
        let size = uiView.bounds.size
        if size.width > 1, size.height > 1 {
            onSize(size)
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var session: SessionController
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var pipeline: MTLRenderPipelineState?
        private var tw = 0
        private var th = 0
        weak var view: TouchMetalView?

        init(session: SessionController) {
            self.session = session
        }

        func attach(view: TouchMetalView) {
            self.view = view
            device = view.device
            commandQueue = device?.makeCommandQueue()
            buildPipeline(view: view)
        }

        private func buildPipeline(view: MTKView) {
            guard let device else { return }
            // Simple textured quad. Rounded corners come from MTKView.layer (not fragment mask).
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            struct VOut { float4 pos [[position]]; float2 uv; };
            vertex VOut v_main(uint vid [[vertex_id]], constant float4 &vp [[buffer(0)]]) {
                float2 corners[4] = {
                    float2(vp.x,        vp.y),
                    float2(vp.x+vp.z,   vp.y),
                    float2(vp.x,        vp.y+vp.w),
                    float2(vp.x+vp.z,   vp.y+vp.w)
                };
                float2 uvs[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
                VOut o;
                o.pos = float4(corners[vid], 0, 1);
                o.uv = uvs[vid];
                return o;
            }
            fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
                constexpr sampler s(address::clamp_to_edge, filter::linear);
                if (in.uv.x < 0.0 || in.uv.x > 1.0 || in.uv.y < 0.0 || in.uv.y > 1.0)
                    return float4(0,0,0,1);
                return tex.sample(s, in.uv);
            }
            """
            guard let lib = try? device.makeLibrary(source: src, options: nil),
                  let vfn = lib.makeFunction(name: "v_main"),
                  let ffn = lib.makeFunction(name: "f_main")
            else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Zero-copy path: upload BGRA straight from Rust buffer (no intermediate Data).
            _ = session.withLatestFrame { pixels, w, h, bpr in
                upload(pixels: pixels, width: w, height: h, bytesPerRow: bpr)
            }
            if let tv = view as? TouchMetalView {
                tv.updateCursorOverlay()
            }
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let pipeline,
                  let cq = commandQueue,
                  let cmd = cq.makeCommandBuffer()
            else { return }

            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)

            if let texture {
                // Map content rect → NDC: x,y,w,h where full view is (-1,-1) to (1,1)
                var vp = contentRectNDC(in: view)
                enc.setVertexBytes(&vp, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                enc.setFragmentTexture(texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }

        /// Content rect in NDC based on letterbox fit + user pan/zoom.
        private func contentRectNDC(in view: MTKView) -> SIMD4<Float> {
            guard let tv = view as? TouchMetalView else {
                return SIMD4<Float>(-1, -1, 2, 2)
            }
            let r = tv.contentRect()
            let vw = max(view.bounds.width, 1)
            let vh = max(view.bounds.height, 1)
            // UIKit y-down → NDC y-up
            let x0 = Float(r.minX / vw) * 2 - 1
            let x1 = Float(r.maxX / vw) * 2 - 1
            let y0 = 1 - Float(r.maxY / vh) * 2
            let y1 = 1 - Float(r.minY / vh) * 2
            return SIMD4<Float>(x0, y0, x1 - x0, y1 - y0)
        }

        private func upload(pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
            guard let device, width > 0, height > 0 else { return }
            if texture == nil || tw != width || th != height {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                desc.usage = [.shaderRead]
                desc.storageMode = .shared
                texture = device.makeTexture(descriptor: desc)
                tw = width
                th = height
            }
            guard let texture else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: bytesPerRow
            )
        }
    }
}

// MARK: - Touch + keyboard first-responder view

final class TouchMetalView: MTKView, UIKeyInput, RemoteGestureEngineDelegate {
    weak var coordinator: MetalRemoteView.Coordinator?
    weak var session: SessionController?

    var captureSystemShortcuts: Bool = true {
        didSet {
            if oldValue != captureSystemShortcuts {
                cachedPriorityCommands = nil
                // Only refresh HW first-responder when soft keyboard is off.
                if !softKeyboardOn { refreshHardwareFirstResponder() }
            }
        }
    }

    /// User zoom (1 = fit). Private set — mutated by viewport gestures.
    private(set) var userZoom: CGFloat = 1
    /// Pan offset in view points (applied after fit centering).
    private var panOffset: CGPoint = .zero
    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 6

    /// Unified gesture state machine (sole owner of pointer semantics).
    private let gestures = RemoteGestureEngine()

    private var softKeyboardOn = false
    private var keyboardObservers: [NSObjectProtocol] = []
    /// Fallback text field (subview of *this* view — never a secondary window /
    /// never a UIHostingController sibling that SwiftUI may strip).
    private lazy var softField: SoftKeyboardField = {
        let f = SoftKeyboardField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        f.delegate = f
        f.isHidden = false
        f.alpha = 0.01
        f.tintColor = .clear
        f.textColor = .clear
        f.backgroundColor = .clear
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartDashesType = .no
        f.smartQuotesType = .no
        f.smartInsertDeleteType = .no
        f.keyboardType = .default
        f.returnKeyType = .default
        f.textContentType = nil
        f.isEnabled = true
        // Interaction on is more reliable for FR; field is 1×1 under content and
        // hit-testing is overridden so sidebar/canvas never lose taps to it.
        f.isUserInteractionEnabled = true
        f.isAccessibilityElement = false
        f.text = SoftKeyboardField.sentinel
        f.onInsert = { [weak self] text in
            guard let self, self.softKeyboardOn else { return }
            if text == "\n" || text == "\r" {
                self.session?.handleKey(character: "\n", usbHid: 0x28, down: true)
                self.session?.handleKey(character: "\n", usbHid: 0x28, down: false)
            } else {
                self.session?.inputString(text)
            }
        }
        f.onDelete = { [weak self] in
            guard let self, self.softKeyboardOn else { return }
            self.session?.handleKey(character: "", usbHid: 0x2A, down: true)
            self.session?.handleKey(character: "", usbHid: 0x2A, down: false)
        }
        return f
    }()

    /// Remote peer cursor overlay (image from cursor_data / fallback arrow).
    private let cursorView = UIImageView()
    private var defaultCursorImage: UIImage?

    private var cachedPriorityCommands: [UIKeyCommand]?

    /// Last remote coords for blind mouse-up if needed.
    private var lastRemoteX = 0
    private var lastRemoteY = 0
    private var touchModeLeftDown = false

    /// Remote-cursor ON → cursor/trackpad mode; OFF → Sidecar touch mode.
    private var isCursorMode: Bool { session?.showRemoteCursor == true }

    // MARK: Setup

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        isMultipleTouchEnabled = true
        setupCursorOverlay()
        setupGestures()
        setupKeyboardNotifications()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        setupCursorOverlay()
        setupGestures()
        setupKeyboardNotifications()
    }

    private func setupGestures() {
        gestures.delegate = self
        gestures.config.minZoom = minZoom
        gestures.config.maxZoom = maxZoom
    }

    // MARK: RemoteGestureEngineDelegate

    var gestureEngineZoom: CGFloat { userZoom }

    func gestureEngine(_ engine: RemoteGestureEngine, didEmit action: RemoteGestureAction) {
        switch action {
        case .hover(let p):
            sendMouse(type: "move", point: p, buttons: "")
        case .leftDown(let p):
            sendMouse(type: "down", point: p, buttons: "left")
        case .leftUp(let p):
            sendMouse(type: "up", point: p, buttons: "left")
        case .leftClick(let p, let count):
            for _ in 0..<max(1, count) {
                sendMouse(type: "down", point: p, buttons: "left")
                sendMouse(type: "up", point: p, buttons: "left")
            }
        case .rightClick(let p):
            sendMouse(type: "move", point: p, buttons: "")
            sendMouse(type: "down", point: p, buttons: "right")
            sendMouse(type: "up", point: p, buttons: "right")
        case .moveCursor(let dx, let dy):
            guard let session else { return }
            let scale = contentToRemoteScale()
            let sens = gestures.config.cursorSensitivity
            session.moveCursorRemote(
                toX: session.cursorX + (dx / scale) * sens,
                y: session.cursorY + (dy / scale) * sens
            )
        case .leftClickAtCursor(let count):
            for _ in 0..<max(1, count) {
                session?.clickAtCursor(button: "left")
            }
        case .rightClickAtCursor:
            session?.clickAtCursor(button: "right")
        case .wheel(let x, let y):
            emit(["type": "wheel", "x": "\(x)", "y": "\(y)"])
        case .zoom(let z, let anchor):
            setZoom(z, anchor: anchor)
        case .panViewport(let dx, let dy):
            panOffset.x += dx
            panOffset.y += dy
            clampPan()
        case .resetViewport:
            resetViewport()
        case .haptic(let style):
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }

    deinit {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        SoftKeyboardHost.shared.hide(notify: false)
    }



    private func setupCursorOverlay() {
        cursorView.contentMode = .scaleAspectFit
        cursorView.isUserInteractionEnabled = false
        cursorView.isHidden = true
        cursorView.layer.zPosition = 1000
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.55
        cursorView.layer.shadowRadius = 1.2
        cursorView.layer.shadowOffset = CGSize(width: 0.5, height: 0.5)
        addSubview(cursorView)
        // Built-in arrow so something is visible before cursor_data arrives.
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        defaultCursorImage = UIImage(systemName: "cursorarrow", withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        cursorView.image = defaultCursorImage
    }

    /// Map remote display coords → view points (letterbox + pan/zoom).
    func mapFromRemote(x: CGFloat, y: CGFloat) -> CGPoint {
        let r = contentRect()
        let dw = CGFloat(max(1, session?.displayWidth ?? 1))
        let dh = CGFloat(max(1, session?.displayHeight ?? 1))
        return CGPoint(
            x: r.minX + (x / dw) * r.width,
            y: r.minY + (y / dh) * r.height
        )
    }

    /// Called each frame from the Metal draw loop.
    func updateCursorOverlay() {
        guard let session else {
            cursorView.isHidden = true
            return
        }
        let show = session.showRemoteCursor && session.cursorVisible && !session.cursorEmbedded
        guard show else {
            cursorView.isHidden = true
            return
        }

        let img = session.cursorImage ?? defaultCursorImage
        if cursorView.image !== img {
            cursorView.image = img
        }
        guard let img else {
            cursorView.isHidden = true
            return
        }

        // Scale cursor with content fit so it matches remote pixel size on screen.
        let r = contentRect()
        let dw = CGFloat(max(1, session.displayWidth))
        let scale = r.width / dw
        let hotX = session.cursorImage != nil ? session.cursorHotX : 0
        let hotY = session.cursorImage != nil ? session.cursorHotY : 0
        let iw = max(1, img.size.width)
        let ih = max(1, img.size.height)
        // Minimum ~12pt so tiny cursors stay visible on high-DPI.
        let drawScale = max(scale, 12 / max(iw, ih))
        let w = iw * drawScale
        let h = ih * drawScale
        let pt = mapFromRemote(x: session.cursorX, y: session.cursorY)
        cursorView.frame = CGRect(
            x: pt.x - hotX * drawScale,
            y: pt.y - hotY * drawScale,
            width: w,
            height: h
        )
        cursorView.isHidden = false
        bringSubviewToFront(cursorView)
    }

    private func setupKeyboardNotifications() {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers.removeAll()
        // Soft keyboard dismiss sync is owned by SoftKeyboardHost.onHide ONLY.
        // Do not clear softKeyboardOn from keyboardDidHide here: while the soft
        // keyboard is up, SoftKeyboardHost owns first responder (metal is not FR).
        // A hide notification during resign→become re-show would incorrectly
        // force softKeyboardVisible=false and block the second open.
    }

    // MARK: First responder / soft keyboard
    //
    // Soft keyboard is owned by *this* view via UIKeyInput — no secondary
    // UIWindow / UITextField. That avoids:
    //  • key-window restore killing the keyboard
    //  • full-screen overlay blocking sidebar taps
    //  • UIHostingController stripping unmanaged sibling text fields
    // Layout push is blocked by RemoteSessionHostController.

    /// Always claim FR: HW keys when soft keyboard off, system KB when on.
    override var canBecomeFirstResponder: Bool { true }

    /// Cached empty input view — returning a *new* UIView every access breaks
    /// reloadInputViews and can prevent the keyboard from appearing.
    private lazy var emptyInputView: UIView = {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }()

    /// `nil` → system software keyboard. Non-nil empty view → HW-only (no soft KB).
    override var inputView: UIView? {
        softKeyboardOn ? nil : emptyInputView
    }

    /// Prefer software keyboard when available (iPad may still hide it if a
    /// hardware keyboard is connected — system policy).
    override var inputAssistantItem: UITextInputAssistantItem {
        let item = super.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        return item
    }

    func setSoftKeyboard(_ on: Bool) {
        // Idempotent: updateUIView runs on every @Published tick (cursor, FPS, …).
        // Do NOT thrash FR — host owns FR while soft keyboard is up (metal is not FR).
        if on == softKeyboardOn {
            if on,
               SoftKeyboardHost.shared.isShowing,
               !SoftKeyboardHost.shared.isFieldFirstResponder {
                // Lost FR while toolbar still says "keyboard on" — re-show once.
                SoftKeyboardHost.shared.show(attachedTo: self)
            }
            return
        }
        softKeyboardOn = on
        if on {
            presentSoftKeyboard()
        } else {
            dismissSoftKeyboard()
        }
    }

    private func presentSoftKeyboard() {
        // Drop metal / local field FR so SoftKeyboardHost can own the key window.
        if isFirstResponder { resignFirstResponder() }
        if softField.isFirstResponder { softField.resignFirstResponder() }

        let host = SoftKeyboardHost.shared
        host.onInsert = { [weak self] text in
            guard let self, self.softKeyboardOn else { return }
            if text == "\n" || text == "\r" {
                self.session?.handleKey(character: "\n", usbHid: 0x28, down: true)
                self.session?.handleKey(character: "\n", usbHid: 0x28, down: false)
            } else {
                self.session?.inputString(text)
            }
        }
        host.onDelete = { [weak self] in
            guard let self, self.softKeyboardOn else { return }
            self.session?.handleKey(character: "", usbHid: 0x2A, down: true)
            self.session?.handleKey(character: "", usbHid: 0x2A, down: false)
        }
        host.onHide = { [weak self] in
            guard let self else { return }
            // User swipe-dismissed the keyboard — sync toolbar without fighting re-show.
            self.softKeyboardOn = false
            if self.session?.softKeyboardVisible == true {
                self.session?.softKeyboardVisible = false
            }
            self.claimHardwareFocus()
        }

        // Defer past the sidebar button touch-up so UIControl doesn't steal FR.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.softKeyboardOn else { return }
            host.show(attachedTo: self)
            // Fallback only if host never got FR (do not steal a working host).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.ensureSoftKeyboardVisibleLocalFallback()
            }
        }
    }

    /// Only used if SoftKeyboardHost did not become first responder.
    private func ensureSoftKeyboardVisibleLocalFallback() {
        guard softKeyboardOn else { return }
        let host = SoftKeyboardHost.shared
        if host.isShowing, host.isFieldFirstResponder {
            return // Host is healthy.
        }
        // Host failed — try once more, then local field.
        if host.isShowing {
            host.show(attachedTo: self)
            return
        }
        activateLocalSoftField()
    }

    private func activateLocalSoftField() {
        guard softKeyboardOn else { return }
        window?.makeKey()
        if softField.superview !== self {
            softField.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
            clipsToBounds = false
            addSubview(softField)
            sendSubviewToBack(softField)
        }
        softField.text = SoftKeyboardField.sentinel
        if isFirstResponder { resignFirstResponder() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.softKeyboardOn else { return }
            if !self.softField.becomeFirstResponder() {
                _ = self.becomeFirstResponder()
                self.reloadInputViews()
            }
        }
    }

    private func dismissSoftKeyboard() {
        SoftKeyboardHost.shared.hide(notify: false)
        if softField.isFirstResponder {
            softField.resignFirstResponder()
        }
        // Stay first responder for HW keys; empty inputView hides the soft keyboard.
        claimHardwareFocus()
    }

    private func claimHardwareFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.softKeyboardOn else { return }
            self.window?.makeKey()
            _ = self.becomeFirstResponder()
            self.reloadInputViews()
        }
    }

    private func refreshHardwareFirstResponder() {
        guard !softKeyboardOn else { return }
        if isFirstResponder {
            resignFirstResponder()
            _ = becomeFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if softKeyboardOn {
                SoftKeyboardHost.shared.show(attachedTo: self)
            } else {
                claimHardwareFocus()
            }
        }
    }

    // MARK: UIKeyInput (soft keyboard → remote)

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // Only accept insertText while soft keyboard mode is on.
        // HW keys while soft-off are handled by pressesBegan (avoids double-fire).
        guard softKeyboardOn else { return }
        if text == "\n" || text == "\r" {
            session?.handleKey(character: "\n", usbHid: 0x28, down: true)
            session?.handleKey(character: "\n", usbHid: 0x28, down: false)
        } else {
            session?.inputString(text)
        }
    }

    func deleteBackward() {
        guard softKeyboardOn else { return }
        session?.handleKey(character: "", usbHid: 0x2A, down: true)
        session?.handleKey(character: "", usbHid: 0x2A, down: false)
    }

    // MARK: Hardware key presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Soft keyboard / UIKeyInput owns character entry; still forward presses
        // for non-character keys when not capturing via insertText.
        if softKeyboardOn {
            super.pressesBegan(presses, with: event)
            return
        }
        if captureSystemShortcuts {
            handlePresses(presses, down: true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if softKeyboardOn {
            super.pressesEnded(presses, with: event)
            return
        }
        if captureSystemShortcuts {
            handlePresses(presses, down: false)
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if softKeyboardOn {
            super.pressesCancelled(presses, with: event)
            return
        }
        if captureSystemShortcuts {
            handlePresses(presses, down: false)
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    private func handlePresses(_ presses: Set<UIPress>, down: Bool) {
        for press in presses {
            guard let key = press.key else { continue }
            let usage = Int(key.keyCode.rawValue & 0xFFFF)
            guard usage != 0 else { continue }
            let chars = key.charactersIgnoringModifiers
            session?.handleKey(character: chars, usbHid: usage, down: down)
        }
    }

    // MARK: UIKeyCommand priority (steal ⌘C etc.)

    override var keyCommands: [UIKeyCommand]? {
        guard captureSystemShortcuts else { return super.keyCommands }
        if let cached = cachedPriorityCommands { return cached }
        let built = Self.buildPriorityCommands(action: #selector(priorityCommandFired(_:)))
        cachedPriorityCommands = built
        return built
    }

    @objc private func priorityCommandFired(_ sender: UIKeyCommand) {
        // Intentionally empty — real down/up arrives via pressesBegan/Ended.
    }

    private static func buildPriorityCommands(action: Selector) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let digits = Array("0123456789")
        var extras = [
            "\t", "\r", UIKeyCommand.inputEscape,
            UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
            " ",
            "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`",
        ]
        if #available(iOS 15.0, *) {
            extras.append(UIKeyCommand.inputDelete)
        } else {
            extras.append("\u{7F}")
        }
        let inputs: [String] = letters.map(String.init) + digits.map(String.init) + extras
        let modifierSets: [UIKeyModifierFlags] = [
            .command,
            [.command, .shift],
            [.command, .alternate],
            [.command, .control],
            [.command, .shift, .alternate],
            .control,
            [.control, .shift],
            [.control, .alternate],
            [.control, .shift, .alternate],
            .alternate,
            [.alternate, .shift],
        ]
        for mods in modifierSets {
            for input in inputs where !input.isEmpty {
                let cmd = UIKeyCommand(input: input, modifierFlags: mods, action: action)
                if #available(iOS 15.0, *) {
                    cmd.wantsPriorityOverSystemBehavior = true
                }
                cmd.discoverabilityTitle = nil
                commands.append(cmd)
            }
        }
        return commands
    }

    // MARK: Viewport geometry

    private var displaySize: (w: CGFloat, h: CGFloat) {
        (
            CGFloat(max(1, session?.displayWidth ?? 1)),
            CGFloat(max(1, session?.displayHeight ?? 1))
        )
    }

    /// Scale that fits the remote display in the view at zoom=1.
    private var fitScale: CGFloat {
        let (dw, dh) = displaySize
        let vw = max(bounds.width, 1)
        let vh = max(bounds.height, 1)
        return min(vw / dw, vh / dh)
    }

    /// Letterboxed remote content rect in view points (includes pan/zoom).
    func contentRect() -> CGRect {
        let (dw, dh) = displaySize
        let vw = bounds.width
        let vh = bounds.height
        guard vw > 1, vh > 1 else { return bounds }
        let scale = fitScale * userZoom
        let cw = dw * scale
        let ch = dh * scale
        let ox = (vw - cw) / 2 + panOffset.x
        let oy = (vh - ch) / 2 + panOffset.y
        return CGRect(x: ox, y: oy, width: cw, height: ch)
    }

    func mapToRemote(_ point: CGPoint) -> (x: Int, y: Int) {
        let r = contentRect()
        let dw = max(1, session?.displayWidth ?? 1)
        let dh = max(1, session?.displayHeight ?? 1)
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let rx = Int(((point.x - r.minX) / r.width) * CGFloat(dw))
        let ry = Int(((point.y - r.minY) / r.height) * CGFloat(dh))
        return (max(0, min(dw - 1, rx)), max(0, min(dh - 1, ry)))
    }

    /// Clamp pan so zoomed content can be scrolled to every edge (no circular math).
    private func clampPan() {
        if userZoom <= 1.001 {
            userZoom = 1
            panOffset = .zero
            return
        }
        let (dw, dh) = displaySize
        let vw = max(bounds.width, 1)
        let vh = max(bounds.height, 1)
        let scale = fitScale * userZoom
        let cw = dw * scale
        let ch = dh * scale
        // How far the content can slide while keeping the view filled when possible.
        let maxX = max(0, (cw - vw) / 2)
        let maxY = max(0, (ch - vh) / 2)
        panOffset.x = min(maxX, max(-maxX, panOffset.x))
        panOffset.y = min(maxY, max(-maxY, panOffset.y))
    }

    /// Zoom keeping `anchor` (view point) fixed on the same remote pixel.
    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        let z = min(maxZoom, max(minZoom, newZoom))
        let old = contentRect()
        guard old.width > 1, old.height > 1 else {
            userZoom = z
            clampPan()
            return
        }
        let fx = (anchor.x - old.minX) / old.width
        let fy = (anchor.y - old.minY) / old.height
        userZoom = z
        let (dw, dh) = displaySize
        let vw = max(bounds.width, 1)
        let vh = max(bounds.height, 1)
        let scale = fitScale * userZoom
        let cw = dw * scale
        let ch = dh * scale
        // anchor = origin + fraction * size  →  origin = anchor - fraction * size
        // origin = (view - size)/2 + pan  →  pan = origin - (view - size)/2
        panOffset.x = anchor.x - fx * cw - (vw - cw) / 2
        panOffset.y = anchor.y - fy * ch - (vh - ch) / 2
        clampPan()
    }

    func resetViewport() {
        userZoom = 1
        panOffset = .zero
    }

    // MARK: Unified gestures (RemoteGestureEngine)
    //
    // All pointer semantics live in RemoteGestureEngine. This view only:
    //   1) feeds touches* into the engine
    //   2) maps actions → mouse JSON / viewport math
    // See RemoteGestureEngine.swift for the mode × gesture matrix.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !softKeyboardOn, !softField.isFirstResponder {
            _ = becomeFirstResponder()
        }
        gestures.preferredMode = isCursorMode ? .cursor : .touch
        gestures.touchesBegan(touches, in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesMoved(touches, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesEnded(touches, in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesCancelled(touches, in: self)
        if touchModeLeftDown {
            emit([
                "x": "\(lastRemoteX)",
                "y": "\(lastRemoteY)",
                "type": "up",
                "buttons": "left",
            ])
            touchModeLeftDown = false
        }
    }

    /// Never let the 1×1 soft-keyboard field steal canvas hits.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === softField { return self }
        return hit
    }

    private func contentToRemoteScale() -> CGFloat {
        let r = contentRect()
        let dw = CGFloat(max(1, session?.displayWidth ?? 1))
        return max(r.width / dw, 0.001)
    }

    // MARK: Mouse JSON

    private func sendMouse(type: String, point: CGPoint, buttons: String) {
        let (x, y) = mapToRemote(point)
        lastRemoteX = x
        lastRemoteY = y
        var map: [String: String] = [
            "x": "\(x)",
            "y": "\(y)",
        ]
        if type != "move" {
            map["type"] = type
            map["buttons"] = buttons
        }
        if type == "down", buttons == "left" {
            touchModeLeftDown = true
        } else if type == "up", buttons == "left" {
            touchModeLeftDown = false
        }
        emit(map)
    }

    private func emit(_ map: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        session?.sendMouseJSON(json)
    }
}

// MARK: - Soft-keyboard text field (child of TouchMetalView)

/// Tiny field that owns system-keyboard FR. Lives as a subview of the metal
/// view so SwiftUI cannot strip it and it never covers the sidebar.
final class SoftKeyboardField: UITextField, UITextFieldDelegate {
    static let sentinel = "\u{200B}"

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?

    override var canBecomeFirstResponder: Bool { isEnabled }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            onDelete?()
        } else if string == "\n" {
            onInsert?("\n")
        } else {
            onInsert?(string)
        }
        textField.text = Self.sentinel
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onInsert?("\n")
        textField.text = Self.sentinel
        return false
    }
}
