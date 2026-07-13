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
            // Vertex positions + UVs driven by viewport transform (pan/zoom).
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            struct VOut { float4 pos [[position]]; float2 uv; };
            struct Uniforms {
                float2 origin;   // content rect origin in NDC-ish space handled below
                float2 size;     // content rect size in clip space units (-1..1 full)
            };
            vertex VOut v_main(uint vid [[vertex_id]], constant float4 &vp [[buffer(0)]]) {
                // vp = (x, y, w, h) in NDC where full view is (-1,-1)-(1,1)
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
                // Outside UV still samples edge; we clear to black first.
                if (in.uv.x < 0 || in.uv.x > 1 || in.uv.y < 0 || in.uv.y > 1)
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
            if let (data, w, h) = session.pullFrame(), w > 0, h > 0 {
                upload(data: data, width: w, height: h)
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

        private func upload(data: Data, width: Int, height: Int) {
            guard let device else { return }
            if texture == nil || tw != width || th != height {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                desc.usage = [.shaderRead]
                texture = device.makeTexture(descriptor: desc)
                tw = width
                th = height
            }
            guard let texture else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: width * 4
                )
            }
        }
    }
}

// MARK: - Touch + keyboard first-responder view

final class TouchMetalView: MTKView, UITextFieldDelegate {
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

    /// User zoom (1 = fit).
    private(set) var userZoom: CGFloat = 1
    /// Pan offset in view points (applied after fit centering).
    private var panOffset: CGPoint = .zero

    private var softKeyboardOn = false
    /// Hidden field that actually owns the system soft keyboard (MTKView + UIKeyInput is unreliable).
    private let softField = UITextField(frame: .zero)
    /// Keeps the field non-empty so Backspace always fires `shouldChangeCharactersIn`.
    private let softSentinel = "\u{200B}" // zero-width space
    private var keyboardObservers: [NSObjectProtocol] = []

    /// Remote peer cursor overlay (image from cursor_data / fallback arrow).
    private let cursorView = UIImageView()
    private var defaultCursorImage: UIImage?

    /// Suppresses HW presses path while soft field is editing (text field handles it).
    private var softKeyboardOnPublic: Bool { softKeyboardOn }

    private var cachedPriorityCommands: [UIKeyCommand]?
    private var activeTouches: [UITouch: CGPoint] = [:]
    private var pinchStartZoom: CGFloat = 1
    private var panStartOffset: CGPoint = .zero
    private var isPinching = false
    private var isTwoFingerPanning = false
    private var lastTwoFingerMid: CGPoint?
    private var pinchStartDistance: CGFloat = 0
    private var wheelAccumulator: CGFloat = 0

    // Shared single-finger tracking
    private var fingerStart: CGPoint?
    private var lastFinger: CGPoint?
    private var fingerMoved = false
    private var longPressTimer: Timer?
    /// Movement past this (view points) promotes a touch into a drag.
    private let dragThreshold: CGFloat = 12

    // Cursor mode (trackpad)
    private var leftHeldInCursorMode = false
    private let cursorSensitivity: CGFloat = 1.15

    // Touch mode (Sidecar-style absolute tablet)
    /// Left button currently held on the peer (only after drag starts or explicit hold).
    private var touchModeLeftDown = false
    /// True once movement crossed dragThreshold — subsequent moves are drag, not hover.
    private var touchModeDragging = false
    private var lastRemoteX = 0
    private var lastRemoteY = 0
    /// Double-tap → double-click
    private var lastTapTime: CFTimeInterval = 0
    private var lastTapPoint: CGPoint = .zero
    private let doubleTapMaxInterval: CFTimeInterval = 0.32
    private let doubleTapMaxDistance: CGFloat = 36
    /// Two-finger quick tap → right-click (if little movement)
    private var multiFingerMoved = false
    private var multiStartMid: CGPoint?
    /// Long-press already fired (e.g. right-click) — ignore lift click.
    private var gestureConsumed = false

    /// Remote-cursor ON → cursor/trackpad mode; OFF → Sidecar touch mode.
    private var isCursorMode: Bool { session?.showRemoteCursor == true }

