#if os(iOS)
    import Testing
    import UIKit

    @testable import UI

    @Test @MainActor func eyeGazeFollowsSuccessiveTargetsWithoutPositionAnimation() throws {
        let view = CompanionSurfaceView(haloEnabled: false)
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        defer { view.dispose() }
        var input = NativeCompanionSurface(
            phase: .idle, reduceMotion: false, expression: .clear,
            gaze: CGSize(width: 1, height: -1), faceWidth: 100,
            eyeCenter: CGPoint(x: 100, y: 100), haloEnabled: false, active: false)

        view.apply(input, foreground: true)
        let gazeLayer = try #require(view.layer.sublayers?.first?.sublayers?.first)
        #expect(abs(gazeLayer.position.x - 14) < 0.001)
        #expect(abs(gazeLayer.position.y + 9) < 0.001)
        #expect(gazeLayer.animationKeys()?.isEmpty ?? true)

        input.gaze = CGSize(width: -0.5, height: 0.5)
        view.apply(input, foreground: true)
        #expect(abs(gazeLayer.position.x + 7) < 0.001)
        #expect(abs(gazeLayer.position.y - 4.5) < 0.001)
        #expect(gazeLayer.animationKeys()?.isEmpty ?? true)

        input.faceWidth = 200
        view.apply(input, foreground: true)
        #expect(abs(gazeLayer.position.x + 14) < 0.001)
        #expect(abs(gazeLayer.position.y - 9) < 0.001)
    }
#endif
