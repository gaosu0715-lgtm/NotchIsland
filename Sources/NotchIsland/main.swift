import AppKit
import Combine
import MediaPlayer
import SwiftUI

private enum IslandLayout {
    static let baselineScreen = CGSize(width: 1710, height: 1112)
    static let idleCompact = CGSize(width: 242, height: 44)
    static let playingCompact = CGSize(width: 304, height: 44)
    static let expanded = CGSize(width: 570, height: 226)
    static let expandedTopClearance: CGFloat = 30

    static func scale(for screen: NSScreen) -> CGFloat {
        let frame = screen.frame
        let rawScale = min(frame.width / baselineScreen.width, frame.height / baselineScreen.height)
        return min(1.08, max(0.68, rawScale))
    }

    static func widthScale(for screen: NSScreen, isExpanded: Bool) -> CGFloat {
        let rawScale = scale(for: screen)
        // 1280x832 needs the vertical scale, but the notch width does not shrink
        // visually as much as the UI. Keep horizontal length generous so the
        // album art and waveform stay outside the camera housing.
        let floor: CGFloat = isExpanded ? 0.86 : 0.90
        return min(1.08, max(floor, rawScale))
    }

    static func baseSize(isExpanded: Bool, isPlaying: Bool) -> CGSize {
        if isExpanded {
            return expanded
        }
        return isPlaying ? playingCompact : idleCompact
    }

    static func renderSize(isExpanded: Bool, isPlaying: Bool, scale: CGFloat, widthScale: CGFloat) -> CGSize {
        let base = baseSize(isExpanded: isExpanded, isPlaying: isPlaying)
        return CGSize(width: base.width * widthScale, height: base.height * scale)
    }

    static func layoutSize(isExpanded: Bool, isPlaying: Bool, scale: CGFloat, widthScale: CGFloat) -> CGSize {
        let rendered = renderSize(isExpanded: isExpanded, isPlaying: isPlaying, scale: scale, widthScale: widthScale)
        return CGSize(width: rendered.width / scale, height: rendered.height / scale)
    }
}

private enum IslandMotion {
    static let spring = Animation.spring(
        response: 0.52,
        dampingFraction: 0.88,
        blendDuration: 0.06
    )

    static let fade = Animation.easeInOut(duration: 0.18)
    static let contentFade = Animation.easeInOut(duration: 0.16)
    static let contentCollapse = Animation.easeIn(duration: 0.09)
    static let contentExpandDelay: TimeInterval = 0.06
    static let frameRetractionDelay: TimeInterval = 0.56
}

private struct MusicSnapshot {
    var title: String
    var artist: String
    var album: String?
    var isPlaying: Bool
    var elapsed: TimeInterval?
    var duration: TimeInterval?
    var artwork: NSImage?
    var updatedAt: Date
    var hasTrack: Bool
    var accentColor: NSColor = .notchIslandFallbackAccent

    static let placeholder = MusicSnapshot(
        title: "Apple Music",
        artist: "Open Music to play",
        album: nil,
        isPlaying: false,
        elapsed: nil,
        duration: nil,
        artwork: nil,
        updatedAt: Date(),
        hasTrack: false
    )

    func liveElapsed(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard isPlaying else { return elapsed }

        let next = elapsed + date.timeIntervalSince(updatedAt)
        if let duration {
            return min(max(0, next), duration)
        }
        return max(0, next)
    }

    func isSameTrack(as other: MusicSnapshot) -> Bool {
        title == other.title && artist == other.artist && album == other.album
    }

}

private final class MusicIslandModel: ObservableObject {
    @Published var isExpanded = false
    @Published var music = MusicSnapshot.placeholder
    @Published var appleScriptStatus: String?
    @Published var layoutScale: CGFloat = 1
    @Published var layoutWidthScale: CGFloat = 1
    @Published var notchClearance: CGFloat = IslandLayout.expandedTopClearance
    @Published var panelUsesExpandedFrame = false

    var openMusic: (() -> Void)?
    var togglePlayPause: (() -> Void)?
    var previousTrack: (() -> Void)?
    var nextTrack: (() -> Void)?
    var refreshNowPlaying: (() -> Void)?

    func updateMusic(_ snapshot: MusicSnapshot) {
        var next = snapshot
        let sameTrack = next.isSameTrack(as: music)
        let shouldAnimate = !sameTrack ||
            next.isPlaying != music.isPlaying ||
            next.hasTrack != music.hasTrack

        if sameTrack {
            // Apple Music metadata is refreshed every few seconds. Reusing the
            // existing NSImage for the same track avoids a visible compact-state
            // artwork flash when SwiftUI rebuilds the image layer.
            if let currentArtwork = music.artwork {
                next.artwork = currentArtwork
                next.accentColor = music.accentColor
            } else if let artwork = next.artwork {
                next.accentColor = artwork.dominantAccentColor() ?? .notchIslandFallbackAccent
            } else {
                next.accentColor = music.accentColor
            }
        } else if let artwork = next.artwork {
            next.accentColor = artwork.dominantAccentColor() ?? .notchIslandFallbackAccent
        }

        if shouldAnimate {
            withAnimation(IslandMotion.spring) {
                music = next
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                music = next
            }
        }
    }

