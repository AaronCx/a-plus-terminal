import Foundation
import Observation
import WebKit

// ============================================================================
// THIS IS THE ONE PART OF PREVIEW THAT INJECTS JAVASCRIPT INTO THE USER'S PAGE.
// ============================================================================
//
// Everything else in the preview stack is subtractive — the navigation guard
// and the content rule list in `PreviewScreen.swift` only ever *refuse* things.
// This file is the exception: it installs a `WKUserScript` that replaces
// `console.log/warn/error/info/debug` on the previewed document so a phone with
// no Web Inspector can still read what the dev server's page is saying. That is
// genuinely useful, and it is also the kind of thing a user has every right to
// be told about before it happens.
//
// The contract, which the CALLER enforces (`PreviewScreen` / `AppSettings`):
//
//  1. OFF BY DEFAULT. While the setting is off, NO `WKUserScript` is added to
//     the configuration's `userContentController` and NO message handler is
//     registered. Not "installed but inert" — absent. A page must not be able
//     to detect that the feature exists, and code that never ran cannot have a
//     bug in it.
//  2. Registering the handler is itself observable by the page: adding a
//     handler exposes `window.webkit.messageHandlers.<name>` to EVERY frame of
//     the document, whether or not we injected our script there. So the
//     handler goes on at the same moment as the script, and comes off with it
//     (`removeScriptMessageHandler(forName:)` + `removeAllUserScripts()`).
//  3. The toggle is disclosed in the UI in plain words ("runs a small script in
//     the page to capture its console output"), and flipping it ON only takes
//     effect on the next load: `.atDocumentStart` injection applies to
//     documents created after the script was added, so the caller reloads.
//  4. Captured lines never leave the device and are never persisted — they live
//     in the `entries` array below and die with the sheet, same as the
//     preview's non-persistent website data store. Zero data collection is a
//     property of the whole app, and a log view is not an exception to it.
//
// The JS is written defensively on the assumption that the page is hostile *and*
// that the page is fragile: it must never change what the page's own logging
// does, and it must never throw into the page's script execution.

/// One captured console line.
struct PreviewConsoleEntry: Identifiable, Equatable, Sendable {
    /// Monotonic per-console counter, never reused (not even after `clear()`),
    /// so SwiftUI's `ForEach` diffing can't confuse a recycled id for a moved
    /// row and animate the wrong line.
    let id: Int
    let level: Level
    let text: String
    let at: Date

    enum Level: String, Sendable {
        case log, warn, error, info, debug
    }
}

/// Sink for the previewed page's console output. Pure state plus two static,
/// side-effect-free functions (`userScriptSource()`, `entry(from:id:at:)`) so
/// the two things worth testing — the exact JS we inject, and the parser for a
/// payload the page fully controls — are testable without a `WKWebView`.
@MainActor
@Observable
final class PreviewConsole {
    /// Ring capacity. Small on purpose: this is a phone-sized log view, and a
    /// dev server in a render loop can emit thousands of lines a second. Older
    /// lines are the ones you scrolled past; the tail is what you opened the
    /// panel for.
    nonisolated static let maxEntries = 200

    /// Hard cap on the characters of any one captured line. Enforced twice —
    /// in the injected JS (so one giant object doesn't get copied across the
    /// WebKit IPC boundary at all) and again in `entry(from:)`, because a page
    /// can call `postMessage` directly and is under no obligation to respect
    /// the cap our own script applies.
    nonisolated static let maxMessageLength = 2000

    /// The handler name the page sees as
    /// `window.webkit.messageHandlers.aplusPreviewConsole`. Deliberately
    /// app-specific: it appears in the page's global namespace, and a generic
    /// name ("console", "logger") would be more likely to collide with
    /// something the dev server itself installs.
    nonisolated static let messageHandlerName = "aplusPreviewConsole"

    /// Oldest-first, capped at `maxEntries`.
    private(set) var entries: [PreviewConsoleEntry] = []

