import SwiftUI
import WebKit

/// The canonical hosted Help page — also viewable on the web, kept editable in
/// one place. See `scottsapps.github.io/veyrn-help.html` (this file's bundled
/// copy in `Resources/` plus `HelpCache` are how it works offline).
private let veyrnHelpURL = URL(string: "https://scottsapps.angstreich.net/veyrn-help.html")!

/// Help is a WebView-backed screen showing the hosted Help page. It always
/// attempts the live URL first (so edits are visible immediately when online)
/// and falls back to the last-good cached copy — which is itself seeded from
/// the bundled `help.html` on first-ever use — on any load failure. Never
/// white-screens, even on a fresh install in airplane mode.
struct HelpView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpWebView(theme: colorScheme == .dark ? "dark" : "light")
            .onAppear { VeyrnTelemetry.signal("Help.viewed") }
            .navigationTitle("Help")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

/// A dismissible wrapper for presenting `HelpView` as a sheet — onboarding
/// shows Help before there's a `NavigationStack` to push into, on either
/// platform, so this supplies its own chrome and Done button.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - WebView (platform representable, shared factory)

#if os(iOS)
private struct HelpWebView: UIViewRepresentable {
    let theme: String

    func makeCoordinator() -> HelpWebCoordinator { HelpWebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        HelpWebFactory.makeWebView(theme: theme, coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        HelpWebFactory.updateTheme(theme, webView: webView, coordinator: context.coordinator)
    }
}
#else
private struct HelpWebView: NSViewRepresentable {
    let theme: String

    func makeCoordinator() -> HelpWebCoordinator { HelpWebCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        HelpWebFactory.makeWebView(theme: theme, coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        HelpWebFactory.updateTheme(theme, webView: webView, coordinator: context.coordinator)
    }
}
#endif

/// `WKWebView` itself is identical on both platforms — only the
/// `*ViewRepresentable` conformance above differs — so the setup/update logic
/// is shared here instead of duplicated per platform.
private enum HelpWebFactory {
    static func makeWebView(theme: String, coordinator: HelpWebCoordinator) -> WKWebView {
        let userScript = WKUserScript(
            source: themeScript(for: theme),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(userScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.lastTheme = theme

        // Attempt the live page first so edits are visible immediately when
        // online; the coordinator falls back to the cached/bundled copy on any
        // load failure. In parallel, refresh the on-disk fallback so an offline
        // user later sees this fetch's content rather than the stale bundled seed.
        webView.load(URLRequest(url: veyrnHelpURL))
        HelpCache.shared.refresh(from: veyrnHelpURL)

        return webView
    }

    static func updateTheme(_ theme: String, webView: WKWebView, coordinator: HelpWebCoordinator) {
        guard coordinator.lastTheme != theme else { return }
        coordinator.lastTheme = theme
        webView.evaluateJavaScript(themeScript(for: theme), completionHandler: nil)
    }

    /// Overrides the page's own localStorage/prefers-color-scheme default (set
    /// by site.js) to match the device's appearance. Double-quoted JS string —
    /// "light"/"dark" never contain a quote.
    static func themeScript(for theme: String) -> String {
        """
        (function(){
          document.documentElement.setAttribute('data-theme', "\(theme)");
          if (document.body) document.body.setAttribute('data-theme', "\(theme)");
        })();
        """
    }
}

final class HelpWebCoordinator: NSObject, WKNavigationDelegate {
    var lastTheme: String = ""
    private var didFallBack = false

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fallBackToLocal(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fallBackToLocal(webView)
    }

    private func fallBackToLocal(_ webView: WKWebView) {
        guard !didFallBack, let localURL = HelpCache.shared.cachedFileURL() else { return }
        didFallBack = true
        webView.loadFileURL(localURL, allowingReadAccessTo: localURL.deletingLastPathComponent())
    }
}
