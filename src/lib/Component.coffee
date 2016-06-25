#     NoFlo - Flow-Based Programming for JavaScript
#     (c) 2013-2016 TheGrid (Rituwall Inc.)
#     (c) 2011-2012 Henri Bergius, Nemein
#     NoFlo may be freely distributed under the MIT license
#
# Baseclass for regular NoFlo components.
{EventEmitter} = require 'events'

ports = require './Ports'
IP = require './IP'

class Component extends EventEmitter
  description: ''
  icon: null

  constructor: (options) ->
    options = {} unless options
    options.inPorts = {} unless options.inPorts
    if options.inPorts instanceof ports.InPorts
      @inPorts = options.inPorts
    else
      @inPorts = new ports.InPorts options.inPorts

    options.outPorts = {} unless options.outPorts
    if options.outPorts instanceof ports.OutPorts
      @outPorts = options.outPorts
    else
      @outPorts = new ports.OutPorts options.outPorts

    @icon = options.icon if options.icon
    @description = options.description if options.description

    @started = false
    @load = 0
    @ordered = options.ordered ? false
    @autoOrdering = options.autoOrdering ? null
    @outputQ = []
    @activateOnInput = options.activateOnInput ? true
    @forwardBracketsFrom = ['in']
    @forwardBracketsTo = ['out', 'error']
    @bracketCounter = {}
    @bracketBuffer = {}
    @fwdBracketCounter = {}

    if 'forwardBracketsFrom' of options
      @forwardBracketsFrom = options.forwardBracketsFrom
    if 'forwardBracketsTo' of options
      @forwardBracketsTo = options.forwardBracketsTo

    if typeof options.process is 'function'
      @process options.process

  getDescription: -> @description

  isReady: -> true

  isSubgraph: -> false

  setIcon: (@icon) ->
    @emit 'icon', @icon
  getIcon: -> @icon

  error: (e, groups = [], errorPort = 'error', scope = null) =>
    if @outPorts[errorPort] and (@outPorts[errorPort].isAttached() or not @outPorts[errorPort].isRequired())
      @outPorts[errorPort].openBracket group, scope: scope for group in groups
      @outPorts[errorPort].data e, scope: scope
      @outPorts[errorPort].closeBracket group, scope: scope for group in groups
      # @outPorts[errorPort].disconnect()
      return
    throw e

  shutdown: ->
    @started = false

  # The startup function performs initialization for the component.
  start: ->
    @started = true
    @started

  isStarted: -> @started

  # Ensures bracket forwarding map is correct for the existing ports
  prepareForwarding: ->
    @forwardBracketsFrom = (p for p in @forwardBracketsFrom when p of @inPorts.ports)
    for inPort in @forwardBracketsFrom
      @bracketCounter[inPort] = 0
    @forwardBracketsTo = (p for p in @forwardBracketsTo when p of @outPorts.ports)

  incFwdCounter: (scope, port) ->
    @fwdBracketCounter[scope] = {} unless scope of @fwdBracketCounter
    @fwdBracketCounter[scope][port] = 0 unless port of @fwdBracketCounter[scope]
    @fwdBracketCounter[scope][port]++

  decFwdCounter: (scope, port) ->
    return unless @fwdBracketCounter[scope]?[port]
    @fwdBracketCounter[scope][port]--
    delete @fwdBracketCounter[scope][port] if @fwdBracketCounter[scope][port] is 0
    delete @fwdBracketCounter[scope] if Object.keys(@fwdBracketCounter[scope]).length is 0

  getFwdCounter: (scope, port) ->
    return 0 unless @fwdBracketCounter[scope]?[port]
    return @fwdBracketCounter[scope][port]

  # Sets process handler function
  process: (handle) ->
    unless typeof handle is 'function'
      throw new Error "Process handler must be a function"
    unless @inPorts
      throw new Error "Component ports must be defined before process function"
    @prepareForwarding()
    @handle = handle
    for name, port of @inPorts.ports
      do (name, port) =>
        port.name = name unless port.name
        port.on 'ip', (ip) =>
          @handleIP ip, port
    @

  # Handles an incoming IP object
  handleIP: (ip, port) ->
    if ip.type is 'openBracket'
      @autoOrdering = true if @autoOrdering is null
      @bracketCounter[port.name]++
    if @forwardBracketsFrom.indexOf(port.name) isnt -1 and
    (ip.type is 'openBracket' or ip.type is 'closeBracket')
      # Bracket forwarding
      @bracketBuffer[ip.scope] = [] unless ip.scope of @bracketBuffer
      # Closing brackets coming afterwards are just forwarded
      if ip.type is 'closeBracket' and @bracketBuffer[ip.scope].length is 0
        outputEntry =
          __resolved: true
        for outPort, count of @fwdBracketCounter[ip.scope]
          if count > 0
            outputEntry[outPort] = [] unless outPort of outputEntry
            outputEntry[outPort].push ip
            @decFwdCounter ip.scope, outPort
        if Object.keys(outputEntry).length > 1
          @outputQ.push outputEntry
          @processOutputQueue()
      else
        @bracketBuffer[ip.scope].push ip
      if ip.scope?
        port.scopedBuffer[ip.scope].pop()
      else
        port.buffer.pop()
      return
    return unless port.options.triggering
    result = {}
    input = new ProcessInput @inPorts, ip, @, port, result
    output = new ProcessOutput @outPorts, ip, @, result
    @load++
    @handle input, output, -> output.done()

  processOutputQueue: ->
    while @outputQ.length > 0
      result = @outputQ[0]
      break unless result.__resolved
      for port, ips of result
        continue if port.indexOf('__') is 0
        continue unless @outPorts.ports[port].isAttached()
        for ip in ips
          @bracketCounter[port]-- if ip.type is 'closeBracket'
          @outPorts[port].sendIP ip
      @outputQ.shift()
    bracketsClosed = true
    for name, port of @outPorts.ports
      if @bracketCounter[port] isnt 0
        bracketsClosed = false
        break
    @autoOrdering = null if bracketsClosed and @autoOrdering is true

