import UIKit

// MARK: - Public model

/// Input semantics for one touch epoch (latched at first finger-down).
enum RemoteInputMode: Equatable {
    /// Absolute tablet / Sidecar: finger position = remote pointer.
    case touch
    /// Trackpad: finger moves the remote cursor; clicks land at the cursor.
    case cursor
}

/// High-level actions the view turns into mouse JSON / viewport math.
enum RemoteGestureAction: Equatable {
    /// Absolute hover (no button). Touch mode only.
    case hover(point: CGPoint)
    /// Absolute left button down / up / click.
    case leftDown(point: CGPoint)
    case leftUp(point: CGPoint)
    case leftClick(point: CGPoint, count: Int)
    case rightClick(point: CGPoint)
    /// Cursor-mode trackpad delta (view points).
    case moveCursor(dx: CGFloat, dy: CGFloat)
    case leftClickAtCursor(count: Int)
    case rightClickAtCursor
    /// Discrete wheel notches (Flutter contract: ±1).
    case wheel(x: Int, y: Int)
    /// Absolute zoom factor with anchor in view points.
    case zoom(to: CGFloat, anchor: CGPoint)
    case panViewport(dx: CGFloat, dy: CGFloat)
    case resetViewport
    case haptic(UIImpactFeedbackGenerator.FeedbackStyle)
}

protocol RemoteGestureEngineDelegate: AnyObject {
    func gestureEngine(_ engine: RemoteGestureEngine, didEmit action: RemoteGestureAction)
    /// Current user zoom (≥1) for pinch re-base.
    var gestureEngineZoom: CGFloat { get }
}

/// Unified remote-desktop gesture state machine.
///
/// **Single owner of pointer semantics** — no competing `UIPan` / `UILongPress` /
/// manual multiPeak detectors. Feed only `touchesBegan/Moved/Ended/Cancelled`.
///
/// | Gesture | Touch mode | Cursor mode |
/// |---|---|---|
/// | 1-finger tap | left at finger | left at cursor |
/// | 1-finger double-tap | double left at finger | double left at cursor |
/// | 1-finger long-press | right at finger | right at cursor |
/// | 1-finger drag | left-drag absolute | move cursor |
/// | 2-finger tap | right at centroid | right at cursor |
/// | 2-finger double-tap | reset zoom | reset zoom |
/// | 2-finger pan @ 1× | scroll wheel | scroll wheel |
/// | 2-finger pan zoomed | pan content | pan content |
/// | 2-finger pinch | zoom | zoom |
final class RemoteGestureEngine {
    weak var delegate: RemoteGestureEngineDelegate?

    /// Live preference; latched into `epochMode` on first finger of a sequence.
    var preferredMode: RemoteInputMode = .touch

    // MARK: Config

    struct Config {
        var dragSlop: CGFloat = 12
        var longPress: CFTimeInterval = 0.45
        var doubleTapInterval: CFTimeInterval = 0.32
        var doubleTapDistance: CGFloat = 36
        var twoFingerTapTravel: CGFloat = 24
        var twoFingerTapDuration: CFTimeInterval = 0.42
        var twoFingerDoubleInterval: CFTimeInterval = 0.32
        var pinchCommitRatio: CGFloat = 0.12
        var multiCommitTravel: CGFloat = 14
        var wheelStepPoints: CGFloat = 14
        var minZoom: CGFloat = 1
        var maxZoom: CGFloat = 6
        var cursorSensitivity: CGFloat = 1.15
    }

    var config = Config()

    // MARK: State

    private enum State: Equatable {
        case idle
        case one(OneFinger)
        case multi(Multi)
        case done // emitted terminal click; wait for all fingers up
    }

    private struct OneFinger: Equatable {
        var id: ObjectIdentifier
        var start: CGPoint
        var last: CGPoint
        var t0: CFTimeInterval
        var maxTravel: CGFloat
        var dragging: Bool
        var longPressFired: Bool
    }

    private struct Multi: Equatable {
        var t0: CFTimeInterval
        var startCentroid: CGPoint
        var startSpan: CGFloat
        var startPoints: [ObjectIdentifier: CGPoint]
        var lastCentroid: CGPoint
        var lastSpan: CGFloat
        var maxTravel: CGFloat
        var baseZoom: CGFloat
        var commit: MultiCommit?
        var wheelAccY: CGFloat
        var wheelAccX: CGFloat
    }

