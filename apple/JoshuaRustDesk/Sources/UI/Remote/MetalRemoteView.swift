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

final class TouchMetalView: MTKView, UITextFieldDelegate, UIGestureRecognizerDelegate {
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

    private var softKeyboardOn = false
    /// Hidden field that actually owns the system soft keyboard (MTKView + UIKeyInput is unreliable).
    private let softField = UITextField(frame: .zero)
    /// Keeps the field non-empty so Backspace always fires `shouldChangeCharactersIn`.
    private let softSentinel = "\u{200B}" // zero-width space
    private var keyboardObservers: [NSObjectProtocol] = []

    /// Remote peer cursor overlay (image from cursor_data / fallback arrow).
    private let cursorView = UIImageView()
    private var defaultCursorImage: UIImage?

    private var cachedPriorityCommands: [UIKeyCommand]?
    private var activeTouches: [UITouch: CGPoint] = [:]

    // Viewport gestures (UIKit — smoother than hand-rolled multi-touch)
    private var pinchBaseZoom: CGFloat = 1
    private var wheelAccumulator: CGFloat = 0
    /// True while a 2-finger viewport gesture is active (suppress mouse).
    private var viewportGestureActive = false
    private var viewportGestureMoved = false

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
    private var touchModeLeftDown = false
    private var touchModeDragging = false
    private var lastRemoteX = 0
    private var lastRemoteY = 0
    private var lastTapTime: CFTimeInterval = 0
    private var lastTapPoint: CGPoint = .zero
    private let doubleTapMaxInterval: CFTimeInterval = 0.32
    private let doubleTapMaxDistance: CGFloat = 36
    private var gestureConsumed = false

    /// Remote-cursor ON → cursor/trackpad mode; OFF → Sidecar touch mode.
    private var isCursorMode: Bool { session?.showRemoteCursor == true }

    // MARK: Setup

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        setupSoftField()
        setupCursorOverlay()
        setupViewportGestures()
        setupKeyboardNotifications()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupSoftField()
        setupCursorOverlay()
        setupViewportGestures()
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

    // MARK: Viewport gestures (pinch + two-finger pan)

    private func setupViewportGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        // Two-finger double-tap → reset zoom (Photos/Maps style).
        let resetTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
        resetTap.numberOfTapsRequired = 2
        resetTap.numberOfTouchesRequired = 2
        resetTap.delegate = self
        addGestureRecognizer(resetTap)