exports.Component = Component

class ProcessInput
  constructor: (@ports, @ip, @nodeInstance, @port, @result) ->
    @scope = @ip.scope
    @buffer = new PortBuffer(@)

  # Sets component state to `activated`
  activate: ->
    @result.__resolved = false
    if @nodeInstance.ordered or @nodeInstance.autoOrdering
      @nodeInstance.outputQ.push @result

  # Returns true if a port (or ports joined by logical AND) has a new IP
  # Passing a validation callback as a last argument allows more selective
  # checking of packets.
  has: (args...) ->
    args = ['in'] unless args.length
    if typeof args[args.length - 1] is 'function'
      validate = args.pop()
      for port in args
        return false unless @ports[port].has @scope, validate
      return true
    res = true
    res and= @ports[port].ready @scope for port in args
    res

  # Fetches IP object(s) for port(s)
  get: (args...) ->
    args = ['in'] unless args.length
    if (@nodeInstance.ordered or @nodeInstance.autoOrdering) and
    @nodeInstance.activateOnInput and
    not ('__resolved' of @result)
      @activate()
    res = (@ports[port].get @scope for port in args)
    if args.length is 1 then res[0] else res

  # Fetches `data` property of IP object(s) for given port(s)
  getData: (args...) ->
    args = ['in'] unless args.length
    ips = @get.apply this, args
    if args.length is 1
      return ips?.data ? undefined
    (ip?.data ? undefined for ip in ips)

  hasStream: (port) ->
    buffer = @buffer.get port
    return false if buffer.length is 0
    # check if we have everything until "disconnect"
    received = 0
    for packet in buffer
      if packet.type is 'openBracket'
        ++received
      else if packet.type is 'closeBracket'
        --received
    received is 0

  getStream: (port, withoutConnectAndDisconnect = false) ->
    buf = @buffer.get port
    @buffer.filter port, (ip) -> false
    if withoutConnectAndDisconnect
      buf = buf.slice 1
      buf.pop()
    buf

class PortBuffer
  constructor: (@context) ->

  set: (name, buffer) ->
    if name? and typeof name isnt 'string'
      buffer = name
      name = null

    if @context.scope?
      if name?
        @context.ports[name].scopedBuffer[@context.scope] = buffer
        return @context.ports[name].scopedBuffer[@context.scope]
      @context.port.scopedBuffer[@context.scope] = buffer
      return @context.port.scopedBuffer[@context.scope]

    if name?
      @context.ports[name].buffer = buffer
      return @context.ports[name].buffer

    @context.port.buffer = buffer
    return @context.port.buffer

  # Get a buffer (scoped or not) for a given port
  # if name is optional, use the current port
  get: (name = null) ->
    if @context.scope?
      if name?
        return @context.ports[name].scopedBuffer[@context.scope]
      return @context.port.scopedBuffer[@context.scope]

    if name?
      return @context.ports[name].buffer
    return @context.port.buffer

  # Find packets matching a callback and return them without modifying the buffer
  find: (name, cb) ->
    b = @get name
    b.filter cb

  # Find packets and modify the original buffer
  # cb is a function with 2 arguments (ip, index)
  filter: (name, cb) ->
    if name? and typeof name isnt 'string'
      cb = name
      name = null

    b = @get name
    b = b.filter cb

    @set name, b