    private enum MultiCommit: Equatable {
        case scroll
        case pan
        case pinch
    }

    private var state: State = .idle
    private var epochMode: RemoteInputMode = .touch
    private var active: [ObjectIdentifier: CGPoint] = [:]
    private var longPressWork: DispatchWorkItem?
    private var twoFingerTapWork: DispatchWorkItem?
    private var oneFingerTapWork: DispatchWorkItem?
    private var lastOneTap: (t: CFTimeInterval, p: CGPoint)?
    private var lastTwoTap: (t: CFTimeInterval, p: CGPoint)?

    // MARK: - Public feed

    func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches {
            active[ObjectIdentifier(t)] = t.location(in: view)
        }
        process()
    }

    func touchesMoved(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches {
            active[ObjectIdentifier(t)] = t.location(in: view)
        }
        process()
    }

    func touchesEnded(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches {
            // Capture last location before removal when possible.
            active[ObjectIdentifier(t)] = t.location(in: view)
        }
        // Remove ended touches after processing current positions once.
        let ended = touches.map { ObjectIdentifier($0) }
        process(ending: Set(ended))
        for id in ended { active.removeValue(forKey: id) }
        if active.isEmpty { finishIdleCleanup() }
    }

    func touchesCancelled(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches {
            active.removeValue(forKey: ObjectIdentifier(t))
        }
        cancelTimers()
        if case .one(let o) = state, o.dragging {
            emit(.leftUp(point: o.last))
        }
        state = .idle
        if active.isEmpty { finishIdleCleanup() }
    }

    func reset() {
        cancelTimers()
        active.removeAll()
        state = .idle
        lastOneTap = nil
        lastTwoTap = nil
    }

    // MARK: - Machine

    private func process(ending: Set<ObjectIdentifier> = []) {
        let n = active.count
        // Remaining after this end event.
        let remaining = active.keys.filter { !ending.contains($0) }.count

        switch state {
        case .idle:
            if n == 1, ending.isEmpty {
                // New one-finger sequence cancels a pending single-click only if
                // it's a potential double-tap (handled in endOneFinger).
                beginOneFinger()
            } else if n >= 2, ending.isEmpty {
                oneFingerTapWork?.cancel()
                oneFingerTapWork = nil
                beginMulti()
            }

        case .one(var o):
            if remaining >= 2 || (n >= 2 && ending.isEmpty) {
                // Second finger: promote to multi, release any drag.
                cancelLongPress()
                if o.dragging {
                    emit(.leftUp(point: o.last))
                    o.dragging = false
                }
                beginMulti()
                return
            }
            if !ending.isEmpty, remaining == 0 {
                endOneFinger(o)
                return
            }
            // Move
            guard let p = active[o.id] ?? active.values.first else { return }
            let travel = hypot(p.x - o.start.x, p.y - o.start.y)
            o.maxTravel = max(o.maxTravel, travel)
            let dx = p.x - o.last.x
            let dy = p.y - o.last.y
            o.last = p

            if o.longPressFired {
                state = .one(o)
                return
            }

            if !o.dragging, o.maxTravel > config.dragSlop {
                cancelLongPress()
                o.dragging = true
                switch epochMode {
                case .touch:
                    emit(.leftDown(point: o.start))
                    emit(.hover(point: p))
                case .cursor:
                    emit(.moveCursor(dx: dx, dy: dy))
                }
            } else if o.dragging {
                switch epochMode {
                case .touch:
                    emit(.hover(point: p))
                case .cursor:
                    emit(.moveCursor(dx: dx, dy: dy))
                }
            } else {
                // Still possible tap / long-press.
                switch epochMode {
                case .touch:
                    emit(.hover(point: p))
                case .cursor:
                    if abs(dx) + abs(dy) > 0.1 {
                        emit(.moveCursor(dx: dx, dy: dy))
                    }
                }
            }
            state = .one(o)

        case .multi(var m):
            if remaining == 0, !ending.isEmpty {
                endMulti(m)
                return
            }
            if n < 2, remaining < 2 {
                // Dropped to one finger mid-multi without clean end — abort multi.
                if remaining == 0 {
                    endMulti(m)
                } else {
                    // Fall back: cancel multi without click if we had committed viewport.
                    if m.commit != nil {
                        state = .done
                    } else {
                        endMulti(m)
                    }
                }
                return
            }
            updateMulti(&m)
            state = .multi(m)

        case .done:
            if remaining == 0 {
                state = .idle
            }
        }
    }

    // MARK: One finger

    private func beginOneFinger() {
        guard let (id, p) = active.first else { return }
        epochMode = preferredMode
        let now = CACurrentMediaTime()
        let o = OneFinger(
            id: id,
            start: p,
            last: p,
            t0: now,
            maxTravel: 0,
            dragging: false,
            longPressFired: false
        )
        state = .one(o)
        if epochMode == .touch {
            emit(.hover(point: p))
        }
        armLongPress()
    }

    private func endOneFinger(_ o: OneFinger) {
        cancelLongPress()
        if o.longPressFired {
            state = .idle
            return
        }
        if o.dragging {
            if epochMode == .touch {
                emit(.leftUp(point: o.last))
            }
            state = .idle
            return
        }
        // Clean tap — delay single click so a second tap can become double-click
        // without emitting an extra single click first.
        let now = CACurrentMediaTime()
        let point = o.start
        let mode = epochMode
        if let last = lastOneTap,
           now - last.t < config.doubleTapInterval,
           hypot(point.x - last.p.x, point.y - last.p.y) < config.doubleTapDistance {
            oneFingerTapWork?.cancel()
            oneFingerTapWork = nil
            lastOneTap = nil
            switch mode {
            case .touch: emit(.leftClick(point: point, count: 2))
            case .cursor: emit(.leftClickAtCursor(count: 2))
            }
            state = .idle
            return
        }
        lastOneTap = (now, point)
        oneFingerTapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.oneFingerTapWork = nil
            switch mode {
            case .touch: self.emit(.leftClick(point: point, count: 1))
            case .cursor: self.emit(.leftClickAtCursor(count: 1))
            }
        }
        oneFingerTapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.doubleTapInterval, execute: work)
        state = .idle
    }

    private func armLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            self?.fireLongPress()
        }
        longPressWork = work
        // `.common` so it fires during tracking (unlike default-mode Timer).
        DispatchQueue.main.asyncAfter(deadline: .now() + config.longPress, execute: work)
    }

    private func fireLongPress() {
        longPressWork = nil
        guard case .one(var o) = state, !o.dragging, !o.longPressFired else { return }
        guard o.maxTravel <= config.dragSlop else { return }
        o.longPressFired = true
        state = .one(o)
        switch epochMode {
        case .touch:
            emit(.rightClick(point: o.start))
        case .cursor:
            emit(.rightClickAtCursor)
        }
        emit(.haptic(.medium))
        state = .done
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    // MARK: Multi finger

    private func beginMulti() {
        cancelLongPress()
        twoFingerTapWork?.cancel()
        twoFingerTapWork = nil
        guard active.count >= 2 else { return }
        let pts = Array(active.values)
        let c = centroid(pts)
        let s = span(pts)
        let now = CACurrentMediaTime()
        var starts: [ObjectIdentifier: CGPoint] = [:]
        for (id, p) in active { starts[id] = p }
        let m = Multi(
            t0: now,
            startCentroid: c,
            startSpan: max(s, 1),
            startPoints: starts,
            lastCentroid: c,
            lastSpan: max(s, 1),
            maxTravel: 0,
            baseZoom: delegate?.gestureEngineZoom ?? 1,
            commit: nil,
            wheelAccY: 0,
            wheelAccX: 0
        )
        state = .multi(m)
    }

    private func updateMulti(_ m: inout Multi) {
        let pts = Array(active.values)
        guard pts.count >= 2 else { return }
        let c = centroid(pts)
        let s = span(pts)
        let travel = hypot(c.x - m.startCentroid.x, c.y - m.startCentroid.y)
        m.maxTravel = max(m.maxTravel, travel)
        // Per-finger travel.
        for (id, p) in active {
            if let sp = m.startPoints[id] {
                m.maxTravel = max(m.maxTravel, hypot(p.x - sp.x, p.y - sp.y))
            }
        }

        let spanRatio = s / max(m.startSpan, 1)
        let dcx = c.x - m.lastCentroid.x
        let dcy = c.y - m.lastCentroid.y

        if m.commit == nil {
            if abs(spanRatio - 1) >= config.pinchCommitRatio {
                m.commit = .pinch
                m.baseZoom = delegate?.gestureEngineZoom ?? m.baseZoom
                twoFingerTapWork?.cancel()
            } else if m.maxTravel >= config.multiCommitTravel {
                let zoom = delegate?.gestureEngineZoom ?? 1
                m.commit = zoom > 1.05 ? .pan : .scroll
                twoFingerTapWork?.cancel()
            }
        }

        switch m.commit {
        case .pinch:
            let z = min(config.maxZoom, max(config.minZoom, m.baseZoom * spanRatio))
            emit(.zoom(to: z, anchor: c))
        case .scroll:
            // Natural iOS: finger up → content up → wheel y positive in our earlier mapping.
            m.wheelAccY += dcy
            m.wheelAccX += dcx
            while abs(m.wheelAccY) >= config.wheelStepPoints {
                let dir = m.wheelAccY > 0 ? 1 : -1
                m.wheelAccY -= CGFloat(dir) * config.wheelStepPoints
                emit(.wheel(x: 0, y: dir))
            }
            while abs(m.wheelAccX) >= config.wheelStepPoints {
                let dir = m.wheelAccX > 0 ? 1 : -1
                m.wheelAccX -= CGFloat(dir) * config.wheelStepPoints
                emit(.wheel(x: dir, y: 0))
            }
        case .pan:
            emit(.panViewport(dx: dcx, dy: dcy))
        case .none:
            break
        }

        m.lastCentroid = c
        m.lastSpan = s
    }

    private func endMulti(_ m: Multi) {
        // Viewport gesture already committed — no click.
        if m.commit != nil {
            let z = delegate?.gestureEngineZoom ?? 1
            if z < 1.05, m.commit == .pinch {
                emit(.resetViewport)
            }
            state = .idle
            return
        }

        let duration = CACurrentMediaTime() - m.t0
        let isTap = m.maxTravel <= config.twoFingerTapTravel
            && duration > 0.03
            && duration <= config.twoFingerTapDuration
            && active.count + 0 <= 2 // peak was 2 conceptually

        guard isTap else {
            state = .idle
            return
        }

        let point = m.startCentroid
        let now = CACurrentMediaTime()
        // Double two-finger tap → reset zoom.
        if let last = lastTwoTap,
           now - last.t < config.twoFingerDoubleInterval,
           hypot(point.x - last.p.x, point.y - last.p.y) < 56 {
            twoFingerTapWork?.cancel()
            twoFingerTapWork = nil
            lastTwoTap = nil
            emit(.resetViewport)
            emit(.haptic(.light))
            state = .idle
            return
        }

        lastTwoTap = (now, point)
        // Delay single 2-finger tap so a second one can become double-tap reset.
        twoFingerTapWork?.cancel()
        let mode = epochMode
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.twoFingerTapWork = nil
            switch mode {
            case .touch:
                self.emit(.rightClick(point: point))
            case .cursor:
                self.emit(.rightClickAtCursor)
            }
            self.emit(.haptic(.medium))
        }
        twoFingerTapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.twoFingerDoubleInterval, execute: work)
        state = .idle
    }

    // MARK: Helpers

    private func finishIdleCleanup() {
        // Keep pending two-finger single-tap work alive after fingers up.
        if case .done = state { state = .idle }
    }

    private func cancelTimers() {
        cancelLongPress()
        twoFingerTapWork?.cancel()
        twoFingerTapWork = nil
        oneFingerTapWork?.cancel()
        oneFingerTapWork = nil
    }

    private func emit(_ action: RemoteGestureAction) {
        delegate?.gestureEngine(self, didEmit: action)
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        var sx: CGFloat = 0, sy: CGFloat = 0
        for p in pts { sx += p.x; sy += p.y }
        let n = CGFloat(pts.count)
        return CGPoint(x: sx / n, y: sy / n)
    }

    private func span(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        // Max pairwise distance (works for 2; for 3+ approximates spread).
        var maxD: CGFloat = 0
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                maxD = max(maxD, hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y))
            }
        }
        return maxD
    }
}
