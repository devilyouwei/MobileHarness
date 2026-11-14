import Foundation

/// All placement stays in UI. A single rounded rectangle grows; no custom neck or hardware mask artwork.
struct IslandPlacement: Equatable, Sendable {
    let compact: CGRect
    let frame: CGRect
    let header: CGRect
    /// Black artwork is independent of the full-width status/content container.
    var background: CGRect { frame.height > compact.height ? frame : compact }
    static let detailBottom: CGFloat = 18
    let protected: CGRect?
    let leadingSlot: CGRect
    let trailingSlot: CGRect?
    let contentTop: Double
    let corner: Double
    /// Keep the SwiftUI header's canvas stable as indicators change width. UIKit moves
    /// its origin opposite to the animated shell, preserving scene-space alignment.
    func headerCanvas(viewport: CGSize, shell: CGRect) -> CGRect {
        CGRect(
            x: -shell.minX, y: -shell.minY + header.minY - compact.minY,
            width: viewport.width, height: viewport.height)
    }
    static func resolve(
        viewport: CGSize, safeTop: Double, safeBottom: Double, expanded: Bool, detailHeight: Double,
        hasSecondary: Bool = true, primaryWidth: CGFloat = IslandCompactMetrics.slotWidth,
        secondaryWidth: CGFloat = IslandCompactMetrics.slotWidth
    ) -> Self {
        let attached =
            safeTop >= 51 && viewport.height > viewport.width && viewport.width >= 390 && viewport.width < 600
        let metricsHeight = IslandCompactMetrics.height
        let slot = primaryWidth
        let padding = IslandCompactMetrics.outerPadding
        let top = attached ? max(8, safeTop - metricsHeight - IslandCompactMetrics.safeAreaBottomGap) : safeTop + 8
        let shield =
            attached
            ? CGRect(
                x: (viewport.width - IslandCompactMetrics.housingWidth) / 2,
                y: top, width: IslandCompactMetrics.housingWidth, height: metricsHeight) : nil
        let compact: CGRect
        if let shield {
            compact = CGRect(
                x: shield.minX - padding - slot, y: top,
                width: shield.width + padding + slot + (hasSecondary ? padding + secondaryWidth : 0),
                height: metricsHeight)
        } else {
            let businessWidth = hasSecondary ? padding * 2 + slot + secondaryWidth + 12 : 44
            compact = CGRect(
                x: (viewport.width - businessWidth) / 2, y: top, width: businessWidth, height: metricsHeight)
        }
        let header = compact.offsetBy(dx: 0, dy: expanded ? 6 : 0)
        let leading = CGRect(
            x: shield.map { $0.minX - slot } ?? (compact.minX + (hasSecondary ? padding : (compact.width - slot) / 2)),
            y: header.minY, width: slot, height: metricsHeight)
        let trailing =
            hasSecondary
            ? CGRect(
                x: shield?.maxX ?? (compact.maxX - padding - secondaryWidth),
                y: header.minY, width: secondaryWidth, height: metricsHeight) : nil
        let contentTop = metricsHeight + 10
        let width = min(420, max(1, viewport.width - 32))
        let height = min(
            max(metricsHeight, viewport.height - top - safeBottom - 8),
            contentTop + min(180, max(44, detailHeight)) + Self.detailBottom)
        let frame = CGRect(
            x: (viewport.width - width) / 2, y: top, width: width,
            height: expanded ? height : metricsHeight)
        return .init(
            compact: compact, frame: frame, header: header, protected: shield, leadingSlot: leading,
            trailingSlot: trailing,
            contentTop: contentTop, corner: expanded ? 36 : metricsHeight / 2)
    }
}

/// Deliberate upward swipe only; shared by the entire expanded surface, independent of its content.
enum IslandInteraction {
    /// The central black housing is part of the interactive pill, not a touch exclusion.
    static func contains(_ point: CGPoint, frame: CGRect, corner: CGFloat) -> Bool {
        guard frame.contains(point) else { return false }
        let radius = max(0, min(corner, min(frame.width, frame.height) / 2))
        let x = min(max(point.x, frame.minX + radius), frame.maxX - radius)
        let y = min(max(point.y, frame.minY + radius), frame.maxY - radius)
        return hypot(point.x - x, point.y - y) <= radius
    }

