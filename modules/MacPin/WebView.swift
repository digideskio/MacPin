//class MPWebView: WKWebView {
//http://stackoverflow.com/questions/27487821/cannot-subclass-wkwebview
	// allow controlling drags out of a MacPin window
	//  API pending https://bugs.webkit.org/show_bug.cgi?id=143618
	// https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragsource.html#//apple_ref/doc/uid/20000976-CJBFBADF
	// https://developer.apple.com/library/mac/documentation/Cocoa/Reference/ApplicationKit/Classes/NSView_Class/index.html#//apple_ref/occ/instm/NSView/beginDraggingSessionWithItems:event:source:
	// override func beginDraggingSessionWithItems(items: [AnyObject], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession
//}

import WebKit
import WebKitPrivates
import JavaScriptCore

@objc protocol WebViewScriptExports: JSExport { // $.WebView & $.browser.tabs[WebView]
	init?(object: [String:AnyObject]) //> new WebView({url: 'http://example.com'});
	// can only JSExport one init*() func!
	// https://github.com/WebKit/webkit/blob/master/Source/JavaScriptCore/API/tests/testapi.mm
	// https://github.com/WebKit/webkit/blob/master/Source/JavaScriptCore/API/JSWrapperMap.mm#L412

	var title: String? { get }
	var url: String { get set }
	var transparent: Bool { get set }
	var userAgent: String { get set }
	func close()
	func evalJS(js: String, _ withCallback: JSValue?)
	func asyncEvalJS(js: String, _ withDelay: Double, _ withCallback: JSValue?)
	func loadURL(urlstr: String) -> Bool
	func loadIcon(icon: String) -> Bool
	func preinject(script: String) -> Bool
	func postinject(script: String) -> Bool
	func addHandler(handler: String) // FIXME kill
	func subscribeTo(handler: String)
}

@objc class MPWebView: WKWebView, WebViewScriptExports {

	var jsdelegate: JSValue = JSRuntime.jsdelegate // point to the singleton, for now

	var url: String { // accessor for JSC, which doesn't support `new URL()`
		get { return URL?.absoluteString ?? "" }
		set { loadURL(newValue) }
	}

	var userAgent: String {
		get { return _customUserAgent ?? _userAgent ?? "" }
		// https://github.com/WebKit/webkit/blob/master/Source/WebCore/page/mac/UserAgentMac.mm#L48
		set(agent) { if !agent.isEmpty { _customUserAgent = agent } }
	}

#if os(OSX)
	var transparent: Bool {
		get { return _drawsTransparentBackground }
		set(transparent) {
			_drawsTransparentBackground = transparent
			//^ background-color:transparent sites immediately bleedthru to a black CALayer, which won't go clear until the content is reflowed or reloaded
 			// so frobble frame size to make content reflow & re-colorize
			setFrameSize(NSSize(width: frame.size.width, height: frame.size.height - 1)) //needed to fully redraw w/ dom-reflow or reload!
			evalJS("window.dispatchEvent(new window.CustomEvent('MacPinWebViewChanged',{'detail':{'transparent': \(transparent)}}));" +
				"document.head.appendChild(document.createElement('style')).remove();") //force redraw in case event didn't
				//"window.scrollTo();")
			setFrameSize(NSSize(width: frame.size.width, height: frame.size.height + 1))
			needsDisplay = true
		}
	}
#elseif os(iOS)
	// no overlaying MacPin apps upon other apps in iOS, so make it a no-op
	var transparent = false
#endif

	let favicon: FavIcon = FavIcon()