        // Two-finger single tap → right-click (waits for double-tap reset to fail).
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerRightClick(_:)))
        rightTap.numberOfTapsRequired = 1
        rightTap.numberOfTouchesRequired = 2
        rightTap.delegate = self
        rightTap.require(toFail: resetTap)
        addGestureRecognizer(rightTap)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let anchor = g.location(in: self)
        switch g.state {
        case .began:
            viewportGestureActive = true
            viewportGestureMoved = false
            pinchBaseZoom = userZoom
            releaseAllButtons(at: nil)
            cancelLongPress()
            resetFingerState()
        case .changed:
            if abs(g.scale - 1) > 0.02 { viewportGestureMoved = true }
            // g.scale is cumulative from gesture start → base * scale
            setZoom(pinchBaseZoom * g.scale, anchor: anchor)
        case .ended, .cancelled, .failed:
            viewportGestureActive = false
            // Snap almost-fit back to 1×
            if userZoom < 1.05 {
                resetViewport()
            }
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            viewportGestureActive = true
            viewportGestureMoved = false
            wheelAccumulator = 0
            releaseAllButtons(at: nil)
            cancelLongPress()
            resetFingerState()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            if hypot(t.x, t.y) > 0.5 { viewportGestureMoved = true }

            if userZoom > 1.02 {
                // Pan the zoomed viewport (finger follows content).
                panOffset.x += t.x
                panOffset.y += t.y
                clampPan()
            } else {
                // Fit view: two-finger drag = scroll wheel (Sidecar-like).
                wheelAccumulator += t.y
                let step: CGFloat = 16
                while abs(wheelAccumulator) >= step {
                    let dir = wheelAccumulator > 0 ? 1 : -1
                    wheelAccumulator -= CGFloat(dir) * step
                    // Natural: finger up → content moves up → negative wheel on many desktops
                    sendWheel(deltaY: -dir * 100, at: g.location(in: self))
                }
            }
        case .ended, .cancelled, .failed:
            viewportGestureActive = false
            wheelAccumulator = 0
        default:
            break
        }
    }

    @objc private func handleTwoFingerDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        resetViewport()
    }

    @objc private func handleTwoFingerRightClick(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        // Don't right-click if a pinch/pan just moved the viewport.
        guard !viewportGestureMoved else { return }
        let p = g.location(in: self)
        if isCursorMode {
            session?.clickAtCursor(button: "right")
        } else {
            click(at: p, button: "right", count: 1)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch + two-finger pan together (standard map UX).
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Viewport gestures only care about multi-touch; single-finger stays on touches*.
        true
    }

    // MARK: Touches (single-finger mouse only; pan/zoom via gesture recognizers)
    //
    // Sidecar-style touch mode (absolute):
    //   • Finger down  → hover (move only, NO button)
    //   • Small lift   → click (down+up); double-tap → double-click
    //   • Move past threshold → left-down + drag; lift → left-up
    //   • Long-press → right-click
    // Cursor mode (trackpad):
    //   • Drag moves remote cursor; tap clicks; long-press holds left
    // Viewport (both modes):
    //   • Pinch → zoom about fingers
    //   • Two-finger drag @ 1× → scroll wheel; when zoomed → pan view
    //   • Two-finger double-tap → reset zoom

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !softKeyboardOn {
            _ = becomeFirstResponder()
        }
        for t in touches {
            activeTouches[t] = t.location(in: self)
        }

        // Multi-touch: viewport gestures own it — cancel single-finger mouse work.
        if activeTouches.count >= 2 || viewportGestureActive {
            cancelLongPress()
            releaseAllButtons(at: touches.first.map { $0.location(in: self) })
            resetFingerState()
            return
        }

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
            scheduleTouchModeLongPress(at: p)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            activeTouches[t] = t.location(in: self)
        }
        // Never drive mouse with multi-finger or during viewport gestures.
        if activeTouches.count >= 2 || viewportGestureActive {
            cancelLongPress()
            releaseAllButtons(at: nil)
            resetFingerState()
            return
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
                cancelLongPress()
                touchModeDragging = true
                fingerMoved = true
                sendMouse(type: "down", point: start, buttons: "left")
                sendMouse(type: "move", point: p, buttons: "")
            } else {
                sendMouse(type: "move", point: p, buttons: "")
            }
        } else {
            sendMouse(type: "move", point: p, buttons: "")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let endPoint = touches.first.map { $0.location(in: self) } ?? lastFinger
        for t in touches { activeTouches.removeValue(forKey: t) }
        cancelLongPress()

        // Still multi or viewport gesture — mouse end handled elsewhere.
        if activeTouches.count >= 1 || viewportGestureActive {
            if activeTouches.isEmpty {
                releaseAllButtons(at: endPoint)
                resetFingerState()
            }
            return
        }

        if isCursorMode {
            if leftHeldInCursorMode {
                session?.mouseButtonAtCursor(type: "up", button: "left")
                leftHeldInCursorMode = false
            } else if !fingerMoved {
                session?.clickAtCursor(button: "left")
            }
            resetFingerState()
            return
        }

        // —— Touch mode end ——
        if gestureConsumed {
            releaseAllButtons(at: endPoint)
        } else if touchModeDragging || touchModeLeftDown {
            if let endPoint {
                sendMouse(type: "up", point: endPoint, buttons: "left")
            } else {
                releaseAllButtons(at: nil)
            }
        } else if let endPoint {
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