    static func shouldCollapse(translation: CGSize) -> Bool {
        translation.height <= -36 && -translation.height > abs(translation.width) * 1.5
    }
}

#if os(iOS)
    import SwiftUI
    import UIKit

    /// Scene-local renderer. Business callers use IslandState/IslandContent, never placement or animation knobs.
    struct IslandHost: UIViewRepresentable {
        let state: IslandState
        let revision: UInt64
        let available: Bool
        let status: IslandDeviceStatus
        let statusDate: Date
        init(state: IslandState) {
            self.state = state
            revision = state.localRevision
            available = state.available && state.sceneActive
            status = state.statusBar.value
            statusDate = state.statusBar.date
        }
        func makeUIView(context: Context) -> IslandAnchor { IslandAnchor() }
        func updateUIView(_ view: IslandAnchor, context: Context) { view.update(state) }
        static func dismantleUIView(_ view: IslandAnchor, coordinator: ()) { view.detach() }
    }

    @MainActor final class IslandOverlayWindow: UIWindow {
        weak var renderer: IslandAnchor?
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard renderer?.accepts(point) == true else { return nil }
            return super.hitTest(point, with: event)
        }
    }
    @MainActor final class IslandOverlayController: UIViewController {
        weak var renderer: IslandAnchor?
        override var prefersStatusBarHidden: Bool { true }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            renderer?.render()
        }
    }
    @MainActor final class IslandAnchor: UIView {
        private weak var state: IslandState?
        private var overlay: IslandOverlayWindow?
        private var controller: IslandOverlayController?
        private var hosting: UIHostingController<IslandLocalBody>?
        private var headerHosting: UIHostingController<IslandLocalHeader>?
        private let surface = UIView()
        private let backdrop = UIView()
        private let statusBar = IslandStatusBarView()
        private var viewport = CGSize.zero
        private var animator: UIViewPropertyAnimator?
        private var animationID = UUID()
        private var lastRevision: UInt64?
        private var lastGeneration: UUID?
        private var placement: IslandPlacement?
        private var safeTop = 0.0
        private var closing = false
        private var isRendering = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { render() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            render()
        }
        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            render()
        }
        func update(_ state: IslandState) {
            self.state = state
            render()
        }
        func detach() {
            animationID = UUID()
            animator?.stopAnimation(true)
            animator = nil
            overlay?.isHidden = true
            hosting?.willMove(toParent: nil)
            hosting?.view.removeFromSuperview()
            hosting?.removeFromParent()
            headerHosting?.willMove(toParent: nil)
            headerHosting?.view.removeFromSuperview()
            headerHosting?.removeFromParent()
            headerHosting = nil
            surface.removeFromSuperview()
            statusBar.removeFromSuperview()
            overlay?.rootViewController = nil
            overlay = nil
            controller = nil
            hosting = nil
            placement = nil
            closing = false
            lastRevision = nil
            lastGeneration = nil
            state?.localDetached()
        }
        func accepts(_ point: CGPoint) -> Bool {
            guard let state, state.available, state.sceneActive,
                state.compact != nil, placement != nil
            else {
                return false
            }
            let container = surface.layer.presentation()?.frame ?? surface.frame
            let background = backdrop.layer.presentation()?.frame ?? backdrop.frame
            let frame = background.offsetBy(dx: container.minX, dy: container.minY)
            let corner = backdrop.layer.presentation()?.cornerRadius ?? backdrop.layer.cornerRadius
            return IslandInteraction.contains(point, frame: frame, corner: corner)
        }
        private func close(_ state: IslandState) {
            guard !closing else { return }
            guard overlay != nil, let placement else {
                state.localCompleted(generation: state.generation, revision: state.localRevision)
                return
            }
            closing = true
            let current = surface.layer.presentation()?.frame ?? surface.frame
            let currentHeader = headerHosting?.view.layer.presentation()?.frame ?? headerHosting?.view.frame
            let statusVisual = statusBar.visualState
            let currentBackground = backdrop.layer.presentation()?.frame ?? backdrop.frame
            let currentBackgroundCorner = backdrop.layer.presentation()?.cornerRadius ?? backdrop.layer.cornerRadius
            animator?.stopAnimation(true)
            surface.frame = current
            backdrop.frame = currentBackground
            backdrop.layer.cornerRadius = currentBackgroundCorner
            if let currentHeader { headerHosting?.view.frame = currentHeader }
            statusBar.frame = IslandStatusBarLayout.contentFrame(viewport: viewport, shell: current)
            statusBar.restore(statusVisual)
            let generation = state.generation
            let revision = state.localRevision
            let token = UUID()
            animationID = token
            let animator = UIViewPropertyAnimator(
                duration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.22, curve: .easeInOut
            ) {
                self.surface.frame =
                    placement.protected ?? placement.compact.insetBy(dx: min(12, placement.compact.width / 4), dy: 0)
                self.surface.layer.cornerRadius = IslandCompactMetrics.height / 2
                self.backdrop.frame = self.surface.bounds
                self.backdrop.layer.cornerRadius = IslandCompactMetrics.height / 2
                self.headerHosting?.view.frame = IslandStatusBarLayout.contentFrame(
                    viewport: self.viewport, shell: self.surface.frame)
                self.statusBar.frame = IslandStatusBarLayout.contentFrame(
                    viewport: self.viewport, shell: self.surface.frame)
                if UIAccessibility.isReduceMotionEnabled { self.surface.alpha = 0 }
            }
            animator.addCompletion { [weak self, weak state] position in
                guard let self, self.animationID == token, position == .end else { return }
                self.detach()
                self.surface.alpha = 1
                state?.localCompleted(generation: generation, revision: revision)
            }
            self.animator = animator
            animator.startAnimation()
        }
        func render() {
            guard !isRendering else {
                setNeedsLayout()
                return
            }
            isRendering = true
            defer { isRendering = false }
            guard let state, let source = window, let scene = source.windowScene, state.available, state.sceneActive
            else {
                if overlay != nil { detach() }
                return
            }
            guard let content = state.compact?.content else {
                close(state)
                return
            }
            closing = false
            let detail = state.detail
            let header = state.headerActivity?.content
            if source.safeAreaInsets.top > 0 || viewport != source.bounds.size {
                safeTop = Double(source.safeAreaInsets.top)
            }
            viewport = source.bounds.size
            let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(ofSize: 15, weight: .medium), compatibleWith: source.traitCollection)
            let textWidth = max(
                40, min(420, source.bounds.width - 32) - 48 - 24 - 44 - 20 - (detail?.thumbnail == nil ? 0 : 66))
            let textHeight =
                detail.map {
                    (($0.text ?? "") as NSString).boundingRect(
                        with: CGSize(width: textWidth, height: 1000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
                    ).height
                } ?? 0
            let next = IslandPlacement.resolve(
                viewport: source.bounds.size, safeTop: safeTop,
                safeBottom: Double(source.safeAreaInsets.bottom), expanded: detail != nil,
                detailHeight: max(ceil(textHeight), detail?.thumbnail == nil ? 44 : 56),
                hasSecondary: header?.secondary != nil, primaryWidth: header?.primary.compactWidth ?? 0,
                secondaryWidth: header?.secondary?.compactWidth ?? IslandCompactMetrics.slotWidth)
            state.reserveLocalFrame(next.frame)
            let fresh = overlay == nil
            let changed =
                fresh || placement != next || lastRevision != state.localRevision || lastGeneration != state.generation
            statusBar.update(state: state.statusBar, language: state.language)
            guard changed else {
                state.localMounted()
                return
            }
            let body = IslandLocalBody(
                state: state, content: state.detailActivity?.content ?? content, detail: detail, placement: next)
            let headerBody = IslandLocalHeader(
                state: state, content: header, placement: next)
            let headerFrame = next.headerCanvas(viewport: viewport, shell: next.frame)
            if fresh {
                let overlay = IslandOverlayWindow(windowScene: scene)
                overlay.renderer = self
                overlay.frame = source.bounds
                // Keep compact indicators above the status bar for the entire mounted lifetime.
                overlay.windowLevel = .alert
                overlay.backgroundColor = .clear
                let controller = IslandOverlayController()
                controller.overrideUserInterfaceStyle = .dark
                controller.renderer = self
                controller.view.backgroundColor = .clear
                overlay.rootViewController = controller
                let hosting = UIHostingController(rootView: body)
                hosting.safeAreaRegions = []
                hosting.view.backgroundColor = .clear
                hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                controller.addChild(hosting)
                surface.backgroundColor = .clear
                surface.clipsToBounds = true
                surface.layer.cornerCurve = .continuous
                backdrop.backgroundColor = .black
                backdrop.isUserInteractionEnabled = false
                backdrop.layer.cornerCurve = .continuous
                backdrop.layer.borderWidth = 0.5
                backdrop.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
                controller.view.addSubview(surface)
                surface.addSubview(backdrop)
                surface.addSubview(hosting.view)
                let headerHosting = UIHostingController(rootView: headerBody)
                headerHosting.safeAreaRegions = []
                headerHosting.view.backgroundColor = .clear
                headerHosting.view.isUserInteractionEnabled = false
                controller.addChild(headerHosting)
                surface.addSubview(headerHosting.view)
                headerHosting.didMove(toParent: controller)
                self.headerHosting = headerHosting
                surface.addSubview(statusBar)
                hosting.didMove(toParent: controller)
                self.overlay = overlay
                self.controller = controller
                self.hosting = hosting
                surface.frame = next.protected ?? next.compact.insetBy(dx: 12, dy: 0)
                surface.layer.cornerRadius = IslandCompactMetrics.height / 2
                backdrop.frame = surface.bounds
                backdrop.layer.cornerRadius = IslandCompactMetrics.height / 2
                hosting.view.frame = surface.bounds
                headerHosting.view.frame = next.headerCanvas(viewport: viewport, shell: surface.frame)
                statusBar.frame = IslandStatusBarLayout.contentFrame(viewport: source.bounds.size, shell: surface.frame)
                statusBar.arrange(placement: next)
                overlay.isHidden = false
            }
            state.localMounted()
            overlay?.frame = source.bounds
            let currentFrame = surface.layer.presentation()?.frame ?? surface.frame
            let currentCorner = surface.layer.presentation()?.cornerRadius ?? surface.layer.cornerRadius
            let currentHeader = headerHosting?.view.layer.presentation()?.frame ?? headerHosting?.view.frame
            let statusVisual = statusBar.visualState
            let currentBackground = backdrop.layer.presentation()?.frame ?? backdrop.frame
            let currentBackgroundCorner = backdrop.layer.presentation()?.cornerRadius ?? backdrop.layer.cornerRadius
            animator?.stopAnimation(true)
            UIView.performWithoutAnimation {
                surface.frame = currentFrame
                surface.layer.cornerRadius = currentCorner
                backdrop.frame = currentBackground
                backdrop.layer.cornerRadius = currentBackgroundCorner
                statusBar.frame = IslandStatusBarLayout.contentFrame(viewport: source.bounds.size, shell: currentFrame)
                statusBar.restore(statusVisual)
                hosting?.rootView = body
                headerHosting?.rootView = headerBody
                if let currentHeader { headerHosting?.view.frame = currentHeader }
                hosting?.view.frame = surface.bounds
            }
            placement = next
            lastRevision = state.localRevision
            lastGeneration = state.generation
            let generation = state.generation
            let revision = state.localRevision
            let token = UUID()
            animationID = token
            let reduced = UIAccessibility.isReduceMotionEnabled
            if reduced {
                surface.frame = next.frame
                surface.layer.cornerRadius = next.corner
                surface.alpha = 0.7
            }
            let openingCompact = fresh && detail == nil && !reduced
            let background = next.background.offsetBy(dx: -next.frame.minX, dy: -next.frame.minY)
            if reduced {
                backdrop.frame = background
                backdrop.layer.cornerRadius = next.corner
            }
            let animator = UIViewPropertyAnimator(
                duration: reduced ? 0.12 : openingCompact ? 0.30 : 0.62,
                dampingRatio: reduced ? 1 : 0.76
            ) {
                self.surface.alpha = 1
                self.surface.frame = next.frame
                self.surface.layer.cornerRadius = next.corner
                self.backdrop.frame = openingCompact ? self.surface.bounds : background
                self.backdrop.layer.cornerRadius = next.corner
                self.hosting?.view.frame = self.surface.bounds
                self.headerHosting?.view.frame = headerFrame
                self.statusBar.frame = IslandStatusBarLayout.contentFrame(
                    viewport: source.bounds.size, shell: next.frame)
                self.statusBar.arrange(placement: next)
                self.surface.layoutIfNeeded()
            }
            animator.addCompletion { [weak self, weak state] position in
                guard let self, self.animationID == token, position == .end else { return }
                if openingCompact {
                    // The opening first reveals every status item, then only the artwork contracts.
                    // A replacement/close captures this second animator just like the first one.
                    let settle = UIViewPropertyAnimator(duration: 0.52, dampingRatio: 0.72) {
                        self.backdrop.frame = background
                    }
                    settle.addCompletion { [weak self, weak state] end in
                        guard let self, self.animationID == token, end == .end else { return }
                        self.animator = nil
                        self.settleLayout(next)
                        state?.localCompleted(generation: generation, revision: revision)
                    }
                    self.animator = settle
                    settle.startAnimation()
                } else {
                    self.animator = nil
                    self.settleLayout(next)
                    state?.localCompleted(generation: generation, revision: revision)
                }
            }
            self.animator = animator
            animator.startAnimation()
        }
        private func settleLayout(_ target: IslandPlacement) {
            let wasRendering = isRendering
            isRendering = true
            defer { isRendering = wasRendering }
            UIView.performWithoutAnimation {
                surface.frame = target.frame
                surface.alpha = 1
                surface.layer.cornerRadius = target.corner
                backdrop.frame = target.background.offsetBy(dx: -target.frame.minX, dy: -target.frame.minY)
                backdrop.layer.cornerRadius = target.corner
                hosting?.view.frame = surface.bounds
                headerHosting?.view.frame = target.headerCanvas(viewport: viewport, shell: target.frame)
                statusBar.frame = IslandStatusBarLayout.contentFrame(viewport: viewport, shell: target.frame)
                statusBar.arrange(placement: target)
                surface.layoutIfNeeded()
            }
        }
    }

    private struct IslandLocalHeader: View {
        let state: IslandState
        let content: IslandContent?
        let placement: IslandPlacement
        var body: some View {
            ZStack(alignment: .topLeading) {
                if let content {
                    IslandCompactView(
                        content: content, bands: state.bands, spectrumActive: state.spectrumActive,
                        housingWidth: placement.protected?.width ?? 0
                    )
                    .frame(width: placement.compact.width, height: placement.compact.height)
                    .position(x: placement.compact.midX, y: placement.compact.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.locale, state.language.locale)
        }
    }

    private struct IslandLocalBody: View {
        let state: IslandState
        let content: IslandContent
        let detail: IslandDetail?
        let placement: IslandPlacement
        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Color.clear
                    if let detail {
                        IslandExpandedView(
                            primary: content.primary, detail: detail, tone: content.tone,
                            thumbnailData: state.thumbnailData(detail.thumbnail),
                            bands: state.bands, spectrumActive: state.spectrumActive, onCollapse: collapse
                        )
                        .frame(
                            height: max(44, geometry.size.height - placement.contentTop - IslandPlacement.detailBottom)
                        )
                        .padding(.horizontal, 24)
                        .offset(y: placement.contentTop)
                    }
                }.frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                TapGesture().onEnded {
                    do { try state.setExpanded(detail == nil) } catch { state.report(error) }
                }, including: state.detailActivity == nil ? .subviews : .all
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onEnded { value in
                    if detail != nil, IslandInteraction.shouldCollapse(translation: value.translation) { collapse() }
                }
            )
            .preferredColorScheme(.dark)
            .environment(\.locale, state.language.locale)
        }
        private func collapse() {
            do { try state.setExpanded(false) } catch { state.report(error) }
        }
    }

    public struct IslandCompactView: View {
        public let content: IslandContent
        public let bands: [Float]
        public let spectrumActive: Bool
        public let housingWidth: CGFloat
        public init(
            content: IslandContent, bands: [Float] = [], spectrumActive: Bool = false,
            housingWidth: CGFloat = IslandCompactMetrics.housingWidth
        ) {
            self.content = content
            self.bands = bands
            self.spectrumActive = spectrumActive
            self.housingWidth = housingWidth
        }
        public var body: some View {
            HStack(spacing: 0) {
                IslandIndicatorView(
                    value: content.primary, size: IslandCompactMetrics.symbolSize, bands: bands,
                    spectrumActive: spectrumActive
                )
                .frame(width: content.primary.compactWidth, height: IslandCompactMetrics.height)
                if housingWidth > 0 {
                    Color.clear.frame(width: housingWidth)
                } else if content.secondary != nil {
                    Color.clear.frame(width: 12)
                }
                if let secondary = content.secondary {
                    IslandIndicatorView(
                        value: secondary, size: IslandCompactMetrics.symbolSize, bands: bands,
                        spectrumActive: spectrumActive
                    )
                    .frame(width: secondary.compactWidth, height: IslandCompactMetrics.height)
                }
            }
            .padding(.leading, IslandCompactMetrics.outerPadding)
            .padding(.trailing, housingWidth > 0 && content.secondary == nil ? 0 : IslandCompactMetrics.outerPadding)
            .frame(height: IslandCompactMetrics.height)
            .foregroundStyle(content.tone == .recording ? Color.red : content.tone == .purple ? .purple : .cyan)
            .accessibilityElement(children: .ignore).accessibilityLabel(content.title)
        }
    }

    public struct IslandExpandedView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        public let primary: IslandIndicator
        public let detail: IslandDetail
        public let tone: IslandTone
        public let thumbnailData: Data?
        public let bands: [Float]
        public let spectrumActive: Bool
        public let onCollapse: (() -> Void)?
        @ScaledMetric(relativeTo: .subheadline) private var textSize = 15.0
        public init(
            primary: IslandIndicator, detail: IslandDetail, tone: IslandTone = .neutral, thumbnailData: Data? = nil,
            bands: [Float] = [], spectrumActive: Bool = false, onCollapse: (() -> Void)? = nil
        ) {
            self.primary = primary
            self.tone = tone
            self.detail = detail
            self.thumbnailData = thumbnailData
            self.bands = bands
            self.spectrumActive = spectrumActive
            self.onCollapse = onCollapse
        }
        public var body: some View {
            HStack(alignment: .center, spacing: 10) {
                IslandIndicatorView(value: primary, size: 24, bands: bands, spectrumActive: spectrumActive)
                    .foregroundStyle(tone == .recording ? Color.red : tone == .purple ? .purple : .cyan).frame(
                        width: 24, height: 32)
                if let text = detail.normalized?.text {
                    ViewThatFits(in: .vertical) {
                        description(text)
                        ScrollView { description(text) }.scrollIndicators(.hidden)
                    }
                }
                if let thumbnailData {
                    IslandThumbnailView(data: thumbnailData).frame(width: 56, height: 56)
                }
                if detail.normalized?.text == nil { Spacer(minLength: 0) }
                if let onCollapse {
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(appCopy.text("Hide details"))
                }
            }.accessibilityElement(children: .contain)
        }
        private func description(_ text: String) -> some View {
            Text(text).font(.system(size: textSize, weight: .medium)).foregroundStyle(.white)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private struct IslandThumbnailView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let data: Data
        @State private var image: UIImage?
        var body: some View {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { Color.clear }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(appCopy.text("Thumbnail"))
            .task(id: data) { image = UIImage(data: data) }
        }
    }
#endif