	convenience init(config: WKWebViewConfiguration? = nil, agent: String? = nil) {
		// init webview with custom config, needed for JS:window.open() which links new child Windows to parent Window
		let configuration = config ?? WKWebViewConfiguration()
		let prefs = WKPreferences() // http://trac.webkit.org/browser/trunk/Source/WebKit2/UIProcess/API/Cocoa/WKPreferences.mm
#if os(OSX)
		prefs.plugInsEnabled = true // NPAPI for Flash, Java, Hangouts
		prefs._developerExtrasEnabled = true // Enable "Inspect Element" in context menu
#endif
		//prefs._isStandalone = true // window.navigator.standalone = true to mimic MobileSafari's springboard-link shell mode
		//prefs.minimumFontSize = 14 //for blindies
		prefs.javaScriptCanOpenWindowsAutomatically = true;
#if WK2LOG
		//prefs._diagnosticLoggingEnabled = true // not in 10.10.3 yet
#endif
		configuration.preferences = prefs
		configuration.suppressesIncrementalRendering = false
		//configuration._websiteDataStore = _WKWebsiteDataStore.nonPersistentDataStore
		self.init(frame: CGRectZero, configuration: configuration)
#if SAFARIDBG
		_allowsRemoteInspection = true // start webinspectord child
		// enables Safari.app->Develop-><computer name> remote debugging of JSCore and all webviews' JS threads
		// http://stackoverflow.com/questions/11361822/debug-ios-67-mobile-safari-using-the-chrome-devtools
#endif
		//_editable = true // https://github.com/WebKit/webkit/tree/master/Tools/WebEditingTester

		allowsBackForwardNavigationGestures = true
#if os(OSX)
		allowsMagnification = true
		_applicationNameForUserAgent = "Version/8.0.5 Safari/600.5.17"
#elseif os(iOS)
		_applicationNameForUserAgent = "Version/8.0 Mobile/12F70 Safari/600.1.4"
#endif
		if let agent = agent { if !agent.isEmpty { _customUserAgent = agent } }
	}

	convenience required init?(object: [String:AnyObject]) {
		self.init(config: nil)
		var url = NSURL(string: "about:blank")
		for (key, value) in object {
			switch value {
				case let urlstr as String where key == "url": url = NSURL(string: urlstr)
				case let agent as String where key == "agent": _customUserAgent = agent
				case let icon as String where key == "icon": loadIcon(icon)
				case let transparent as Bool where key == "transparent":
#if os(OSX)
					_drawsTransparentBackground = transparent
#endif
				case let value as [String] where key == "preinject": for script in value { preinject(script) }
				case let value as [String] where key == "postinject": for script in value { postinject(script) }
				case let value as [String] where key == "handlers": for handler in value { addHandler(handler) } //FIXME kill
				case let value as [String] where key == "subscribeTo": for handler in value { subscribeTo(handler) }
				default: warn("unhandled param: `\(key): \(value)`")
			}
		}

		for script in GlobalUserScripts { if let script = script as? String { warn(script); postinject(script) } }
		if let url = url { gotoURL(url) } else { return nil }
	}

	convenience required init(url: NSURL, agent: String? = nil) {
		self.init(config: nil, agent: agent)
		gotoURL(url)
	}

	override var description: String { return "\(reflect(self).summary) `\(title ?? String())` [\(URL ?? String())]" }
	deinit { warn(description) }

	func evalJS(js: String, _ withCallback: JSValue? = nil) {
		if let withCallback = withCallback where withCallback.isObject() { //is a function or a {}
			warn("withCallback: \(withCallback)")
			evaluateJavaScript(js, completionHandler:{ (result: AnyObject!, exception: NSError!) -> Void in
				// (result: WebKit::WebSerializedScriptValue*, exception: WebKit::CallbackBase::Error)
				//withCallback.callWithArguments([result, exception]) // crashes, need to translate exception into something javascripty
				warn("withCallback() ~> \(result),\(exception)")
				if result != nil {
					withCallback.callWithArguments([result, true]) // unowning withCallback causes a crash and weaking it muffs the call
				} else {
					// passing nil crashes
					withCallback.callWithArguments([JSValue(nullInContext: JSRuntime.context), true])
				}
				return
			})
			return
		}
		evaluateJavaScript(js, completionHandler: nil)
	}

	func asyncEvalJS(js: String, _ withDelay: Double, _ withCallback: JSValue? = nil) {
		let backgroundQueue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
		let delayTime = dispatch_time(DISPATCH_TIME_NOW, Int64(Double(NSEC_PER_SEC) * withDelay))
		dispatch_after(delayTime, backgroundQueue) {
			if let withCallback = withCallback where withCallback.isObject() { //is a function or a {}
				warn("withCallback: \(withCallback)")
				self.evaluateJavaScript(js, completionHandler:{ (result: AnyObject!, exception: NSError!) -> Void in
					// (result: WebKit::WebSerializedScriptValue*, exception: WebKit::CallbackBase::Error)
					//withCallback.callWithArguments([result, exception]) // crashes, need to translate exception into something javascripty
					warn("withCallback() ~> \(result),\(exception)")
					if result != nil {
						withCallback.callWithArguments([result, true]) // unowning withCallback causes a crash and weaking it muffs the call
					} else {
						// passing nil crashes
						withCallback.callWithArguments([JSValue(nullInContext: JSRuntime.context), true])
					}
				})
			} else {
				self.evaluateJavaScript(js, completionHandler: nil)
			}
		}
	}