    func toggleExpanded() {
        withAnimation(IslandMotion.spring) {
            isExpanded.toggle()
        }
    }

    func updateLayout(scale: CGFloat, widthScale: CGFloat, notchClearance: CGFloat) {
        guard abs(layoutScale - scale) > 0.001 ||
                abs(layoutWidthScale - widthScale) > 0.001 ||
                abs(self.notchClearance - notchClearance) > 0.001 else {
            return
        }
        layoutScale = scale
        layoutWidthScale = widthScale
        self.notchClearance = notchClearance
    }

    func setPanelUsesExpandedFrame(_ value: Bool) {
        guard panelUsesExpandedFrame != value else { return }
        panelUsesExpandedFrame = value
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MusicIslandModel()
    private var panelController: IslandPanelController?
    private var musicProvider: AppleMusicNowPlayingProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        model.openMusic = {
            AppleMusicController.openMusic()
        }
        model.togglePlayPause = { [weak self] in
            AppleMusicController.playPause()
            self?.musicProvider?.refreshSoon()
        }
        model.previousTrack = { [weak self] in
            AppleMusicController.previousTrack()
            self?.musicProvider?.refreshSoon()
        }
        model.nextTrack = { [weak self] in
            AppleMusicController.nextTrack()
            self?.musicProvider?.refreshSoon()
        }
        model.refreshNowPlaying = { [weak self] in
            self?.musicProvider?.refresh()
        }

        panelController = IslandPanelController(model: model)
        musicProvider = AppleMusicNowPlayingProvider(model: model)
        musicProvider?.start()
    }
}

private final class IslandPanelController {
    private let panel: NotchPanel
    private weak var model: MusicIslandModel?
    private var screen: NSScreen
    private var cancellables = Set<AnyCancellable>()
    private var frameRetractionWorkItem: DispatchWorkItem?

    init(model: MusicIslandModel) {
        self.model = model
        self.screen = Self.selectTargetScreen()
        let scale = IslandLayout.scale(for: screen)
        let widthScale = IslandLayout.widthScale(for: screen, isExpanded: true)
        let geometry = NotchGeometry(screen: screen)
        model.updateLayout(scale: scale, widthScale: widthScale, notchClearance: geometry.contentClearance(for: scale))
        let size = Self.currentPanelSize(
            usesExpandedFrame: model.isExpanded,
            isPlaying: model.music.isPlaying,
            scale: scale,
            widthScale: widthScale
        )

        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        panel.contentView = ClearHostingView(rootView: IslandRootView(model: model))
        updateFrame(isExpanded: model.isExpanded, isPlaying: model.music.isPlaying)
        panel.orderFrontRegardless()

        model.$isExpanded
            .combineLatest(model.$music.map(\.isPlaying).removeDuplicates())
            .sink { [weak self] isExpanded, isPlaying in
                self?.updateFrame(isExpanded: isExpanded, isPlaying: isPlaying)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.invalidateShadow()
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
    }

    @objc private func screenParametersChanged() {
        screen = Self.selectTargetScreen(preferredScreenID: screen.screenID)
        guard let model else { return }
        updateFrame(isExpanded: model.isExpanded, isPlaying: model.music.isPlaying)
    }

    private func updateFrame(isExpanded: Bool, isPlaying: Bool) {
        guard let model else { return }

        frameRetractionWorkItem?.cancel()
        frameRetractionWorkItem = nil

        if isExpanded {
            model.setPanelUsesExpandedFrame(true)
            applyPanelFrame(usesExpandedFrame: true, isPlaying: isPlaying)
            return
        }

        if model.panelUsesExpandedFrame {
            // During collapse, keep the real NSPanel large until SwiftUI's
            // spring has settled. If the window shrinks first, the compact view
            // is laid out in a changing coordinate space and appears to skew
            // before it snaps back to the notch center.
            applyPanelFrame(usesExpandedFrame: true, isPlaying: isPlaying)

            let workItem = DispatchWorkItem { [weak self, weak model] in
                guard let self, let model, !model.isExpanded else { return }
                model.setPanelUsesExpandedFrame(false)
                self.applyPanelFrame(usesExpandedFrame: false, isPlaying: model.music.isPlaying)
            }
            frameRetractionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.frameRetractionDelay, execute: workItem)
            return
        }

        model.setPanelUsesExpandedFrame(false)
        applyPanelFrame(usesExpandedFrame: false, isPlaying: isPlaying)
    }

