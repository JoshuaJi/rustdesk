import SwiftUI
import MetalKit
import UIKit

/// MTKView that pulls BGRA frames from Rust soft-render buffer.
struct MetalRemoteView: UIViewRepresentable {
    @ObservedObject var session: SessionController
    var onSize: (CGSize) -> Void
    var onTouch: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onTouch: onTouch)
    }

    func makeUIView(context: Context) -> TouchMetalView {
        let v = TouchMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.coordinator = context.coordinator
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.delegate = context.coordinator
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.preferredFramesPerSecond = 60
        v.isMultipleTouchEnabled = false
        context.coordinator.attach(view: v)
        return v
    }

    func updateUIView(_ uiView: TouchMetalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.onTouch = onTouch
        let size = uiView.bounds.size
        if size.width > 1, size.height > 1 {
            onSize(size)
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var session: SessionController
        var onTouch: (String) -> Void
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var pipeline: MTLRenderPipelineState?
        private var tw = 0
        private var th = 0
        weak var view: TouchMetalView?

        init(session: SessionController, onTouch: @escaping (String) -> Void) {
            self.session = session
            self.onTouch = onTouch
        }

        func attach(view: TouchMetalView) {
            self.view = view
            device = view.device
            commandQueue = device?.makeCommandQueue()
            buildPipeline(view: view)
        }

        private func buildPipeline(view: MTKView) {
            guard let device else { return }
            // Simple shader-less clear + blit path using texture drawn with built-in
            // We use a tiny embedded shader via MTLLibrary default if available.
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            struct VOut { float4 pos [[position]]; float2 uv; };
            vertex VOut v_main(uint vid [[vertex_id]]) {
                float2 positions[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
                float2 uvs[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
                VOut o; o.pos = float4(positions[vid], 0, 1); o.uv = uvs[vid]; return o;
            }
            fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
                constexpr sampler s(address::clamp_to_edge, filter::linear);
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
            // Pull latest frame if any
            if let (data, w, h) = session.pullFrame(), w > 0, h > 0 {
                upload(data: data, width: w, height: h)
            }
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let pipeline,
                  let texture,
                  let cq = commandQueue,
                  let cmd = cq.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
            else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
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

final class TouchMetalView: MTKView {
    weak var coordinator: MetalRemoteView.Coordinator?
    private var lastPoint: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, coordinator != nil else { return }
        let p = t.location(in: self)
        lastPoint = p
        send(type: "down", point: p, buttons: "left")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, coordinator != nil else { return }
        let p = t.location(in: self)
        lastPoint = p
        send(type: "move", point: p, buttons: "")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        send(type: "up", point: p, buttons: "left")
        lastPoint = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func send(type: String, point: CGPoint, buttons: String) {
        guard let c = coordinator else { return }
        let scale = contentScaleFactor
        // Map view coords to remote display using simple fit
        let dw = max(1, c.session.displayWidth)
        let dh = max(1, c.session.displayHeight)
        let vw = bounds.width * scale
        let vh = bounds.height * scale
        let sx = CGFloat(dw) / max(vw, 1)
        let sy = CGFloat(dh) / max(vh, 1)
        let s = max(sx, sy) // cover? use min for fit
        let fit = min(sx, sy)
        let x = Int((point.x * scale) * fit)
        let y = Int((point.y * scale) * fit)
        var map: [String: String] = [
            "x": "\(max(0, min(dw - 1, x)))",
            "y": "\(max(0, min(dh - 1, y)))",
        ]
        if type != "move" {
            map["type"] = type
            map["buttons"] = buttons
        }
        if let data = try? JSONSerialization.data(withJSONObject: map),
           let json = String(data: data, encoding: .utf8) {
            c.onTouch(json)
        }
    }
}
