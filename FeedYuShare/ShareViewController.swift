import UIKit
import UniformTypeIdentifiers

/// Share-sheet target: accepts a Google Maps share (a URL, or text
/// containing one), drops the link in the ShareInbox for the main app, shows
/// a brief confirmation, and dismisses. No UI beyond the confirmation card —
/// naming/toggling happens in the app's Settings.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        Task { await handleShare() }
    }

    private func handleShare() async {
        let urlString = await extractURLString()
        if let urlString {
            ShareInbox.append(urlString)
        }
        let message = urlString != nil
            ? String(localized: "Saved! FeedYu adds this list next time you open it.")
            : String(localized: "No link found in the share.")
        showConfirmation(message, success: urlString != nil)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func extractURLString() async -> String? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let raw = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = raw as? URL, url.scheme?.hasPrefix("http") == true {
                    return url.absoluteString
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let raw = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    let text = (raw as? String) ?? String(decoding: (raw as? Data) ?? Data(), as: UTF8.self)
                    if let url = ShareInbox.firstHTTPURL(in: text) { return url }
                }
            }
        }
        return nil
    }

    private func showConfirmation(_ message: String, success: Bool) {
        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
        icon.tintColor = success ? .systemGreen : .systemOrange
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .callout)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(label)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -64),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
    }
}