    private func applyPanelFrame(usesExpandedFrame: Bool, isPlaying: Bool) {
        guard let model else { return }

        let geometry = NotchGeometry(screen: screen)
        let screenFrame = geometry.screenFrame
        let scale = IslandLayout.scale(for: screen)
        let widthScale = IslandLayout.widthScale(for: screen, isExpanded: true)
        model.updateLayout(scale: scale, widthScale: widthScale, notchClearance: geometry.contentClearance(for: scale))
        let size = Self.currentPanelSize(
            usesExpandedFrame: usesExpandedFrame,
            isPlaying: isPlaying,
            scale: scale,
            widthScale: widthScale
        )

        // Apple does not publish one fixed notch size for every display mode.
        // auxiliaryTopLeftArea / auxiliaryTopRightArea reveal the menu-bar areas
        // on each side of the camera housing, so the panel is centered on the
        // actual notch gap instead of the full screen bounds.
        let frame = NSRect(
            x: geometry.centerX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        // Keep the notch center as a hard anchor. NSWindow frame animation can
        // briefly use intermediate origins, which made repeated expand/collapse
        // clicks look like the island was drifting away from the notch.
        panel.setFrame(frame.integral, display: true, animate: false)
        panel.orderFrontRegardless()
    }

    private static func currentPanelSize(
        usesExpandedFrame: Bool,
        isPlaying: Bool,
        scale: CGFloat,
        widthScale: CGFloat
    ) -> CGSize {
        let currentWidthScale = usesExpandedFrame ? widthScale : max(widthScale, 0.90)
        return IslandLayout.renderSize(
            isExpanded: usesExpandedFrame,
            isPlaying: isPlaying,
            scale: scale,
            widthScale: currentWidthScale
        )
    }

    private static func selectTargetScreen(preferredScreenID: NSNumber? = nil) -> NSScreen {
        let screens = NSScreen.screens

        if let preferredScreenID,
           let preferredScreen = screens.first(where: { $0.screenID == preferredScreenID }) {
            return preferredScreen
        }

        if let builtInScreen = screens.first(where: { screen in
            let name = screen.localizedName.lowercased()
            return name.contains("built-in") || name.contains("liquid retina") || name.contains("color lcd")
        }) {
            return builtInScreen
        }

        if let notchedScreen = screens.max(by: { $0.safeAreaInsets.top < $1.safeAreaInsets.top }),
           notchedScreen.safeAreaInsets.top > 0 {
            return notchedScreen
        }

        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen
        }

        return NSScreen.main ?? screens.first!
    }
}

private struct NotchGeometry {
    let screenFrame: NSRect
    let centerX: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(screen: NSScreen) {
        let frame = screen.frame
        let safeTop = screen.safeAreaInsets.top
        let fallbackHeight = max(34, min(48, safeTop))
        let fallbackWidth = min(max(188, frame.width * 0.15), 236)

        if let left = screen.auxiliaryTopLeftArea.map({ Self.normalizedArea($0, in: frame) }),
           let right = screen.auxiliaryTopRightArea.map({ Self.normalizedArea($0, in: frame) }) {
            let gapMinX = left.maxX
            let gapMaxX = right.minX
            let gapWidth = gapMaxX - gapMinX

            if gapWidth > 80, gapWidth < frame.width * 0.34 {
                screenFrame = frame
                // On 13-inch MacBook Air M4/M5 panels the camera housing is
                // physically centered. Some macOS display modes report
                // auxiliary menu-bar areas with a slight horizontal bias, so
                // use the display midpoint as the hard visual anchor and keep
                // auxiliary areas only for estimating notch size.
                centerX = frame.midX
                width = gapWidth
                height = max(fallbackHeight, min(left.height, right.height))
                return
            }
        }

        screenFrame = frame
        centerX = frame.midX
        width = fallbackWidth
        height = fallbackHeight
    }

    private static func normalizedArea(_ area: NSRect, in screenFrame: NSRect) -> NSRect {
        guard !screenFrame.intersects(area),
              area.minX >= 0,
              area.minY >= 0,
              area.maxX <= screenFrame.width + 1,
              area.maxY <= screenFrame.height + 1 else {
            return area
        }

        return area.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    }

    func contentClearance(for scale: CGFloat) -> CGFloat {
        let renderedClearance = height + 8
        return min(58, max(IslandLayout.expandedTopClearance, renderedClearance / max(scale, 0.001)))
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    var screenID: NSNumber? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    typealias HitTestPredicate = (_ point: NSPoint, _ bounds: NSRect, _ isFlipped: Bool) -> Bool

    private var hitTestPredicate: HitTestPredicate?

    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    init(rootView: Content, hitTestPredicate: HitTestPredicate?) {
        self.hitTestPredicate = hitTestPredicate
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.hasShadow = false
        window?.invalidateShadow()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestPredicate?(point, bounds, isFlipped) ?? true else {
            return nil
        }

        return super.hitTest(point)
    }
}

private struct IslandRootView: View {
    @ObservedObject var model: MusicIslandModel
    @State private var isHovering = false

