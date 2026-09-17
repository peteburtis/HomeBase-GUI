//
//  CameraToolbarStatus.swift
//  HomeBase-GUI
//

#if os(iOS)
import SwiftUI
import UIKit

// Use UIKit's glass configurations so noninteractive status text shares the
// system appearance of the toolbar buttons. Keep status capsules compact and
// expose them to accessibility as static text, without a custom-painted fill.
struct CameraToolbarStatus: UIViewRepresentable {
    let title: String
    var prominent = false
    var monospacedDigits = false
    var showsActivityIndicator = false
    var accessibilityValue: String? = nil

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton()
        button.isUserInteractionEnabled = false
        button.accessibilityTraits = .staticText
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        var configuration: UIButton.Configuration = prominent
            ? .prominentGlass()
            : .glass()
        configuration.title = title
        configuration.showsActivityIndicator = showsActivityIndicator
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 8,
            leading: 14,
            bottom: 8,
            trailing: 14
        )
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                let font = monospacedDigits
                    ? UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
                    : UIFont.systemFont(ofSize: 16, weight: .medium)
                attributes.font = UIFontMetrics(forTextStyle: .callout)
                    .scaledFont(for: font)
                return attributes
            }
        if prominent {
            configuration.baseBackgroundColor = .systemRed
        }
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityValue = accessibilityValue
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIButton,
        context: Context
    ) -> CGSize? {
        uiView.intrinsicContentSize
    }
}
#endif