class ProcessOutput
  constructor: (@ports, @ip, @nodeInstance, @result) ->
    @scope = @ip.scope
    @bracketsToForward = null
    @forwardedBracketsTo = []

  # Sets component state to `activated`
  activate: ->
    @result.__resolved = false
    if @nodeInstance.ordered or @nodeInstance.autoOrdering
      @nodeInstance.outputQ.push @result

  # Checks if a value is an Error
  isError: (err) ->
    err instanceof Error or
    Array.isArray(err) and err.length > 0 and err[0] instanceof Error

  # Sends an error object
  error: (err) ->
    multiple = Array.isArray err
    err = [err] unless multiple
    if 'error' of @ports and
    (@ports.error.isAttached() or not @ports.error.isRequired())
      @send error: new IP 'openBracket' if multiple
      @send error: e for e in err
      @send error: new IP 'closeBracket' if multiple
    else
      throw e for e in err

  # Sends a single IP object to a port
  sendIP: (port, packet) ->
    if typeof packet isnt 'object' or IP.types.indexOf(packet.type) is -1
      ip = new IP 'data', packet
    else
      ip = packet
    ip.scope = @scope if @scope isnt null and ip.scope is null
    if @nodeInstance.ordered or @nodeInstance.autoOrdering
      @result[port] = [] unless port of @result
      @result[port].push ip
    else
      @nodeInstance.outPorts[port].sendIP ip

  prepareOpenBrackets: ->
    @bracketsToForward = []
    hasOpening = false
    while @nodeInstance.bracketBuffer[@scope]?.length > 0
      ip = @nodeInstance.bracketBuffer[@scope][0]
      if ip.type is 'openBracket'
        @bracketsToForward.push @nodeInstance.bracketBuffer[@scope].shift()
        hasOpening = true
      else
        break if hasOpening
        # Closing brackets from previous execution need to be forwarded
        @bracketsToForward.push @nodeInstance.bracketBuffer[@scope].shift()

  prepareCloseBrackets: ->
    @bracketsToForward = []
    while @nodeInstance.bracketBuffer[@scope]?.length > 0
      ip = @nodeInstance.bracketBuffer[@scope][0]
      if ip.type is 'closeBracket'
        @bracketsToForward.push @nodeInstance.bracketBuffer[@scope].shift()
      else
        break

  # Sends packets for each port as a key in the map
  # or sends Error or a list of Errors if passed such
  send: (outputMap) ->
    # Prepare brackets to be forwareded
    @prepareOpenBrackets() unless @bracketsToForward
    if (@nodeInstance.ordered or @nodeInstance.autoOrdering) and
    not ('__resolved' of @result)
      @activate()
    return @error outputMap if @isError outputMap

    componentPorts = []
    mapIsInPorts = false
    for port in Object.keys @ports.ports
      componentPorts.push port if port isnt 'error' and port isnt 'ports' and port isnt '_callbacks'
      if not mapIsInPorts and typeof outputMap is 'object' and Object.keys(outputMap).indexOf(port) isnt -1
        mapIsInPorts = true

    if componentPorts.length is 1 and not mapIsInPorts
      ip = outputMap
      outputMap = {}
      outputMap[componentPorts[0]] = ip

    for port, packet of outputMap
      if @nodeInstance.forwardBracketsTo.indexOf(port) isnt -1 and @forwardedBracketsTo.indexOf(port) is -1
        # Forward openening brackets before sending data
        for ip in @bracketsToForward
          @sendIP port, ip
          if ip.type is 'openBracket'
            @nodeInstance.incFwdCounter ip.scope, port
          else
            @nodeInstance.decFwdCounter ip.scope, port
        @forwardedBracketsTo.push port
      # Then send current output
      @sendIP port, packet

  # Sends the argument via `send()` and marks activation as `done()`
  sendDone: (outputMap) ->
    @send outputMap
    @done()

  # Makes a map-style component pass a result value to `out`
  # keeping all IP metadata received from `in`,
  # or modifying it if `options` is provided
  pass: (data, options = {}) ->
    unless 'out' of @ports
      throw new Error 'output.pass() requires port "out" to be present'
    for key, val of options
      @ip[key] = val
    @ip.data = data
    @sendDone out: @ip

  # Finishes process activation gracefully
  done: (error) ->
    @error error if error
    # TODO return @bracketsToForward back to buffer if nothing was sent?
    # This makes buffer grow and results into empty brackets
    # if @forwardedBracketsTo.length is 0 and @bracketsToForward.length
    #   @nodeInstance.bracketBuffer[@scope] = @bracketsToForward.concat @nodeInstance.bracketBuffer[@scope]
    @prepareCloseBrackets()
    # Forward closing brackets to any ports that we have sent to
    if @bracketsToForward.length > 0
      for port in @forwardedBracketsTo
        for ip in @bracketsToForward
          @sendIP port, ip
          if ip.type is 'openBracket'
            @nodeInstance.incFwdCounter ip.scope, port
          else
            @nodeInstance.decFwdCounter ip.scope, port
      @forwardedBracketsTo = []
    @bracketsToForward = null

    # Flush the queue
    if @nodeInstance.ordered or @nodeInstance.autoOrdering
      @result.__resolved = true
      @nodeInstance.processOutputQueue()
    @nodeInstance.load--