    private var compactLayoutSize: CGSize {
        IslandLayout.layoutSize(
            isExpanded: false,
            isPlaying: model.music.isPlaying,
            scale: model.layoutScale,
            widthScale: compactWidthScale
        )
    }

    private var expandedLayoutSize: CGSize {
        IslandLayout.layoutSize(
            isExpanded: true,
            isPlaying: model.music.isPlaying,
            scale: model.layoutScale,
            widthScale: model.layoutWidthScale
        )
    }

    private var panelRenderSize: CGSize {
        IslandLayout.renderSize(
            isExpanded: model.panelUsesExpandedFrame,
            isPlaying: model.music.isPlaying,
            scale: model.layoutScale,
            widthScale: panelWidthScale
        )
    }

    private var panelWidthScale: CGFloat {
        model.panelUsesExpandedFrame ? model.layoutWidthScale : max(model.layoutWidthScale, 0.90)
    }

    private var compactWidthScale: CGFloat {
        max(model.layoutWidthScale, 0.90)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MorphingIslandShell(
                model: model,
                compactSize: compactLayoutSize,
                expandedSize: expandedLayoutSize,
                progress: model.isExpanded ? 1 : 0,
                isHovering: isHovering
            )
                .scaleEffect(model.layoutScale, anchor: .top)
                .animation(IslandMotion.spring, value: model.isExpanded)
                .animation(IslandMotion.spring, value: model.music.isPlaying)
                .animation(.easeOut(duration: 0.18), value: model.layoutScale)
                .animation(.easeOut(duration: 0.18), value: model.layoutWidthScale)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.14)) {
                        isHovering = hovering
                    }
                }
                .contextMenu {
                    Button(model.isExpanded ? "Collapse" : "Expand") {
                        model.toggleExpanded()
                    }
                    Button("Open Apple Music") {
                        model.openMusic?()
                    }
                    Button(model.music.isPlaying ? "Pause" : "Play") {
                        model.togglePlayPause?()
                    }
                    Button("Refresh Now Playing") {
                        model.refreshNowPlaying?()
                    }
                    Divider()
                    Button("Quit NotchIsland") {
                        NSApp.terminate(nil)
                    }
                }
        }
        .frame(width: panelRenderSize.width, height: panelRenderSize.height, alignment: .top)
    }
}

private struct MorphingIslandShell: View, Animatable {
    @ObservedObject var model: MusicIslandModel
    let compactSize: CGSize
    let expandedSize: CGSize
    var progress: CGFloat
    let isHovering: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var currentSize: CGSize {
        CGSize(
            width: blend(compactSize.width, expandedSize.width),
            height: blend(compactSize.height, expandedSize.height)
        )
    }

    private var cornerRadius: CGFloat {
        blend(compactSize.height / 2, 44)
    }

    private var tapLayerHeight: CGFloat {
        progress > 0.5 ? max(64, currentSize.height - 78) : currentSize.height
    }

    private func blend(_ compact: CGFloat, _ expanded: CGFloat) -> CGFloat {
        compact + (expanded - compact) * progress
    }

    var body: some View {
        MusicIslandContentView(model: model, layoutSize: currentSize, expansion: progress)
            .frame(width: currentSize.width, height: currentSize.height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.98))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovering ? 0.11 : 0.055), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                InstantClickView {
                    model.toggleExpanded()
                }
                .frame(width: currentSize.width, height: tapLayerHeight)
                .contentShape(Rectangle())
                .accessibilityLabel(model.isExpanded ? "Collapse Now Playing" : "Expand Now Playing")
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct InstantClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MouseDownView {
        let view = MouseDownView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MouseDownView, context: Context) {
        nsView.action = action
    }

    final class MouseDownView: NSView {
        var action: (() -> Void)?

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            action?()
        }
    }
}

private struct MusicIslandContentView: View {
    @ObservedObject var model: MusicIslandModel
    let layoutSize: CGSize
    let expansion: CGFloat
    @State private var detailsVisible = false

    private var expandedOpacity: Double {
        detailsVisible ? 1 : 0
    }

    private func blend(_ compact: CGFloat, _ expanded: CGFloat) -> CGFloat {
        compact + (expanded - compact) * expansion
    }

    private var artworkSize: CGFloat {
        blend(34, 78)
    }

    private var artworkX: CGFloat {
        blend(27, 65)
    }

    private var artworkY: CGFloat {
        blend(layoutSize.height / 2, model.notchClearance + 39)
    }

    private var glyphX: CGFloat {
        blend(layoutSize.width - 41, layoutSize.width - 53)
    }

    private var glyphY: CGFloat {
        blend(layoutSize.height / 2, model.notchClearance + 39)
    }