	func close() { removeFromSuperview() } // signal VC too?

	func gotoURL(url: NSURL) {
		if url.scheme == "file" {
			//webview.loadFileURL(url, allowingReadAccessToURL: url.URLByDeletingLastPathComponent!) //load file and allow link access to its parent dir
			//		waiting on http://trac.webkit.org/changeset/174029/trunk to land
			//webview._addOriginAccessWhitelistEntry(WithSourceOrigin:destinationProtocol:destinationHost:allowDestinationSubdomains:)
			// need to allow loads from file:// to inject NSBundle's CSS
		}
		loadRequest(NSURLRequest(URL: url))
	}

	func loadURL(urlstr: String) -> Bool { // overloading gotoURL is crashing Cocoa selectors
		if let url = NSURL(string: urlstr) {
			gotoURL(url as NSURL)
			return true
		}
		return false // tell JS we were given a malformed URL
	}

	func scrapeIcon() { // extract icon location from current webpage and initiate retrieval
		evaluateJavaScript("if (icon = document.head.querySelector('link[rel$=icon]')) { icon.href };", completionHandler:{ [unowned self] (result: AnyObject!, exception: NSError!) -> Void in
			if let href = result as? String { // got link for icon or apple-touch-icon from DOM
				self.loadIcon(href)
			} else if let url = self.URL, iconurlp = NSURLComponents(URL: url, resolvingAgainstBaseURL: false) where !((iconurlp.host ?? "").isEmpty) {
				iconurlp.path = "/favicon.ico" // request a root-of-domain favicon
				self.loadIcon(iconurlp.string!)
			}
		})
	}

	func loadIcon(icon: String) -> Bool {
		if let url = NSURL(string: icon) where !icon.isEmpty {
			favicon.url = url
			return true
		}
		return false
	}

	func preinject(script: String) -> Bool { return loadUserScriptFromBundle(script, configuration.userContentController, .AtDocumentStart, onlyForTop: false) }
	func postinject(script: String) -> Bool { return loadUserScriptFromBundle(script, configuration.userContentController, .AtDocumentEnd, onlyForTop: false) }
	func addHandler(handler: String) { configuration.userContentController.addScriptMessageHandler(JSRuntime, name: handler) }
	func subscribeTo(handler: String) { configuration.userContentController.addScriptMessageHandler(JSRuntime, name: handler) }

	func loadSeeDebugger() { if postinject("seeDebugger") { reload() } }
	func runSeeDebugger() {
		// http://davidbau.com/archives/2013/04/19/debugging_locals_with_seejs.html
		evalJS("see.init();")

		// https://github.com/davidbau/see/blob/master/see-bookmarklet.js
		/*
		if let seeJSpath = NSBundle.mainBundle().URLForResource("seeDebugger", withExtension: "js") {
			// gotta run it from the bundle because CORS
			var seeJS = "(function() { loadscript( '\(seeJSpath)', function() { see.init(); }); function loadscript(src, callback) { function setonload(script, fn) { script.onload = script.onreadystatechange = fn; } var script = document.createElement('script'), head = document.getElementsByTagName('head')[0], pending = 1; setonload(script, function() { pending && (!script.readyState || {loaded:1,complete:1}[script.readyState]) && (pending = 0, callback(), setonload(script, null), head.removeChild(script)); }); script.src = src; head.appendChild(script); } })();"
			evalJS(seeJS) // still doesn't allow loading local resources
		}
		// download to temp?
		// else complain?
		*/
	}


	func REPL() {
		termiosREPL({ (line: String) -> Void in
			self.evaluateJavaScript(line, completionHandler:{ [unowned self] (result: AnyObject!, exception: NSError!) -> Void in
				println(result)
				println(exception)
			})
		})
	}
}
