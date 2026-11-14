#if os(iOS)
    import SwiftUI
    import UIKit

    @MainActor public struct WindowHost: UIViewRepresentable {
        let state: WindowState
        let items: [WindowPresentation]
        let available: Bool
        let generation: UUID
        let topBoundary: Double?
        let maximizedFrame: WindowGeometry?
        let content: (WindowPresentation) -> AnyView
        public init(state: WindowState, topBoundary: Double? = nil, content: @escaping (WindowPresentation) -> AnyView)
        {
            self.state = state
            self.items = state.windows
            self.available = state.available
            self.generation = state.generation
            self.topBoundary = topBoundary
            self.maximizedFrame = state.maximizedFrame
            self.content = content
        }
        public func makeUIView(context: Context) -> WindowHostView {
            let view = WindowHostView()
            view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
                (view: WindowHostView, _: UITraitCollection) in view.setNeedsLayout()
            }
            return view
        }
        public func updateUIView(_ view: WindowHostView, context: Context) {
            view.update(state: state, items: items, topBoundary: topBoundary, content: content)
        }
        public static func dismantleUIView(_ view: WindowHostView, coordinator: ()) { view.retire() }
    }

    @MainActor public final class WindowHostView: UIView {
        private struct Pane {
            let host: UIHostingController<AnyView>
            let surface: UIView
            var revision: UInt64
            var animator: UIViewPropertyAnimator?
            var animationID = UUID()
            var target = CGRect.zero
            var mode = WindowMode.normal
        }
        private var panes: [UUID: Pane] = [:]
        private weak var state: WindowState?
        private var generation: UUID?
        private var layoutFrame = CGRect.zero
        private var layoutMaximum: WindowGeometry?
        private var topBoundary: Double?
        private var usableFrame: CGRect { bounds.inset(by: safeAreaInsets) }
        public override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }
        public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
                return nil
            }
            for surface in subviews.reversed() {
                guard let entry = panes.first(where: { $0.value.surface === surface }) else { continue }
                let local = surface.convert(point, from: self)
                let corner =
                    entry.value.host.view.layer.presentation()?.cornerRadius ?? entry.value.host.view.layer.cornerRadius
                guard UIBezierPath(roundedRect: surface.bounds, cornerRadius: corner).contains(local),
                    let hit = surface.hitTest(local, with: event)
                else { continue }
                if let state, state.focusedID != entry.key {
                    do {
                        bringSubviewToFront(surface)
                        try state.focus(entry.key)
                    } catch {
                        state.report(entry.key, message: error.localizedDescription)
                    }
                }
                return hit
            }
            return nil
        }
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                retire()
                return
            }
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) { responder = current.next }
            if let parent = responder as? UIViewController {
                for pane in panes.values where pane.host.parent == nil {
                    parent.addChild(pane.host)
                    pane.host.didMove(toParent: parent)
                }
            }
        }
        public override func layoutSubviews() {
            super.layoutSubviews()
            let safe = usableFrame
            guard let state, safe.width > 0, safe.height > 0 else { return }
            let boundary = topBoundary.map { value in
                window.map { convert(CGPoint(x: 0, y: value), from: $0).y } ?? value
            }
            let maximum = WindowGeometry.maximized(viewport: bounds, safe: safe, topBoundary: boundary)
            let titleSize = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection).pointSize
            if layoutFrame != safe || layoutMaximum != maximum || state.cardTitleSize != titleSize {
                layoutFrame = safe
                layoutMaximum = maximum
                state.layout(width: safe.width, height: safe.height, maximized: maximum, titleSize: titleSize)
            }
        }
        public func retire() {
            for pane in panes.values {
                pane.animator?.stopAnimation(true)
                pane.host.willMove(toParent: nil)
                pane.surface.removeFromSuperview()
                pane.host.removeFromParent()
            }
            panes.removeAll()
            if let state, let generation, state.generation == generation {
                for item in state.windows {
                    state.complete(item.id, revision: item.revision, generation: generation, success: false)
                }
            }
        }
        func update(
            state: WindowState, items: [WindowPresentation], topBoundary: Double?,
            content: (WindowPresentation) -> AnyView
        ) {
            self.state = state
            if self.topBoundary != topBoundary {
                self.topBoundary = topBoundary
                setNeedsLayout()
            }
            if generation != state.generation {
                retire()
                generation = state.generation
            }
            guard state.available else { return }
            for id in Array(panes.keys) where !items.contains(where: { $0.id == id }) {
                if let pane = panes.removeValue(forKey: id) {
                    pane.animator?.stopAnimation(true)
                    pane.host.willMove(toParent: nil)
                    pane.surface.removeFromSuperview()
                    pane.host.removeFromParent()
                }
            }
            for item in items {
                let root = AnyView(
                    WindowChrome(
                        item: item, state: state, content: content(item),
                        contentInsets: item.mode == .maximized ? safeAreaInsets : .zero))
                let fresh = panes[item.id] == nil
                var pane =
                    panes[item.id] ?? Pane(host: UIHostingController(rootView: root), surface: UIView(), revision: 0)
                pane.host.rootView = root
                let surface = pane.surface
                if fresh {
                    surface.backgroundColor = .clear
                    pane.host.safeAreaRegions = []
                    let hosted = pane.host.view!
                    hosted.backgroundColor = .clear
                    hosted.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    hosted.layer.cornerRadius = item.mode == .minimized ? 16 : item.mode == .maximized ? 0 : 24
                    hosted.layer.masksToBounds = true
                    hosted.layer.borderWidth = item.mode == .maximized ? 0 : 0.5
                    hosted.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
                    surface.addSubview(hosted)
                    surface.layer.shadowColor = UIColor.black.cgColor
                    surface.layer.shadowOpacity = 0.3
                    surface.layer.shadowRadius = 18
                    var responder: UIResponder? = self
                    while let current = responder, !(current is UIViewController) { responder = current.next }
                    if let parent = responder as? UIViewController { parent.addChild(pane.host) }
                    addSubview(surface)
                    pane.host.didMove(toParent: pane.host.parent)
                }
                bringSubviewToFront(surface)
                let geometry = state.frame(item)
                let target = CGRect(
                    x: usableFrame.minX + geometry.x, y: usableFrame.minY + geometry.y, width: geometry.width,
                    height: geometry.height)
                if pane.revision == item.revision && (pane.animator == nil || pane.target == target)
                    && (item.mode != .maximized || pane.target == target)
                {
                    if pane.animator == nil { surface.frame = target }
                    panes[item.id] = pane
                    continue
                }
                let currentFrame = surface.layer.presentation()?.frame
                let currentOpacity = surface.layer.presentation()?.opacity
                pane.animator?.stopAnimation(true)
                surface.transform = .identity
                if let currentFrame { surface.frame = currentFrame }
                if let currentOpacity { surface.alpha = CGFloat(currentOpacity) }
                pane.revision = item.revision
                pane.target = target
                let animationID = UUID()
                pane.animationID = animationID
                if fresh {
                    surface.frame = target
                    pane.host.view.frame = surface.bounds
                    surface.alpha = 0
                    surface.transform = .init(scaleX: 0.96, y: 0.96)
                }
                let closing = item.phase == .closing
                let minimizedTransition = item.mode == .minimized || pane.mode == .minimized
                pane.mode = item.mode
                let duration =
                    UIAccessibility.isReduceMotionEnabled
                    ? 0.12 : closing ? 0.2 : fresh ? 0.28 : minimizedTransition ? 0.35 : 0.3
                if UIAccessibility.isReduceMotionEnabled {
                    surface.transform = .identity
                    surface.frame = target
                    if !closing { surface.alpha = 0 }
                }
                let hosted = pane.host.view!
                let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.88) {
                    surface.transform = .identity
                    surface.frame = target
                    surface.alpha = closing ? 0 : 1
                    hosted.layer.cornerRadius = item.mode == .minimized ? 16 : item.mode == .maximized ? 0 : 24
                    hosted.layer.borderWidth = item.mode == .maximized ? 0 : 0.5
                }
                let generation = state.generation
                animator.addCompletion { [weak self, weak state] position in
                    guard let self, self.panes[item.id]?.animationID == animationID else { return }
                    self.panes[item.id]?.animator = nil
                    if closing, position == .end {
                        surface.removeFromSuperview()
                    }
                    state?.complete(item.id, revision: item.revision, generation: generation, success: position == .end)
                }
                pane.animator = animator
                panes[item.id] = pane
                // Start after hierarchy mounting; completion is supplied by UIKit, never a timer.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation, self.panes[item.id]?.animationID == animationID
                    else {
                        return
                    }
                    guard self.window != nil else {
                        state.complete(item.id, revision: item.revision, generation: generation, success: false)
                        return
                    }
                    animator.startAnimation()
                }
            }
        }
    }

    @MainActor private struct WindowChrome: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let item: WindowPresentation
        let state: WindowState
        let content: AnyView
        let contentInsets: UIEdgeInsets
        @State private var dragOrigin: WindowGeometry?
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        private let colors: [Color] = [
            Color(red: 0.68, green: 0.79, blue: 0.94), Color(red: 0.80, green: 0.74, blue: 0.91),
            Color(red: 0.66, green: 0.84, blue: 0.80), Color(red: 0.74, green: 0.77, blue: 0.91),
            Color(red: 0.92, green: 0.75, blue: 0.80), Color(red: 0.94, green: 0.82, blue: 0.66),
        ]
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if item.mode != .minimized {
                        control("minus", color: .yellow, command: .minimize, label: appCopy.text("Minimize"))
                        control(
                            item.mode == .maximized ? "arrow.down.right.and.arrow.up.left" : "plus", color: .green,
                            command: item.mode == .maximized ? .restore : .maximize,
                            label: item.mode == .maximized ? appCopy.text("Restore") : appCopy.text("Maximize"))
                    } else {
                        WindowIconView(icon: item.icon).frame(width: 44).allowsHitTesting(false)
                    }
                    VStack(spacing: 0) {
                        Text(
                            item.content == WindowContent.camera.rawValue || item.content == WindowContent.web.rawValue
                                ? appCopy.text(item.title) : item.title
                        )
                        .font(
                            item.mode == .minimized
                                ? .system(size: state.cardTitleSize, weight: .semibold)
                                : .subheadline.weight(.semibold)
                        )
                        .lineLimit(1).truncationMode(.tail)
                        if item.mode == .minimized, let activity = item.activity {
                            Text(activity).font(.caption2).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, item.mode == .minimized ? WindowCardLayout.titlePadding : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .global).onChanged { value in
                            guard item.mode != .maximized else { return }
                            if dragOrigin == nil { dragOrigin = state.frame(item) }
                            if let origin = dragOrigin {
                                do {
                                    try state.drag(
                                        item.id, x: origin.x + value.translation.width,
                                        y: origin.y + value.translation.height)
                                } catch { state.report(item.id, message: error.localizedDescription) }
                            }
                        }.onEnded { _ in
                            dragOrigin = nil
                            state.endDrag(item.id)
                        }
                        .exclusively(
                            before: TapGesture(count: item.mode == .minimized ? 1 : 2).onEnded {
                                state.submit(
                                    item.id,
                                    command: item.mode == .minimized || item.mode == .maximized
                                        ? .restore : .maximize)
                            }))
                    if item.mode != .minimized {
                        ZStack {
                            if item.phase == .opening || item.phase == .changing {
                                ProgressView().controlSize(.mini).tint(.white).accessibilityLabel(
                                    appCopy.text("Opening window"))
                            }
                        }.frame(width: 44).allowsHitTesting(false)
                    }
                    control(
                        "xmark", color: item.mode == .minimized ? .white : .red, command: .close,
                        label: appCopy.text("Close"))
                }
                .frame(height: item.mode == .minimized ? 48 : 52)
                .background(
                    item.mode == .minimized
                        ? colors[item.color].opacity(reduceTransparency || contrast == .increased ? 1 : 0.75)
                        : Color.black.opacity(0.75))
                if let prompt = item.prompt {
                    VStack(spacing: 8) {
                        Text(appCopy.text(prompt.title)).font(.subheadline)
                        HStack {
                            ForEach(prompt.choices) { choice in
                                Button(appCopy.text(choice.title)) {
                                    state.answer(item.id, promptID: prompt.id, choice: choice.id)
                                }
                                .frame(
                                    minWidth: 44, minHeight: 44)
                            }
                        }
                    }.padding(8).background(.black)
                }
                if let failure = item.failure { Text(failure).font(.caption).padding(8) }
                if item.mode != .minimized { content.frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
            }
            .padding(.leading, contentInsets.left)
            .padding(.trailing, contentInsets.right)
            .padding(.bottom, contentInsets.bottom)
            .foregroundStyle(item.mode == .minimized ? Color.black : Color.white)
            .background(item.mode == .minimized ? Color.clear : Color.black)

        }
        private func control(_ icon: String, color: Color, command: WindowCommand, label: String) -> some View {
            Button {
                state.submit(item.id, command: command)
            } label: {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black).frame(width: 20, height: 20).background(color, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(label)
        }
    }

    @MainActor private struct WindowIconView: View {
        let icon: WindowIcon?
        @State private var image: UIImage?
        var body: some View {
            Group {
                switch icon {
                case .system(let name): Image(systemName: name).resizable().scaledToFit()
                case .emoji(let value): Text(value).font(.system(size: 22))
                case .image:
                    if let image { Image(uiImage: image).resizable().scaledToFit() } else { Color.clear }
                case nil: Color.clear
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            .onChange(of: icon, initial: true) { _, value in
                if case .image(let data) = value { image = UIImage(data: data) } else { image = nil }
            }
        }
    }
#endif