    private var textWidth: CGFloat {
        max(120, layoutSize.width - 228)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtworkTile(
                image: model.music.artwork,
                size: artworkSize,
                cornerRadius: blend(10, 18),
                isDimmed: !model.music.isPlaying
            )
            .position(x: artworkX, y: artworkY)
            .accessibilityHidden(true)

            TrackTextBlock(music: model.music)
                .frame(width: textWidth, alignment: .leading)
                .position(
                    x: 26 + 78 + 16 + textWidth / 2,
                    y: model.notchClearance + 36
                )
                .opacity(expandedOpacity)
                .offset(y: detailsVisible ? 0 : -6)
                .allowsHitTesting(false)
                .animation(detailsVisible ? IslandMotion.contentFade : IslandMotion.contentCollapse, value: detailsVisible)

            PlaybackGlyph(
                music: model.music,
                expansion: expansion,
                accentColor: model.music.accentColor
            )
            .position(x: glyphX, y: glyphY)
            .accessibilityHidden(true)

            ProgressStrip(music: model.music)
                .frame(width: max(180, layoutSize.width - 52))
                .position(x: layoutSize.width / 2, y: model.notchClearance + 103)
                .opacity(expandedOpacity)
                .offset(y: detailsVisible ? 0 : -4)
                .allowsHitTesting(false)
                .animation(detailsVisible ? IslandMotion.contentFade : IslandMotion.contentCollapse, value: detailsVisible)

            ExpandedControlRow(model: model)
                .frame(width: layoutSize.width - 52)
                .position(x: layoutSize.width / 2, y: layoutSize.height - 42)
                .opacity(expandedOpacity)
                .offset(y: detailsVisible ? 0 : 6)
                .animation(detailsVisible ? IslandMotion.contentFade : IslandMotion.contentCollapse, value: detailsVisible)
        }
        .compositingGroup()
        .onAppear {
            detailsVisible = model.isExpanded
        }
        .onChange(of: model.isExpanded) { isExpanded in
            if isExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.contentExpandDelay) {
                    guard model.isExpanded else { return }
                    withAnimation(IslandMotion.contentFade) {
                        detailsVisible = true
                    }
                }
            } else {
                withAnimation(IslandMotion.contentCollapse) {
                    detailsVisible = false
                }
            }
        }
    }
}

private struct TrackTextBlock: View {
    let music: MusicSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(music.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(music.artist)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
                .truncationMode(.tail)

            if let album = music.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

private struct ExpandedControlRow: View {
    @ObservedObject var model: MusicIslandModel

    var body: some View {
        HStack(spacing: 38) {
            Spacer(minLength: 0)

            Button {
                model.openMusic?()
            } label: {
                Image(systemName: "star")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.36))
                    .frame(width: 34, height: 36)
            }
            .buttonStyle(.plain)
            .help("Open Apple Music")

            HStack(spacing: 42) {
                ControlButton(systemName: "backward.fill") {
                    model.previousTrack?()
                }

                ControlButton(systemName: model.music.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                    model.togglePlayPause?()
                }

                ControlButton(systemName: "forward.fill") {
                    model.nextTrack?()
                }
            }

            Image(systemName: "airplayaudio")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.36))
                .frame(width: 34, height: 36)

            Spacer(minLength: 0)
        }
    }
}

private struct ArtworkTile: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat
    var isDimmed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let image = AppAssets.defaultArtwork() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
        }
        .frame(width: size, height: size)
        .brightness(isDimmed ? -0.10 : 0)
        .saturation(isDimmed ? 0.78 : 1)
        .opacity(isDimmed ? 0.72 : 1)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct PlaybackGlyph: View {
    let music: MusicSnapshot
    let expansion: CGFloat
    let accentColor: NSColor

    var body: some View {
        if music.isPlaying {
            WaveformView(expansion: expansion, accentColor: accentColor)
        } else {
            StaticWaveformView(expansion: expansion, accentColor: accentColor)
        }
    }
}

private struct StaticWaveformView: View {
    let expansion: CGFloat
    let accentColor: NSColor

    private var dotCount: Int { 7 }
    private var dotSize: CGFloat { blend(3.2, 5.0) }

    private func blend(_ compact: CGFloat, _ expanded: CGFloat) -> CGFloat {
        compact + (expanded - compact) * expansion
    }

    var body: some View {
        HStack(spacing: blend(4, 5)) {
            ForEach(0..<dotCount, id: \.self) { index in
                Capsule()
                    .fill(Color(nsColor: accentColor.waveformBaseColor).opacity(Double(blend(0.78, 0.9))))
                    .frame(width: dotSize, height: staticHeight(index))
            }
        }
        .frame(width: blend(42, 56), height: blend(25, 52))
    }

    private func staticHeight(_ index: Int) -> CGFloat {
        blend(dotSize, dotSize * staticHeightMultiplier(index))
    }

    private func staticHeightMultiplier(_ index: Int) -> CGFloat {
        let pattern: [CGFloat] = [4.0, 5.5, 6.8, 7.4, 6.6, 5.4, 4.3]
        return pattern[index % pattern.count]
    }
}

private struct WaveformView: View {
    let expansion: CGFloat
    let accentColor: NSColor

