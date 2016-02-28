class Poltergeist.WebPage
  @CALLBACKS = ['onConsoleMessage','onError',
                'onLoadFinished', 'onInitialized', 'onLoadStarted',
                'onResourceRequested', 'onResourceReceived', 'onResourceError',
                'onNavigationRequested', 'onUrlChanged', 'onPageCreated',
                'onClosing']

  @DELEGATES = ['open', 'sendEvent', 'uploadFile', 'release', 'render',
                'renderBase64', 'goBack', 'goForward']

  @COMMANDS  = ['currentUrl', 'find', 'nodeCall', 'documentSize',
                'beforeUpload', 'afterUpload', 'clearLocalStorage']

  @EXTENSIONS = []

  constructor: (@_native) ->
    @_native or= require('webpage').create()

    @id              = 0
    @source          = null
    @closed          = false
    @state           = 'default'
    @urlWhitelist    = []
    @urlBlacklist    = []
    @errors          = []
    @_networkTraffic = {}
    @_tempHeaders    = {}
    @_blockedUrls    = []
    @_requestedResources = {}
    @_responseHeaders = []

    for callback in WebPage.CALLBACKS
      @bindCallback(callback)

    if phantom.version.major < 2
      @._overrideNativeEvaluate()

  for command in @COMMANDS
    do (command) =>
      @prototype[command] =
        (args...) -> @runCommand(command, args)

  for delegate in @DELEGATES
    do (delegate) =>
      @prototype[delegate] =
        -> @_native[delegate].apply(@_native, arguments)

  onInitializedNative: ->
    @id += 1
    @source = null
    @injectAgent()
    @removeTempHeaders()
    @setScrollPosition(left: 0, top: 0)

  onClosingNative: ->
    @handle = null
    @closed = true

  onConsoleMessageNative: (message) ->
    if message == '__DOMContentLoaded'
      @source = @_native.content
      false
    else
      console.log(message)

  onLoadStartedNative: ->
    @state = 'loading'
    @requestId = @lastRequestId
    @_requestedResources = {}

  onLoadFinishedNative: (@status) ->
    @state = 'default'
    @source or= @_native.content

  onErrorNative: (message, stack) ->
    stackString = message

    stack.forEach (frame) ->
      stackString += "\n"
      stackString += "    at #{frame.file}:#{frame.line}"
      stackString += " in #{frame.function}" if frame.function && frame.function != ''

    @errors.push(message: message, stack: stackString)
    return true

  onResourceRequestedNative: (request, net) ->
    useWhitelist = @urlWhitelist.length > 0

    whitelisted = @urlWhitelist.some (whitelisted_regex) ->
      whitelisted_regex.test request.url

    blacklisted = @urlBlacklist.some (blacklisted_regex) ->
      blacklisted_regex.test request.url

    abort = false

    if useWhitelist && !whitelisted
      abort = true

    if blacklisted
      abort = true

    if abort
      @_blockedUrls.push request.url unless request.url in @_blockedUrls
      net.abort()
    else
      @lastRequestId = request.id

      if @normalizeURL(request.url) == @redirectURL
        @redirectURL = null
        @requestId   = request.id

      @_networkTraffic[request.id] = {
        request:       request,
        responseParts: []
        error: null
      }

      @_requestedResources[request.id] = request.url
    return true

  onResourceReceivedNative: (response) ->
    @_networkTraffic[response.id]?.responseParts.push(response)

    if response.stage == 'end'
      delete @_requestedResources[response.id]

    if @requestId == response.id
      if response.redirectURL
        @redirectURL = @normalizeURL(response.redirectURL)
      else
        @statusCode = response.status
        @_responseHeaders = response.headers
    return true

  onResourceErrorNative: (errorResponse) ->
    @_networkTraffic[errorResponse.id]?.error = errorResponse
    delete @_requestedResources[errorResponse.id]
    return true

  injectAgent: ->
    if @native().evaluate(-> typeof __poltergeist) == "undefined"
      @native().injectJs "#{phantom.libraryPath}/agent.js"
      @native().injectJs extension for extension in WebPage.EXTENSIONS
      return true
    return false

  injectExtension: (file) ->
    WebPage.EXTENSIONS.push file
    @native().injectJs file

  native: ->
    if @closed
      throw new Poltergeist.NoSuchWindowError
    else
      @_native

  windowName: ->
    @native().windowName

  keyCode: (name) ->
    name = "Control" if name == "Ctrl"
    this.native().event.key[name]

  keyModifierCode: (names) ->
    modifiers = this.native().event.modifier
    names.split(',').map((name) -> modifiers[name]).reduce((n1,n2) -> n1 | n2)

  keyModifierKeys: (names) ->
    for name in names.split(',') when name isnt 'keypad'
      this.keyCode(name.charAt(0).toUpperCase() + name.substring(1))

  _waitState_until: (state, callback, timeout, timeout_callback) ->
    if (@state == state)
      callback.call(this)
    else
      if new Date().getTime() > timeout
        timeout_callback.call(this)
      else
        setTimeout (=> @_waitState_until(state, callback, timeout, timeout_callback)), 100

  waitState: (state, callback, max_wait=0, timeout_callback) ->
    # callback and timeout_callback will be called with this == the current page
    if @state == state
      callback.call(this)
    else
      if max_wait != 0
        timeout = new Date().getTime() + (max_wait*1000)
        setTimeout (=> @_waitState_until(state, callback, timeout, timeout_callback)), 100
      else
        setTimeout (=> @waitState(state, callback)), 100

  setHttpAuth: (user, password) ->
    @native().settings.userName = user
    @native().settings.password = password
    return true

  networkTraffic: ->
    @_networkTraffic

  clearNetworkTraffic: ->
    @_networkTraffic = {}
    return true

  blockedUrls: ->
    @_blockedUrls

  clearBlockedUrls: ->
    @_blockedUrls = []
    return true

  openResourceRequests: ->
    url for own id, url of @_requestedResources

  content: ->
    @native().frameContent

  title: ->
    @native().frameTitle

  frameUrl: (frameNameOrId) ->
    query = (frameNameOrId) ->
      document.querySelector("iframe[name='#{frameNameOrId}'], iframe[id='#{frameNameOrId}']")?.src
    @evaluate(query, frameNameOrId)

  clearErrors: ->
    @errors = []
    return true

  responseHeaders: ->
    headers = {}
    @_responseHeaders.forEach (item) ->
      headers[item.name] = item.value
    headers

  cookies: ->
    @native().cookies

  deleteCookie: (name) ->
    @native().deleteCookie(name)

  viewportSize: ->
    @native().viewportSize

  setViewportSize: (size) ->
    @native().viewportSize = size

  setZoomFactor: (zoom_factor) ->
    @native().zoomFactor = zoom_factor

  setPaperSize: (size) ->
    @native().paperSize = size

  scrollPosition: ->
    @native().scrollPosition

  setScrollPosition: (pos) ->
    @native().scrollPosition = pos

  clipRect: ->
    @native().clipRect

  setClipRect: (rect) ->
    @native().clipRect = rect

  elementBounds: (selector) ->
    @native().evaluate(
      (selector) ->
        document.querySelector(selector).getBoundingClientRect()
      , selector
    )

  setUserAgent: (userAgent) ->
    @native().settings.userAgent = userAgent

  getCustomHeaders: ->
    @native().customHeaders

  setCustomHeaders: (headers) ->
    @native().customHeaders = headers

  addTempHeader: (header) ->
    @_tempHeaders[name] = value for name, value of header
    @_tempHeaders

  removeTempHeaders: ->
    allHeaders = @getCustomHeaders()
    delete allHeaders[name] for name, value of @_tempHeaders
    @setCustomHeaders(allHeaders)

  pushFrame: (name) ->
    return true if this.native().switchToFrame(name)

    # if switch by name fails - find index and try again
    frame_no = this.native().evaluate(
      (frame_name) ->
        frames = document.querySelectorAll("iframe, frame")
        (idx for f, idx in frames when f?['name'] == frame_name or f?['id'] == frame_name)[0]
      , name)
    frame_no? and this.native().switchToFrame(frame_no)

  popFrame: (pop_all = false)->
    if pop_all
      this.native().switchToMainFrame()
    else
      this.native().switchToParentFrame()

  dimensions: ->
    scroll   = @scrollPosition()
    viewport = @viewportSize()

    top:    scroll.top,  bottom: scroll.top  + viewport.height,
    left:   scroll.left, right:  scroll.left + viewport.width,
    viewport: viewport
    document: @documentSize()

  # A work around for http://code.google.com/p/phantomjs/issues/detail?id=277
  validatedDimensions: ->
    dimensions = @dimensions()
    document   = dimensions.document

    if dimensions.right > document.width
      dimensions.left  = Math.max(0, dimensions.left - (dimensions.right - document.width))
      dimensions.right = document.width

    if dimensions.bottom > document.height
      dimensions.top    = Math.max(0, dimensions.top - (dimensions.bottom - document.height))
      dimensions.bottom = document.height

    @setScrollPosition(left: dimensions.left, top: dimensions.top)

    dimensions

  get: (id) ->
    new Poltergeist.Node(this, id)

  # Before each mouse event we make sure that the mouse is moved to where the
  # event will take place. This deals with e.g. :hover changes.
  mouseEvent: (name, x, y, button = 'left') ->
    @sendEvent('mousemove', x, y)
    @sendEvent(name, x, y, button)

  evaluate: (fn, args...) ->
    @injectAgent()
    @native().evaluate("function() {
      for(var i=0; i < arguments.length; i++){
        if ((typeof(arguments[i]) == 'object') && (typeof(arguments[i]['ELEMENT']) == 'object')){
          arguments[i] = window.__poltergeist.get(arguments[i]['ELEMENT']['id']).element;
        }
      }
      var _result = #{@stringifyCall(fn)};
      return (_result == null) ? undefined : _result; }", args...)

  execute: (fn, args...) ->
    @injectAgent()
    @native().evaluate("function() {
      for(var i=0; i < arguments.length; i++){
        if ((typeof(arguments[i]) == 'object') && (typeof(arguments[i]['ELEMENT']) == 'object')){
          arguments[i] = window.__poltergeist.get(arguments[i]['ELEMENT']['id']).element;
        }
      }
      #{@stringifyCall(fn)} }", args...)

  stringifyCall: (fn) ->
    "(#{fn.toString()}).apply(this, arguments)"

  bindCallback: (name) ->
    @native()[name] = =>
      result = @[name + 'Native'].apply(@, arguments) if @[name + 'Native']? # For internal callbacks
      @[name].apply(@, arguments) if result != false && @[name]? # For externally set callbacks
    return true

  # Any error raised here or inside the evaluate will get reported to
  # phantom.onError. If result is null, that means there was an error
  # inside the agent.
  runCommand: (name, args) ->
    result = @evaluate(
      (name, args) -> __poltergeist.externalCall(name, args),
      name, args
    )

    if result != null
      if result.error?
        switch result.error.message
          when 'PoltergeistAgent.ObsoleteNode'
            throw new Poltergeist.ObsoleteNode
          when 'PoltergeistAgent.InvalidSelector'
            [method, selector] = args
            throw new Poltergeist.InvalidSelector(method, selector)
          else
            throw new Poltergeist.BrowserError(result.error.message, result.error.stack)
      else
        result.value

  canGoBack: ->
    @native().canGoBack

  canGoForward: ->
    @native().canGoForward

  normalizeURL: (url) ->
    parser = document.createElement('a')
    parser.href = url
    return parser.href

  clearMemoryCache: ->
    clearMemoryCache = this.native().clearMemoryCache
    if typeof clearMemoryCache == "function"
      clearMemoryCache()
    else
      throw new Poltergeist.UnsupportedFeature("clearMemoryCache is supported since PhantomJS 2.0.0")

  _overrideNativeEvaluate: ->
    # PhantomJS 1.9.x WebPage#evaluate depends on the browser context  JSON, this replaces it
    # with the evaluate from 2.1.1 which uses the PhantomJS JSON
    @_native.evaluate = `function (func, args) {
        function quoteString(str) {
            var c, i, l = str.length, o = '"';
            for (i = 0; i < l; i += 1) {
                c = str.charAt(i);
                if (c >= ' ') {
                    if (c === '\\' || c === '"') {
                        o += '\\';
                    }
                    o += c;
                } else {
                    switch (c) {
                    case '\b':
                        o += '\\b';
                        break;
                    case '\f':
                        o += '\\f';
                        break;
                    case '\n':
                        o += '\\n';
                        break;
                    case '\r':
                        o += '\\r';
                        break;
                    case '\t':
                        o += '\\t';
                        break;
                    default:
                        c = c.charCodeAt();
                        o += '\\u00' + Math.floor(c / 16).toString(16) +
                            (c % 16).toString(16);
                    }
                }
            }
            return o + '"';
        }

        function detectType(value) {
            var s = typeof value;
            if (s === 'object') {
                if (value) {
                    if (value instanceof Array) {
                        s = 'array';
                    } else if (value instanceof RegExp) {
                        s = 'regexp';
                    } else if (value instanceof Date) {
                        s = 'date';
                    }
                } else {
                    s = 'null';
                }
            }
            return s;
        }

        var str, arg, argType, i, l;
        if (!(func instanceof Function || typeof func === 'string' || func instanceof String)) {
            throw "Wrong use of WebPage#evaluate";
        }
        str = 'function() { return (' + func.toString() + ')(';
        for (i = 1, l = arguments.length; i < l; i++) {
            arg = arguments[i];
            argType = detectType(arg);

            switch (argType) {
            case "object":      //< for type "object"
            case "array":       //< for type "array"
                str += JSON.stringify(arg) + ","
                break;
            case "date":        //< for type "date"
                str += "new Date(" + JSON.stringify(arg) + "),"
                break;
            case "string":      //< for type "string"
                str += quoteString(arg) + ',';
                break;
            default:            // for types: "null", "number", "function", "regexp", "undefined"
                str += arg + ',';
                break;
            }
        }
        str = str.replace(/,$/, '') + '); }';
        return this.evaluateJavaScript(str);
    };`