    // MARK: Setup

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        setupSoftField()
        setupCursorOverlay()
        setupKeyboardNotifications()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupSoftField()
        setupCursorOverlay()
        setupKeyboardNotifications()
    }

    deinit {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupSoftField() {
        softField.delegate = self
        softField.autocorrectionType = .no
        softField.autocapitalizationType = .none
        softField.spellCheckingType = .no
        softField.smartDashesType = .no
        softField.smartQuotesType = .no
        softField.smartInsertDeleteType = .no
        softField.keyboardType = .default
        softField.returnKeyType = .default
        softField.textContentType = nil
        softField.isSecureTextEntry = false
        // Nearly invisible but still part of the hierarchy (zero-size can block keyboard).
        softField.alpha = 0.01
        softField.tintColor = .clear
        softField.textColor = .clear
        softField.backgroundColor = .clear
        softField.isHidden = false
        // Do not steal canvas taps; still works as first-responder for soft keyboard.
        softField.isUserInteractionEnabled = false
        softField.text = softSentinel
        softField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(softField)
        NSLayoutConstraint.activate([
            softField.widthAnchor.constraint(equalToConstant: 1),
            softField.heightAnchor.constraint(equalToConstant: 1),
            softField.leadingAnchor.constraint(equalTo: leadingAnchor),
            softField.topAnchor.constraint(equalTo: topAnchor),
        ])
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
        let nc = NotificationCenter.default
        keyboardObservers.append(nc.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.softKeyboardOn else { return }
            // User dismissed keyboard (or HW keyboard took over) — sync toolbar state.
            // Delay slightly so our own hide path can set softKeyboardOn first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.softKeyboardOn, !self.softField.isFirstResponder else { return }
                self.softKeyboardOn = false
                self.session?.softKeyboardVisible = false
                self.claimHardwareFocus()
            }
        })
    }

    // MARK: First responder / soft keyboard

    /// Hardware keys (BT / Magic Keyboard) when soft keyboard is hidden.
    override var canBecomeFirstResponder: Bool { !softKeyboardOn }

    /// Empty input view so claiming first responder does not pop the soft keyboard.
    override var inputView: UIView? {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        return v
    }

    func setSoftKeyboard(_ on: Bool) {
        if on == softKeyboardOn {
            if on, !softField.isFirstResponder {
                presentSoftKeyboard()
            }
            return
        }
        softKeyboardOn = on
        if on {
            // Soft keyboard needs normal text input — pause shortcut stealing.
            if session?.captureSystemShortcuts == true {
                // Keep published flag; just avoid fighting while typing.
            }
            presentSoftKeyboard()
        } else {
            dismissSoftKeyboard()
        }
    }

    private func presentSoftKeyboard() {
        // Drop metal first-responder so the text field can take keyboard focus.
        if isFirstResponder {
            resignFirstResponder()
        }
        softField.text = softSentinel
        softField.isUserInteractionEnabled = true
        // Delay past the toolbar button's touch sequence (it steals first responder).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.softKeyboardOn else { return }
            let ok = self.softField.becomeFirstResponder()
            if !ok {
                // Retry once after layout / presentation settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.softKeyboardOn else { return }
                    _ = self.softField.becomeFirstResponder()
                }
            }
        }
    }

    private func dismissSoftKeyboard() {
        softField.resignFirstResponder()
        claimHardwareFocus()
    }

    private func claimHardwareFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.softKeyboardOn else { return }
            _ = self.becomeFirstResponder()
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
        if window != nil, !softKeyboardOn {
            claimHardwareFocus()
        }
    }

    // MARK: UITextFieldDelegate (soft keyboard text path)

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            // Backspace / delete
            session?.handleKey(character: "", usbHid: 0x2A, down: true)
            session?.handleKey(character: "", usbHid: 0x2A, down: false)
        } else if string == "\n" {
            // Return key (some layouts deliver via shouldChange)
            session?.handleKey(character: "\n", usbHid: 0x28, down: true)
            session?.handleKey(character: "\n", usbHid: 0x28, down: false)
        } else {
            session?.inputString(string)
        }
        // Keep sentinel so the field never goes empty.
        textField.text = softSentinel
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        session?.handleKey(character: "\n", usbHid: 0x28, down: true)
        session?.handleKey(character: "\n", usbHid: 0x28, down: false)
        textField.text = softSentinel
        return false
    }

    // MARK: Hardware key presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Soft field is editing: let the text system handle (IME, etc.).
        if softKeyboardOn, softField.isFirstResponder {
            super.pressesBegan(presses, with: event)
            return
        }
        if captureSystemShortcuts || !softKeyboardOn {
            handlePresses(presses, down: true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if softKeyboardOn, softField.isFirstResponder {
            super.pressesEnded(presses, with: event)
            return
        }
        if captureSystemShortcuts || !softKeyboardOn {
            handlePresses(presses, down: false)
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if softKeyboardOn, softField.isFirstResponder {
            super.pressesCancelled(presses, with: event)
            return
        }
        if captureSystemShortcuts || !softKeyboardOn {
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

    /// Letterboxed remote content rect in view points (includes pan/zoom).
    func contentRect() -> CGRect {
        let dw = CGFloat(max(1, session?.displayWidth ?? 1))
        let dh = CGFloat(max(1, session?.displayHeight ?? 1))
        let vw = bounds.width
        let vh = bounds.height
        guard vw > 1, vh > 1 else { return bounds }
        let fit = min(vw / dw, vh / dh)
        let scale = fit * userZoom
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

    private func clampPan() {
        let r = contentRect()
        // Allow panning so content stays partially visible.
        let vw = bounds.width
        let vh = bounds.height
        let maxX = max(0, (r.width - vw) / 2 + vw * 0.25)
        let maxY = max(0, (r.height - vh) / 2 + vh * 0.25)
        panOffset.x = min(maxX, max(-maxX, panOffset.x))
        panOffset.y = min(maxY, max(-maxY, panOffset.y))
    }

    func resetViewport() {
        userZoom = 1
        panOffset = .zero
    }

    // MARK: Touches
    //
    // Sidecar-style touch mode (absolute):
    //   • Finger down  → hover (move only, NO button)
    //   • Small lift   → click (down+up) at that point; double-tap → double-click
    //   • Move past threshold → left-down + drag; lift → left-up
    //   • Two-finger drag → scroll wheel
    //   • Two-finger quick tap → right-click
    //   • Pinch → local viewport zoom
    //
    // Cursor mode (trackpad):
    //   • Drag moves remote cursor; tap clicks at cursor; long-press holds left

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !softKeyboardOn {
            _ = becomeFirstResponder()
        }
        for t in touches {
            activeTouches[t] = t.location(in: self)
        }
        let fingerCount = activeTouches.count

        if fingerCount >= 2 {
            cancelLongPress()
            // Abort any in-progress single-finger drag/click.
            releaseAllButtons(at: touches.first.map { $0.location(in: self) })
            fingerStart = nil
            lastFinger = nil
            fingerMoved = false
            touchModeDragging = false

            isPinching = false
            isTwoFingerPanning = true
            multiFingerMoved = false
            let mid = midpoint(of: Set(activeTouches.keys))
            multiStartMid = mid
            lastTwoFingerMid = mid
            pinchStartZoom = userZoom
            panStartOffset = panOffset
            pinchStartDistance = 0
            return
        }

        isPinching = false
        isTwoFingerPanning = false
        guard let t = touches.first else { return }
        let p = t.location(in: self)

        fingerStart = p
        lastFinger = p
        fingerMoved = false
        touchModeDragging = false
        leftHeldInCursorMode = false
        gestureConsumed = false

        if isCursorMode {
            scheduleCursorModeLongPress()
        } else {
            // Sidecar: hover to touch point — do NOT press the button yet.
            releaseAllButtons(at: p)
            sendMouse(type: "move", point: p, buttons: "")
            // Long-press in touch mode → right-click (context menu).
            scheduleTouchModeLongPress(at: p)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            activeTouches[t] = t.location(in: self)
        }
        if activeTouches.count >= 2 {
            isTwoFingerPanning = true
            handleMultiTouch(Set(activeTouches.keys))
            return
        }
        // Drop stale multi flags if only one finger remains.
        if isPinching || isTwoFingerPanning {
            isPinching = false
            isTwoFingerPanning = false
            lastTwoFingerMid = nil
            pinchStartDistance = 0
            multiStartMid = nil
        }

        guard let t = touches.first, let start = fingerStart, let last = lastFinger else { return }
        let p = t.location(in: self)
        let travel = hypot(p.x - start.x, p.y - start.y)
        let dx = p.x - last.x
        let dy = p.y - last.y
        lastFinger = p

        if isCursorMode {
            if travel > dragThreshold {
                fingerMoved = true
                cancelLongPress()
            }
            applyCursorModeDelta(dx: dx, dy: dy)
            return
        }

        // —— Touch mode (Sidecar absolute) ——
        if !touchModeDragging {
            if travel > dragThreshold {
                // Promote to drag: press at the *start* point (where the user planted),
                // then move to current — avoids “clicking” random mid-slide positions.
                cancelLongPress()
                touchModeDragging = true
                fingerMoved = true
                sendMouse(type: "down", point: start, buttons: "left")
                sendMouse(type: "move", point: p, buttons: "")
            } else {
                // Still a potential tap — just hover/follow under the finger.
                sendMouse(type: "move", point: p, buttons: "")
            }
        } else {
            sendMouse(type: "move", point: p, buttons: "")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let endPoint = touches.first.map { $0.location(in: self) } ?? lastFinger
        let endingMulti = isTwoFingerPanning || isPinching || activeTouches.count > 1
        for t in touches { activeTouches.removeValue(forKey: t) }
        cancelLongPress()

        if activeTouches.count >= 2 {
            return
        }

        // Finishing a multi-touch gesture.
        if endingMulti || (multiStartMid != nil && activeTouches.isEmpty) {
            let wasScrollOrPinch = multiFingerMoved || isPinching
            let mid = multiStartMid
            clearMultiState()
            // Two-finger quick tap (little movement) → right-click.
            if !wasScrollOrPinch, activeTouches.isEmpty {
                if isCursorMode {
                    session?.clickAtCursor(button: "right")
                } else if let mid {
                    click(at: mid, button: "right", count: 1)
                }
            }
            // Ensure no stuck left button after multi interrupted a drag.
            releaseAllButtons(at: endPoint)
            resetFingerState()
            return
        }

        if isCursorMode {
            if leftHeldInCursorMode {
                session?.mouseButtonAtCursor(type: "up", button: "left")
                leftHeldInCursorMode = false
            } else if !fingerMoved, activeTouches.isEmpty {
                session?.clickAtCursor(button: "left")
            }
            resetFingerState()
            return
        }

        // —— Touch mode end ——
        if gestureConsumed {
            releaseAllButtons(at: endPoint)
        } else if touchModeDragging || touchModeLeftDown {
            // Finish drag: release at lift point.
            if let endPoint {
                sendMouse(type: "up", point: endPoint, buttons: "left")
            } else {
                releaseAllButtons(at: nil)
            }
        } else if let endPoint, activeTouches.isEmpty {
            // Tap (no significant movement) → clean click(s) at finger position.
            let now = CACurrentMediaTime()
            let dist = hypot(endPoint.x - lastTapPoint.x, endPoint.y - lastTapPoint.y)
            let isDouble = (now - lastTapTime) < doubleTapMaxInterval && dist < doubleTapMaxDistance
            click(at: endPoint, button: "left", count: isDouble ? 2 : 1)
            lastTapTime = now
            lastTapPoint = endPoint
        }
        touchModeDragging = false
        resetFingerState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let endPoint = touches.first.map { $0.location(in: self) }
        for t in touches { activeTouches.removeValue(forKey: t) }
        cancelLongPress()
        clearMultiState()
        releaseAllButtons(at: endPoint)
        resetFingerState()
    }

    private func resetFingerState() {
        fingerStart = nil
        lastFinger = nil
        fingerMoved = false
        touchModeDragging = false
        leftHeldInCursorMode = false
        gestureConsumed = false
    }

    private func clearMultiState() {
        isPinching = false
        isTwoFingerPanning = false
        lastTwoFingerMid = nil
        pinchStartDistance = 0
        wheelAccumulator = 0
        multiFingerMoved = false
        multiStartMid = nil
    }

    private func releaseAllButtons(at point: CGPoint?) {
        if leftHeldInCursorMode {
            session?.mouseButtonAtCursor(type: "up", button: "left")
            leftHeldInCursorMode = false
        }
        guard touchModeLeftDown else { return }
        if let point {
            sendMouse(type: "up", point: point, buttons: "left")
        } else {
            emit([
                "x": "\(lastRemoteX)",
                "y": "\(lastRemoteY)",
                "type": "up",
                "buttons": "left",
            ])
            touchModeLeftDown = false
        }
    }

    /// Absolute click(s) at a view point (touch mode).
    private func click(at point: CGPoint, button: String, count: Int) {
        for _ in 0..<max(1, count) {
            sendMouse(type: "down", point: point, buttons: button)
            sendMouse(type: "up", point: point, buttons: button)
        }
    }

    private func scheduleCursorModeLongPress() {
        cancelLongPress()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self, self.isCursorMode, !self.fingerMoved else { return }
            self.leftHeldInCursorMode = true
            self.session?.mouseButtonAtCursor(type: "down", button: "left")
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func scheduleTouchModeLongPress(at point: CGPoint) {
        cancelLongPress()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, !self.isCursorMode, !self.touchModeDragging, !self.gestureConsumed else { return }
            guard !self.fingerMoved else { return }
            // Context menu (right-click) under finger.
            self.click(at: point, button: "right", count: 1)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.gestureConsumed = true
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func applyCursorModeDelta(dx: CGFloat, dy: CGFloat) {
        guard let session else { return }
        let scale = max(0.001, contentToRemoteScale())
        let rdx = (dx / scale) * cursorSensitivity
        let rdy = (dy / scale) * cursorSensitivity
        session.moveCursorRemote(toX: session.cursorX + rdx, y: session.cursorY + rdy)
    }

    private func contentToRemoteScale() -> CGFloat {
        let r = contentRect()
        let dw = CGFloat(max(1, session?.displayWidth ?? 1))
        return r.width / dw
    }

    private func handleMultiTouch(_ touches: Set<UITouch>) {
        let pts = touches.map { $0.location(in: self) }
        guard pts.count >= 2 else { return }
        let mid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        let dist = hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)

        if pinchStartDistance <= 0 {
            pinchStartDistance = dist
            pinchStartZoom = userZoom
            lastTwoFingerMid = mid
            return
        }

        // Pinch vs scroll: large span change → zoom viewport; else two-finger scroll.
        let spanDelta = abs(dist - pinchStartDistance)
        if spanDelta > 24 {
            isPinching = true
            multiFingerMoved = true
            let factor = dist / max(pinchStartDistance, 1)
            userZoom = min(5, max(1, pinchStartZoom * factor))
        }

        if let last = lastTwoFingerMid {
            let dx = mid.x - last.x
            let dy = mid.y - last.y
            if hypot(dx, dy) > 4 { multiFingerMoved = true }

            if userZoom > 1.01, isPinching || spanDelta > 24 {
                panOffset.x += dx
                panOffset.y += dy
                clampPan()
            } else {
                // Sidecar-style two-finger scroll → mouse wheel
                wheelAccumulator += dy
                let step: CGFloat = 18
                while abs(wheelAccumulator) >= step {
                    let dir = wheelAccumulator > 0 ? 1 : -1
                    wheelAccumulator -= CGFloat(dir) * step
                    // Invert so finger-up scrolls content up (natural).
                    sendWheel(deltaY: -dir * 120, at: mid)
                }
            }
        }
        lastTwoFingerMid = mid
    }

    private func midpoint(of touches: Set<UITouch>) -> CGPoint {
        let pts = touches.map { $0.location(in: self) }
        guard !pts.isEmpty else { return .zero }
        let sx = pts.reduce(0) { $0 + $1.x }
        let sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
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

    private func sendWheel(deltaY: Int, at point: CGPoint) {
        emit([
            "type": "wheel",
            "x": "0",
            "y": "\(deltaY)",
        ])
    }

    private func emit(_ map: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        session?.sendMouseJSON(json)
    }
}