    private var barCount: Int { 7 }
    private var maxHeight: CGFloat { blend(25, 48) }
    private var minHeight: CGFloat { blend(5, 10) }

    private func blend(_ compact: CGFloat, _ expanded: CGFloat) -> CGFloat {
        compact + (expanded - compact) * expansion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let base = accentColor.waveformBaseColor
            let highlight = accentColor.waveformHighlightColor
            HStack(alignment: .center, spacing: blend(3, 4)) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: base),
                                    Color(nsColor: highlight)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: blend(3, 4.5), height: barHeight(index: index, time: time))
                }
            }
            .frame(width: blend(34, 54), height: maxHeight)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.72
        let primary = (sin(time * 6.5 + phase) + 1) / 2
        let secondary = (sin(time * 3.1 + phase * 1.8) + 1) / 2
        let mixed = 0.34 + 0.48 * primary + 0.18 * secondary
        return minHeight + (maxHeight - minHeight) * CGFloat(mixed)
    }
}

private struct ProgressStrip: View {
    let music: MusicSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = music.liveElapsed(at: context.date)
            let duration = music.duration
            let progress = progress(elapsed: elapsed, duration: duration)

            HStack(spacing: 8) {
                Text(timeText(elapsed))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(Color.white.opacity(0.62))
                            .frame(width: max(4, proxy.size.width * progress))
                    }
                }
                .frame(height: 5)

                Text(remainingText(elapsed: elapsed, duration: duration))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func progress(elapsed: TimeInterval?, duration: TimeInterval?) -> CGFloat {
        guard let elapsed, let duration, duration > 0 else { return 0 }
        return CGFloat(min(max(elapsed / duration, 0), 1))
    }

    private func timeText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "--:--" }
        return format(seconds)
    }

    private func remainingText(elapsed: TimeInterval?, duration: TimeInterval?) -> String {
        guard let elapsed, let duration, duration > 0 else { return "-:--" }
        return "-\(format(max(0, duration - elapsed)))"
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private struct ControlButton: View {
    let systemName: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 34 : 27, weight: .bold))
                .foregroundStyle(.white.opacity(prominent ? 0.96 : 0.74))
                .frame(width: prominent ? 50 : 42, height: 40)
        }
        .buttonStyle(.plain)
    }
}

private final class AppleMusicNowPlayingProvider: NSObject {
    private weak var model: MusicIslandModel?
    private var timer: Timer?
    private var isScriptQueryInFlight = false

    init(model: MusicIslandModel) {
        self.model = model
        super.init()
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleMusicPlayerInfo(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleMusicPlayerInfo(_:)),
            name: Notification.Name("com.apple.iTunes.playerInfo"),
            object: nil
        )

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        refreshFromNowPlayingInfoCenter()
        refreshFromMusicApp()
    }

    @objc private func handleMusicPlayerInfo(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        let title = (userInfo["Name"] as? String).nonEmpty ?? "Apple Music"
        let artist = (userInfo["Artist"] as? String).nonEmpty ?? "Unknown Artist"
        let album = (userInfo["Album"] as? String).nonEmpty
        let state = (userInfo["Player State"] as? String)?.lowercased()
        let isPlaying = state == "playing"

        let duration = seconds(from: userInfo["Total Time"], milliseconds: true)
        let elapsed = seconds(from: userInfo["Player Position"], milliseconds: false)

        let snapshot = MusicSnapshot(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            elapsed: elapsed,
            duration: duration,
            artwork: artworkImage(from: userInfo),
            updatedAt: Date(),
            hasTrack: true
        )

        DispatchQueue.main.async { [weak self] in
            self?.model?.updateMusic(snapshot)
        }

        refreshSoon()
    }

    private func refreshFromNowPlayingInfoCenter() {
        // MPNowPlayingInfoCenter is public. On macOS it may only expose metadata
        // visible to the current process, but keeping this path makes it easy to
        // plug in other public now-playing sources later.
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

        let title = (info[MPMediaItemPropertyTitle] as? String).nonEmpty
        let artist = (info[MPMediaItemPropertyArtist] as? String).nonEmpty
        guard title != nil || artist != nil else { return }

        var artwork: NSImage?
        if let itemArtwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            artwork = itemArtwork.image(at: CGSize(width: 240, height: 240))
        }

        let snapshot = MusicSnapshot(
            title: title ?? "Now Playing",
            artist: artist ?? "Unknown Artist",
            album: (info[MPMediaItemPropertyAlbumTitle] as? String).nonEmpty,
            isPlaying: ((info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? 0) > 0,
            elapsed: info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval,
            duration: info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval,
            artwork: artwork,
            updatedAt: Date(),
            hasTrack: true
        )

        DispatchQueue.main.async { [weak self] in
            self?.model?.updateMusic(snapshot)
        }
    }

    private func refreshFromMusicApp() {
        guard AppleMusicController.isMusicRunning else {
            DispatchQueue.main.async { [weak self] in
                self?.model?.updateMusic(.placeholder)
            }
            return
        }

        guard !isScriptQueryInFlight else { return }
        isScriptQueryInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AppleMusicController.readSnapshot()

            DispatchQueue.main.async {
                self?.isScriptQueryInFlight = false
                switch result {
                case let .success(snapshot):
                    self?.model?.appleScriptStatus = nil
                    self?.model?.updateMusic(snapshot)
                case let .failure(error):
                    self?.model?.appleScriptStatus = error.localizedDescription
                }
            }
        }
    }

    private func seconds(from value: Any?, milliseconds: Bool) -> TimeInterval? {
        let raw: Double?
        switch value {
        case let value as Double:
            raw = value
        case let value as Float:
            raw = Double(value)
        case let value as Int:
            raw = Double(value)
        case let value as String:
            raw = Double(value)
        default:
            raw = nil
        }

        guard let raw else { return nil }
        return milliseconds ? raw / 1000 : raw
    }

    private func artworkImage(from userInfo: [AnyHashable: Any]) -> NSImage? {
        if let image = userInfo["Artwork"] as? NSImage {
            return image
        }

        if let data = userInfo["ArtworkData"] as? Data {
            return NSImage(data: data)
        }

        return nil
    }
}

