import Foundation
import Testing

@testable import UI

@Test func galleryUsesStableIdentityAndDoesNotWrapAtTheEnds() {
    let ids = (1...20).map { "preview_\($0)" }
    #expect(CameraGalleryNavigation.index(nil, in: ids) == 19)
    #expect(CameraGalleryNavigation.moved("preview_1", by: -1, in: ids) == nil)
    #expect(CameraGalleryNavigation.moved("preview_20", by: 1, in: ids) == nil)
    #expect(CameraGalleryNavigation.moved("preview_10", by: 1, in: ids) == "preview_11")
    let rolled = Array(ids.dropFirst()) + ["preview_21"]
    #expect(CameraGalleryNavigation.retainedSelection("preview_1", in: rolled) == "preview_2")
    #expect(CameraGalleryNavigation.retainedSelection("preview_10", in: rolled) == "preview_10")
    #expect(CameraGalleryNavigation.retainedSelection(nil, in: rolled) == nil)
    #expect(CameraGalleryNavigation.retainedSelection("preview_1", in: []) == nil)
}
@Test @MainActor func galleryCatalogRetainsFlagsAndSessionChangeClearsPresentation() throws {
    let root = UIContainer()
    try root.start()
    let ui = root.camera
    ui.present(
        .gallery(
            "first",
            [.init(id: "preview_1", status: "pending"), .init(id: "preview_2", status: "saved", mediaID: "media_1")]))
    #expect(ui.snapshot.previews.count == 2)
    #expect(ui.snapshot.previews.first?.status == "pending")
    ui.present(.gallery(nil, []))
    #expect(ui.snapshot.gallerySession == nil && ui.snapshot.previews.isEmpty)
}