    /// Never resets, including across `clear()` — see `PreviewConsoleEntry.id`.
    private var nextID = 0

    init() {}

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Appends, evicting the oldest lines once the cap is exceeded.
    func append(_ entry: PreviewConsoleEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// The bridge's entry point: parse one page-supplied body and store it.
    /// Unparseable bodies are dropped silently — a page that posts junk to our
    /// handler gets nothing, not an error line it can use to spam the view.
    ///
    /// No throttling here beyond the cap: `@Observable` mutations coalesce into
    /// at most one SwiftUI update per frame, so a page logging in a `rAF` loop
    /// costs an array append and an eviction per message, not a re-render each.
    func record(_ body: Any, at: Date = Date()) {
        guard let entry = Self.entry(from: body, id: nextID, at: at) else { return }
        nextID += 1
        append(entry)
    }

    // MARK: - Parsing (pure)

    /// Parses one message body from the page into an entry, or nil if there's
    /// nothing displayable in it.
    ///
    /// EVERY byte of `body` is attacker-controlled — `postMessage` is reachable
    /// from any script in the document, our wrapper is not the only caller, and
    /// nothing stops a page from posting a 50 MB string, a nested array, a
    /// `level` of `"<script>"`, or no `text` at all. So: dictionaries only,
    /// `text` must actually be a `String`, an unknown or missing `level`
    /// degrades to `.log` rather than dropping the line (the text is the part
    /// with the information in it), and the string is sanitised and clipped in
    /// a SINGLE pass that stops at the cap — deliberately not
    /// `String(text.prefix(...))` on the raw value, because that still walks and
    /// copies characters we've already decided to throw away.
    nonisolated static func entry(from body: Any, id: Int, at: Date) -> PreviewConsoleEntry? {
        guard let payload = body as? [String: Any] else { return nil }
        guard let raw = payload["text"] as? String else { return nil }

        // Bound the work before lowercasing: `level` is a page-supplied string
        // and could itself be enormous (lowercasing 50 MB on the main actor is
        // a hang). No real level is longer than "error"; anything else — a
        // missing key, "trace", markup, a number — degrades to `.log`.
        let level = (payload["level"] as? String)
            .map { raw -> PreviewConsoleEntry.Level in
                let name = raw.prefix(16).trimmingCharacters(in: .whitespaces).lowercased()
                return PreviewConsoleEntry.Level(rawValue: name) ?? .log
            } ?? .log

        return PreviewConsoleEntry(id: id, level: level, text: clip(raw), at: at)
    }

    /// Sanitise + truncate in one pass over `Character`s, bailing at the cap.
    ///
    /// Control characters are dropped rather than rendered: the panel is a
    /// SwiftUI text view, not a terminal, and a page that logs raw ANSI escape
    /// sequences (dev servers do this constantly — the same string they'd write
    /// to a TTY) would otherwise fill the view with invisible junk. Newlines
    /// survive, normalised, because multi-line log output is the point.
    /// How many scalars this will look at, regardless of how few survive.
    /// Without a budget on *consumed* input the loop is bounded only by the
    /// length of a string the page chose, which is not a bound at all.
    private nonisolated static let maxScannedScalars = maxMessageLength * 4

    private nonisolated static func clip(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var kept = 0
        var scanned = 0
        // Unicode *scalars*, not Characters. A `Character` is a grapheme
        // cluster of unbounded length, so `"a" + "\u{301}" * 50_000_000` is a
        // single Character: a cap counted in Characters would admit it whole,
        // walk 50M scalars inside `unicodeScalars.contains`, and store ~100 MB
        // in a 200-entry ring. Scalars make the cap mean something.
        for scalar in text.unicodeScalars {
            // EVERY scalar counts against the scan budget, including the ones
            // dropped below. This is the part that was wrong: control
            // characters used to `continue` without counting, so a page
            // logging megabytes of ANSI escapes (dev servers do this
            // constantly — the same bytes they'd write to a TTY) walked the
            // entire string on the main thread. `record` runs main-actor via
            // the script-message handler, so that was a hang, and a page can
            // fire it in a loop: a watchdog kill that would take the user's
            // live SSH sessions with it.
            scanned += 1
            if scanned > maxScannedScalars || kept >= maxMessageLength {
                scalars.append("…")
                break
            }
            if scalar == "\n" || scalar == "\r" {
                // Multi-line log output is the point; \r\n collapses to one.
                if scalars.last != "\n" || scalar == "\n" { scalars.append("\n") }
            } else if scalar == "\t" {
                scalars.append(scalar)
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                continue   // dropped from the output, but still counted above
            } else {
                scalars.append(scalar)
            }
            kept += 1
        }
        return String(scalars)
    }

    // MARK: - Injection

    /// The user script, built with the two decisions that matter:
    ///
    /// `.atDocumentStart` — the wrapper has to be in place before the page's
    /// own scripts run, or every log line emitted during module evaluation and
    /// first paint (exactly the ones you're debugging on a phone) is lost. It
    /// also means we capture the *original* `console` methods, before any
    /// framework's logger has replaced them.
    ///
    /// `forMainFrameOnly: true` — and `false` would be wrong here, for three
    /// reasons. (a) This is the one place the app injects script into a page it
    /// doesn't own; "every frame of every document" is a materially bigger
    /// promise to make the user than "the page you opened", and the feature
    /// doesn't need it. (b) The entries array is one global 200-line ring with
    /// no frame attribution in the UI, so a page with a handful of chatty
    /// iframes (analytics stubs, embeds, a dev overlay) would evict the main
    /// frame's real output with lines the user can't place — the log view is
    /// worse than useless at that point. (c) A page can create frames faster
    /// than a human can read, and each injected frame is another
    /// `console.log` → `postMessage` pump into the same ring.
    ///
    /// Note the asymmetry this creates, and why the bridge closes it:
    /// restricting *injection* to the main frame does NOT restrict *access* to
    /// the handler — `webkit.messageHandlers` is exposed to every frame once
    /// the handler is registered — so `PreviewConsoleBridge` drops anything
    /// that didn't come from the main frame.
    static func userScript() -> WKUserScript {
        WKUserScript(source: userScriptSource(), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// The injected script. Static and pure so a test can assert on it (and so
    /// the exact text of what we run inside a user's page is reviewable in one
    /// place). Kept ES5-shaped and free of anything the page could have already
    /// replaced by the time it runs.
    nonisolated static func userScriptSource() -> String {
        """
        (function () {
          try {
            var w = window;
            // Injection is once per document, but a page is free to re-evaluate
            // us (or inline the same source); double-wrapping would post every
            // line twice and, worse, could nest the pass-through.
            if (w.__aPlusPreviewConsoleInstalled) { return; }
            w.__aPlusPreviewConsoleInstalled = true;

            var target = w.console;
            if (!target) { return; }

            var LIMIT = \(maxMessageLength);
            // Snapshot our dependencies now, at document start, before the page
            // has had a chance to replace them. A page whose JSON.stringify
            // throws (or recurses into console.log) must not be able to reach
            // in through the capture path.
            var json = w.JSON;
            var stringify = (json && typeof json.stringify === 'function') ? json.stringify : null;
            var hasWeakSet = (typeof w.WeakSet === 'function');
            var WeakSetRef = w.WeakSet;

            // Re-entrancy latch: a getter or toJSON on a logged object can call
            // console.log itself. Without this, serialising one object logs,
            // which serialises, which logs — a hang inside the user's page,
            // caused by us.
            var capturing = false;

            function post(level, text) {
              try {
                var bridge = w.webkit && w.webkit.messageHandlers
                  && w.webkit.messageHandlers.\(messageHandlerName);
                // Absent whenever the setting is off, and absent again the
                // moment the caller removes the handler — this is the only
                // reason the wrapper can outlive the bridge harmlessly.
                if (!bridge || typeof bridge.postMessage !== 'function') { return; }
                bridge.postMessage({ level: level, text: text });
              } catch (e) { /* handler torn down mid-page; nothing to do */ }
            }

            function describe(v) {
              var t = typeof v;
              // Clip here, not after concatenating: returning a 50 MB argument
              // verbatim materialises the whole thing (and copies it again in
              // serialize) before the cap at the end ever runs.
              if (t === 'string') { return v.length > LIMIT ? v.slice(0, LIMIT) + '…' : v; }
              if (v === null) { return 'null'; }
              if (t === 'undefined') { return 'undefined'; }
              // String() is safe for symbols and bigints where '' + v throws.
              if (t !== 'object' && t !== 'function') {
                try { return String(v); } catch (e) { return '[' + t + ']'; }
              }
              if (t === 'function') {
                try { return '[Function' + (v.name ? ': ' + v.name : '') + ']'; } catch (e) { return '[Function]'; }
              }
              try {
                // Errors are the highest-value thing on this screen: the stack
                // is the whole reason you opened the panel.
                if (v instanceof Error) {
                  return v.stack || ((v.name || 'Error') + ': ' + v.message);
                }
              } catch (e) { /* cross-realm or exotic object */ }
              try {
                // JSON.stringify of a DOM node is '{}' — useless, and dev pages
                // log elements constantly.
                if (typeof v.nodeName === 'string' && typeof v.nodeType === 'number') {
                  return '<' + v.nodeName.toLowerCase() + '>';
                }
              } catch (e) { /* throwing property getter */ }
              if (stringify) {
                try {
                  var seen = hasWeakSet ? new WeakSetRef() : null;
                  var out = stringify.call(json, v, function (key, val) {
                    if (val !== null && typeof val === 'object') {
                      // Circular graphs are normal (any DOM-adjacent or store
                      // object) and stringify throws on them; mark and move on
                      // rather than losing the whole line.
                      if (seen) {
                        if (seen.has(val)) { return '[Circular]'; }
                        seen.add(val);
                      }
                    }
                    if (typeof val === 'bigint') { return String(val); }
                    // Clip huge leaf strings inside the walk: this is what
                    // stops one 50 MB field from being copied in full before
                    // we truncate it. We can't stop the page from *holding*
                    // that value, only from paying to serialise all of it.
                    if (typeof val === 'string' && val.length > LIMIT) {
                      return val.slice(0, LIMIT) + '…';
                    }
                    return val;
                  });
                  if (typeof out === 'string') { return out; }
                } catch (e) { /* toJSON threw, or a replacer-proof cycle */ }
              }
              try { return String(v); } catch (e) { return '[object]'; }
            }

            function serialize(args) {
              var out = '';
              for (var i = 0; i < args.length && out.length < LIMIT; i++) {
                out += (i ? ' ' : '') + describe(args[i]);
              }
              return out.length > LIMIT ? out.slice(0, LIMIT) + '…' : out;
            }

            var levels = ['log', 'warn', 'error', 'info', 'debug'];
            for (var n = 0; n < levels.length; n++) {
              (function (level) {
                var original = target[level];
                target[level] = function () {
                  // ALWAYS call through, FIRST, and preserve the original's
                  // observable behaviour exactly — including a throw. Capturing
                  // a page's logging must never change what that logging does;
                  // silently swallowing here would make Web Inspector and this
                  // panel disagree, which is the worst possible debugging tool.
                  var result, thrown, didThrow = false;
                  try {
                    if (typeof original === 'function') {
                      result = original.apply(target, arguments);
                    }
                  } catch (e) { thrown = e; didThrow = true; }
                  if (!capturing) {
                    capturing = true;
                    try { post(level, serialize(arguments)); } catch (e) {} finally { capturing = false; }
                  }
                  if (didThrow) { throw thrown; }
                  return result;
                };
              })(levels[n]);
            }
            // console stays writable on purpose: a page that installs its own
            // logger over ours (many frameworks do) simply stops being
            // captured. Locking these down with defineProperty would keep
            // capture alive at the cost of breaking the user's app — the wrong
            // trade for a debugging aid.
          } catch (e) {
            // Last resort. Whatever went wrong in here, the page's own scripts
            // are about to run and must not inherit our exception.
          }
        })();
        """
    }
}

/// `WKScriptMessageHandler` for the console bridge.
///
/// Holds NOTHING that could close a retain cycle: `WKUserContentController`
/// retains its handlers strongly and forever (the classic WKWebView leak — a
/// handler that is also the view controller keeps the whole screen, its web
/// view and its content controller alive after dismissal), so this object owns
/// only a closure with a `weak` capture of the console and never sees the web
/// view or the controller at all. Even a leaked bridge leaks one closure.
///
/// The caller is still responsible for `removeScriptMessageHandler(forName:)`
/// on teardown — see `remove(from:)` — because until that runs the page can
/// still see `webkit.messageHandlers.aplusPreviewConsole`, and the contract at
/// the top of this file says it only exists while the setting is on.
final class PreviewConsoleBridge: NSObject, WKScriptMessageHandler {
    private let deliver: @MainActor (Any, Date) -> Void

    init(console: PreviewConsole) {
        // `weak` is the whole point: the controller owns this bridge, the sheet
        // owns the console, and neither may keep the other alive.
        self.deliver = { [weak console] body, at in
            console?.record(body, at: at)
        }
        super.init()
    }

    /// Escape hatch for tests and for any caller that wants delivery somewhere
    /// other than a `PreviewConsole`. The closure must not capture the web view
    /// or the content controller.
    init(deliver: @escaping @MainActor (Any, Date) -> Void) {
        self.deliver = deliver
        super.init()
    }

    /// Adds the script and the handler together — the two halves of the
    /// disclosure are never installed separately. Call ONLY when the setting is
    /// on; the returned bridge is retained by `controller`, so the caller
    /// doesn't need to hold it, only to `remove(from:)` it later.
    @discardableResult
    @MainActor
    static func install(in controller: WKUserContentController, console: PreviewConsole) -> PreviewConsoleBridge {
        let bridge = PreviewConsoleBridge(console: console)
        // Re-registering the same name traps in WebKit, so clear first: the
        // settings toggle can flip on, off and on again inside one sheet.
        controller.removeScriptMessageHandler(forName: PreviewConsole.messageHandlerName)
        controller.add(bridge, name: PreviewConsole.messageHandlerName)
        controller.addUserScript(PreviewConsole.userScript())
        return bridge
    }

    /// Removes both halves. `removeAllUserScripts()` is the only API WebKit
    /// offers — there is no per-script removal — which is safe here precisely
    /// because this is the *only* user script the preview ever installs. If
    /// another one is ever added, this has to become a rebuild of the full
    /// script list, or it will silently uninstall that one too.
    @MainActor
    static func remove(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: PreviewConsole.messageHandlerName)
        controller.removeAllUserScripts()
    }

    /// WebKit delivers on the main thread; `assumeIsolated` is how this
    /// codebase crosses that line (see `PreviewWebView.Coordinator`) rather
    /// than hopping and letting log lines arrive out of order with the page
    /// state that produced them.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == PreviewConsole.messageHandlerName else { return }
            // The script is main-frame-only, but the HANDLER is visible to every
            // frame in the document — registering it puts
            // `webkit.messageHandlers.aplusPreviewConsole` in every subframe's
            // global, injected or not. Without this guard, an iframe could post
            // 200 lines and evict everything the user actually wanted to read,
            // and the panel would attribute them to the main page.
            guard message.frameInfo.isMainFrame else { return }
            deliver(message.body, Date())
        }
    }
}