private enum AppleMusicController {
    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    static func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        NSWorkspace.shared.open(url)
    }

    static func playPause() {
        runAppleScript("""
        tell application "Music"
            playpause
        end tell
        """)
    }

    static func previousTrack() {
        runAppleScript("""
        tell application "Music"
            previous track
        end tell
        """)
    }

    static func nextTrack() {
        runAppleScript("""
        tell application "Music"
            next track
        end tell
        """)
    }

    static func readSnapshot() -> Result<MusicSnapshot, Error> {
        let source = """
        tell application "Music"
            if player state is stopped then return "__STOPPED__"

            set currentTrack to current track
            set trackName to name of currentTrack as text
            set artistName to artist of currentTrack as text
            set albumName to album of currentTrack as text
            set stateName to player state as text
            set durationSeconds to duration of currentTrack as real
            set positionSeconds to player position as real
            set artworkPath to ""

            try
                set trackID to persistent ID of currentTrack as text
                if (count of artworks of currentTrack) > 0 then
                    set artworkData to data of artwork 1 of currentTrack
                    set artworkPath to (POSIX path of (path to temporary items)) & "NotchIslandArtwork-" & trackID & ".img"
                    set fileRef to open for access POSIX file artworkPath with write permission
                    set eof of fileRef to 0
                    write artworkData to fileRef
                    close access fileRef
                end if
            on error
                try
                    close access POSIX file artworkPath
                end try
                set artworkPath to ""
            end try

            return trackName & linefeed & artistName & linefeed & albumName & linefeed & stateName & linefeed & (durationSeconds as text) & linefeed & (positionSeconds as text) & linefeed & artworkPath
        end tell
        """

        var errorInfo: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue else {
            return .failure(AppleScriptError(errorInfo: errorInfo))
        }

        if output == "__STOPPED__" {
            return .success(.placeholder)
        }

        let lines = output.components(separatedBy: .newlines)
        guard lines.count >= 6 else {
            return .failure(AppleScriptError(message: "Music returned incomplete track metadata."))
        }

        let artworkPath = lines.dropFirst(6).joined(separator: "\n").nonEmpty
        let artwork = artworkPath.flatMap { NSImage(contentsOfFile: $0) }

        let snapshot = MusicSnapshot(
            title: lines[0].nonEmpty ?? "Apple Music",
            artist: lines[1].nonEmpty ?? "Unknown Artist",
            album: lines[2].nonEmpty,
            isPlaying: lines[3].lowercased().contains("playing"),
            elapsed: TimeInterval(lines[5]),
            duration: TimeInterval(lines[4]),
            artwork: artwork,
            updatedAt: Date(),
            hasTrack: true
        )

        return .success(snapshot)
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }
}

private struct AppleScriptError: LocalizedError {
    let message: String

    init(message: String) {
        self.message = message
    }

    init(errorInfo: NSDictionary?) {
        if let message = errorInfo?[NSAppleScript.errorMessage] as? String {
            self.message = message
        } else {
            self.message = "Apple Music automation is unavailable."
        }
    }

    var errorDescription: String? {
        message
    }
}

private enum AppAssets {
    static func defaultArtwork() -> NSImage? {
        if let image = Bundle.module.image(forResource: "DefaultArtwork") {
            return image
        }

        // SwiftPM command-line builds can copy the asset catalog directory into
        // the resource bundle instead of compiling an Assets.car file.
        guard let url = Bundle.module.url(
            forResource: "DefaultArtwork",
            withExtension: "svg",
            subdirectory: "Assets.xcassets/DefaultArtwork.imageset"
        ) else {
            return nil
        }

        return NSImage(contentsOf: url)
    }
}

