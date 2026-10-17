import AppKit
import WebKit

/// The Workbench window: the web pages in a WKWebView, with a native placeholder while the server
/// starts or when it can't. Links that leave Workbench open in your default browser.
@MainActor
final class MainWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
  private let webView: WKWebView
  private let placeholder = NSStackView()
  private let spinner = NSProgressIndicator()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let retryButton = NSButton(title: "Restart Server", target: nil, action: #selector(AppDelegate.restartServer(_:)))
  private let logButton = NSButton(title: "Show Server Log", target: nil, action: #selector(AppDelegate.showServerLog(_:)))
  private var loaded = false
  private var pendingPath: String?

  init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isInspectable = true
    webView.allowsBackForwardNavigationGestures = true

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Workbench"
    window.minSize = NSSize(width: 720, height: 480)
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("WorkbenchMain")
    window.tabbingMode = .disallowed
    super.init(window: window)
    window.delegate = self

    webView.navigationDelegate = self
    webView.uiDelegate = self
    buildContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Shows what the server is doing; loads the pages the first time it's up.
  func serverChanged(_ state: ServerProcess.State) {
    switch state {
    case .starting:
      showPlaceholder("Starting Workbench…", failed: false)
    case .running:
      if loaded {
        // A restarted server: pick up where the page was.
        webView.reload()
      } else {
        loaded = true
        load(pendingPath ?? "/")
      }
      placeholder.isHidden = true
      webView.isHidden = false
    case let .failed(reason):
      showPlaceholder(reason, failed: true)
    }
  }

  /// Opens a Workbench page ("/prs"), now or once the server is up.
  func open(path: String) {
    showWindow(nil)
    NSApp.activate()
    if loaded { load(path) } else { pendingPath = path }
  }

  @objc func reloadPage(_ sender: Any?) { webView.reload() }
  @objc func goBack(_ sender: Any?) { webView.goBack() }
  @objc func goForward(_ sender: Any?) { webView.goForward() }

  private func load(_ path: String) {
    webView.load(URLRequest(url: URL(string: path, relativeTo: Config.baseURL)!))
  }

  private func buildContent() {
    spinner.style = .spinning
    spinner.controlSize = .regular
    message.alignment = .center
    message.textColor = .secondaryLabelColor
    message.preferredMaxLayoutWidth = 420
    let buttons = NSStackView(views: [retryButton, logButton])
    placeholder.orientation = .vertical
    placeholder.spacing = 14
    placeholder.setViews([spinner, message, buttons], in: .center)

    let content = NSView()
    for view in [webView, placeholder] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      webView.topAnchor.constraint(equalTo: content.topAnchor),
      webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      placeholder.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
    window?.contentView = content
    showPlaceholder("Starting Workbench…", failed: false)
  }

  private func showPlaceholder(_ text: String, failed: Bool) {
    // Once pages are showing, a quick restart isn't worth hiding them for.
    if loaded && !failed { return }
    message.stringValue = text
    spinner.isHidden = failed
    if failed { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    retryButton.superview?.isHidden = !failed
    webView.isHidden = true
    placeholder.isHidden = false
  }

  private static func isWorkbench(_ url: URL) -> Bool {
    ["127.0.0.1", "localhost"].contains(url.host ?? "") && url.port == Config.port
  }

  // MARK: Links

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let url = action.request.url else { return .cancel }
    // Frames inside a page, and Workbench's own pages, stay here.
    if action.targetFrame?.isMainFrame == false || Self.isWorkbench(url) || ["about", "blob", "data"].contains(url.scheme ?? "") {
      return .allow
    }
    // GitHub, Linear, Google sign-in (which refuses embedded browsers) and claude:// links.
    NSWorkspace.shared.open(url)
    return .cancel
  }

  /// target="_blank": Workbench pages open here, everything else in your browser.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url {
      if Self.isWorkbench(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
    }
    return nil
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.reload()
  }

  // MARK: alert() and confirm(), which WKWebView drops unless the app shows them

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
    let alert = NSAlert()
    alert.messageText = message
    await present(alert)
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    return await present(alert) == .alertFirstButtonReturn
  }

  @discardableResult
  private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    guard let window else { return alert.runModal() }
    return await alert.beginSheetModal(for: window)
  }
}
