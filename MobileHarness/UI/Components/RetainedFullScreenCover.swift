#if os(iOS)
    import SwiftUI
    import UIKit

    extension View {
        /// Full-screen inspection must not detach the live home renderer below it.
        func retainedFullScreenCover<Content: View>(
            isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
            @ViewBuilder content: @escaping () -> Content
        ) -> some View {
            background(
                RetainedCoverPresenter(isPresented: isPresented, onDismiss: onDismiss, content: content))
        }
    }

    @MainActor
    private struct RetainedCoverPresenter<Content: View>: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        let onDismiss: (() -> Void)?
        let content: () -> Content

        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeUIViewController(context: Context) -> CoverAnchor {
            let anchor = CoverAnchor()
            context.coordinator.anchor = anchor
            anchor.appeared = { [weak owner = context.coordinator] in owner?.reconcile() }
            return anchor
        }
        func updateUIViewController(_ anchor: CoverAnchor, context: Context) {
            let owner = context.coordinator
            owner.desired = $isPresented
            owner.onDismiss = onDismiss
            owner.content = content
            if let presented = owner.presented { presented.rootView = content() }
            owner.reconcile()
        }
        static func dismantleUIViewController(_ anchor: CoverAnchor, coordinator: Coordinator) {
            anchor.appeared = nil
            coordinator.stopped = true
            coordinator.desired = nil
            coordinator.reconcile()
        }

        @MainActor
        final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
            weak var anchor: CoverAnchor?
            var desired: Binding<Bool>?
            var onDismiss: (() -> Void)?
            var content: (() -> Content)?
            var presented: UIHostingController<Content>?
            var transitioning = false
            var stopped = false

            func reconcile() {
                guard !transitioning else { return }
                if !stopped, desired?.wrappedValue == true {
                    guard presented == nil, let anchor, anchor.viewIfLoaded?.window != nil,
                        anchor.presentedViewController == nil, let content
                    else { return }
                    let controller = UIHostingController(rootView: content())
                    controller.modalPresentationStyle = .overFullScreen
                    presented = controller
                    transitioning = true
                    // Keep the owner through the transition so dismantling can join dismissal.
                    anchor.present(controller, animated: true) { [self] in
                        transitioning = false
                        reconcile()
                    }
                    controller.presentationController?.delegate = self
                } else if let controller = presented {
                    transitioning = true
                    controller.dismiss(animated: !stopped) { [self] in finish(controller) }
                }
            }

            private func finish(_ controller: UIViewController) {
                guard presented === controller else { return }
                presented = nil
                transitioning = false
                onDismiss?()
                reconcile()
            }

            func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
                guard presented === presentationController.presentedViewController else { return }
                desired?.wrappedValue = false
                finish(presentationController.presentedViewController)
            }
        }
    }

    @MainActor
    private final class CoverAnchor: UIViewController {
        var appeared: (() -> Void)?
        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
        }
    }
#endif