private extension NSImage {
    func dominantAccentColor() -> NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let stepX = max(1, width / 42)
        let stepY = max(1, height / 42)
        var samples: [RGBSample] = []

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                guard let rawColor = bitmap.colorAt(x: x, y: y),
                      let color = rawColor.usingColorSpace(.sRGB) else {
                    continue
                }

                var alpha: CGFloat = 0
                color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
                guard alpha > 0.25 else { continue }

                samples.append(
                    RGBSample(
                        red: color.redComponent,
                        green: color.greenComponent,
                        blue: color.blueComponent,
                        weight: alpha
                    )
                )
            }
        }

        return RGBCluster.dominantColor(in: samples, clusterCount: 5)?.normalizedForWaveform()
    }
}

private struct RGBSample {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var weight: CGFloat

    func distanceSquared(to other: RGBSample) -> CGFloat {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue
        return redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta
    }

    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

private struct RGBCluster {
    var centroid: RGBSample
    var redSum: CGFloat = 0
    var greenSum: CGFloat = 0
    var blueSum: CGFloat = 0
    var weightSum: CGFloat = 0

    mutating func reset() {
        redSum = 0
        greenSum = 0
        blueSum = 0
        weightSum = 0
    }

    mutating func add(_ sample: RGBSample) {
        redSum += sample.red * sample.weight
        greenSum += sample.green * sample.weight
        blueSum += sample.blue * sample.weight
        weightSum += sample.weight
    }

    mutating func updateCentroid() {
        guard weightSum > 0 else { return }
        centroid = RGBSample(
            red: redSum / weightSum,
            green: greenSum / weightSum,
            blue: blueSum / weightSum,
            weight: weightSum
        )
    }

    static func dominantColor(in samples: [RGBSample], clusterCount: Int) -> NSColor? {
        guard !samples.isEmpty else { return nil }

        var clusters = initialClusters(from: samples, count: min(clusterCount, samples.count))

        for _ in 0..<8 {
            for index in clusters.indices {
                clusters[index].reset()
            }

            for sample in samples {
                let nearestIndex = clusters.indices.min { first, second in
                    sample.distanceSquared(to: clusters[first].centroid) < sample.distanceSquared(to: clusters[second].centroid)
                } ?? 0
                clusters[nearestIndex].add(sample)
            }

            for index in clusters.indices {
                clusters[index].updateCentroid()
            }
        }

        return clusters.max { $0.weightSum < $1.weightSum }?.centroid.color
    }

    private static func initialClusters(from samples: [RGBSample], count: Int) -> [RGBCluster] {
        let average = averageSample(samples)
        var centroids = [average]

        while centroids.count < count {
            guard let next = samples.max(by: { first, second in
                nearestDistanceSquared(from: first, to: centroids) < nearestDistanceSquared(from: second, to: centroids)
            }) else {
                break
            }
            centroids.append(next)
        }

        return centroids.map { RGBCluster(centroid: $0) }
    }

    private static func averageSample(_ samples: [RGBSample]) -> RGBSample {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var weight: CGFloat = 0

        for sample in samples {
            red += sample.red * sample.weight
            green += sample.green * sample.weight
            blue += sample.blue * sample.weight
            weight += sample.weight
        }

        guard weight > 0 else {
            return samples[0]
        }

        return RGBSample(red: red / weight, green: green / weight, blue: blue / weight, weight: weight)
    }

    private static func nearestDistanceSquared(from sample: RGBSample, to centroids: [RGBSample]) -> CGFloat {
        centroids.map { sample.distanceSquared(to: $0) }.min() ?? 0
    }
}

private extension NSColor {
    static let notchIslandFallbackAccent = NSColor(srgbRed: 0.54, green: 0.80, blue: 1.0, alpha: 1)

    var waveformBaseColor: NSColor {
        shifted(brightnessMultiplier: 0.88, saturationDelta: 0.04)
    }

    var waveformHighlightColor: NSColor {
        shifted(brightnessMultiplier: 1.18, saturationDelta: -0.10)
    }

    func normalizedForWaveform() -> NSColor {
        guard let color = usingColorSpace(.sRGB) else { return .notchIslandFallbackAccent }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let isNeutral = saturation < 0.08
        let adjustedSaturation = isNeutral ? saturation : min(1, max(0.18, saturation))
        let adjustedBrightness = min(0.98, max(isNeutral ? 0.58 : 0.54, brightness))
        return NSColor(hue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness, alpha: 1)
    }

    private func shifted(brightnessMultiplier: CGFloat, saturationDelta: CGFloat) -> NSColor {
        guard let color = usingColorSpace(.sRGB) else { return .notchIslandFallbackAccent }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let isNeutral = saturation < 0.08
        let adjustedSaturation = isNeutral ? saturation : min(1, max(0.18, saturation + saturationDelta))

        return NSColor(
            hue: hue,
            saturation: adjustedSaturation,
            brightness: min(1, max(0.34, brightness * brightnessMultiplier)),
            alpha: 1
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
