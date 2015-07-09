#     NoFlo - Flow-Based Programming for JavaScript
#     (c) 2013-2014 TheGrid (Rituwall Inc.)
#     (c) 2011-2012 Henri Bergius, Nemein
#     NoFlo may be freely distributed under the MIT license
#
# Baseclass for regular NoFlo components.
{EventEmitter} = require 'events'

ports = require './Ports'

class Component extends EventEmitter
  description: ''
  icon: null
  started: false

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

  getDescription: -> @description

  isReady: -> true

  isSubgraph: -> false

  setIcon: (@icon) ->
    @emit 'icon', @icon
  getIcon: -> @icon

  error: (e, groups = [], errorPort = 'error') =>
    if @outPorts[errorPort] and (@outPorts[errorPort].isAttached() or not @outPorts[errorPort].isRequired())
      @outPorts[errorPort].beginGroup group for group in groups
      @outPorts[errorPort].send e
      @outPorts[errorPort].endGroup() for group in groups
      @outPorts[errorPort].disconnect()
      return
    throw e

  shutdown: ->
    @started = false

  # The startup function performs initialization for the component.
  start: ->
    @started = true
    @started

  isStarted: -> @started

  # Component process definition sets up built-in listeners, synchronization
  # and binds the process function
  process: (proc) ->
    # Ensure some defaults
    # Forward group events from specific inputs to the output:
    # - false: don't forward anything
    # - true: forward unique groups of all inputs
    # - string: forward groups of a specific port only
    # - array: forward unique groups of inports in the list
    @forwardGroups = true unless 'forwardGroups' of @
    # Match incoming data by groups
    @matchByGroups = false unless 'matchByGroups' of @
    # Match incoming data by object field
    @matchByField = false unless 'matchByField' of @
    # Maintain order consistency between input and output
    @ordered = true unless 'ordered' of @
    # Drop premature input before all params are received
    @dropPrematureInput = false unless 'dropPrematureInput' of @
    # Firing policy for addressable ports
    unless 'arrayPolicy' of @
      @arrayPolicy =
        input: 'any'
        control: 'all'

    @_gcTimeout = 300 # TODO remove this
    @_gcFrequency = 100 # TODO remove this

    # Detect input, output, control ports
    @_inputs = {}
    @_controls = {}
    @_outputs = {}
    for name, port of @inPorts
      if port.options.input and port.options.control
        throw new Error "A port cannot be input and control at the same time"
      else if port.options.input
        @_inputs[name] = port
      else if port.options.control
        @_controls[name] = port

    # Set up the queues
    @_resetBuffers()

    # Bind controls handlers
    for name, port of @_controls
      @_requiredControls.push name if port.isRequired()
      @_defaultedControls.push name if port.hasDefault()
    for name, port of @_controls
      @_bindControl name, port

    # Set up group forwarding
    @_collectGroups = @forwardGroups
    # Collect groups from each port?
    if typeof @_collectGroups is 'boolean' and not @matchByGroups
      @_collectGroups = inPorts
    # Collect groups from one and only port?
    if typeof @_collectGroups is 'string' and not @matchByGroups
      @_collectGroups = [@_collectGroups]
    # Collect groups from any port, as we group by them
    if @_collectGroups isnt false and @matchByGroups
      @_collectGroups = true

    # Bind input handlers
    for name, port of @_inputs
      @_bindInput name, port

  # Reset state and stop sending output
  shutdown: ->
    # TODO kill in-flight operations
    @_resetBuffers()

  # Initialize or reset buffers
  _resetBuffers: ->
    # Internal state
    @load = 0 if 'load' of @outPorts
    @controls = {}

    # Input buffering
    @_inputQ = []
    @_portBuffers = {}
    @_groupedData = {}
    @_groupedGroups = {}
    @_groupedDisconnects = {}

    # Output buffering
    @_outputQ = []

    # Handler tasks
    @_taskQ = []

    # Control ports handling
    @_requiredControls = []
    @_completeControls = []
    @_receivedControls = []
    @_defaultedControls = []
    @_defaultsSent = false

    # Disconnect event forwarding
    @_disconnectData = {}
    @_disconnectQ = []

    @_groupBuffers = {}
    @_keyBuffers = {}
    @_gcTimestamps = {}
    @_gcCounter = 0


  # Manual disconnect forwarding
  _disconnectOuts: ->
    for name, p of @_outputs
      p.disconnect() if p.isConnected()

  # Groups open forwarding
  _sendGroupToOuts: (grp) ->
    for name, p of @_outputs
      p.beginGroup grp

  # Groups close forwarding
  _closeGroupOnOuts: ->
    for name, p of @_outputs
      p.endGroup()

  # Hook called before calling user process
  _beforeProcess: (outs) ->
      @_outputQ.push outs if @_ordered
      @load++
      if 'load' of @outPorts and @outPorts.load.isAttached()
        @outPorts.load.send component.load
        @outPorts.load.disconnect()

  # Hook called after calling user process
  _afterProcess: ->
      @_resumeOutputQueue()
      @load--
      if 'load' of @outPorts and @outPorts.load.isAttached()
        @outPorts.load.send @load
        @outPorts.load.disconnect()

  # Trigger defaults on controls which haven't received any data
  _sendDefaults: ->
    if @_defaultedControls.length > 0
      for param in @_defaultedControls
        if @_receivedControls.indexOf(param) is -1
          tempSocket = InternalSocket.createSocket()
          @inPorts[param].attach tempSocket
          tempSocket.send()
          tempSocket.disconnect()
          @inPorts[param].detach tempSocket
    @_defaultsSent = true

  # Composes and binds control port reaction
  _bindControl: (name, port) ->
    port.process = (event, payload, index) =>
      # Param ports only react on data
      return unless event is 'data'
      if port.isAddressable()
        @controls[name] = {} unless name of @controls
        @controls[name][index] = payload
        if @arrayPolicy.controls is 'all' and Object.keys(@controls[name]).length < port.listAttached().length
          return # Need data on all array indexes to proceed
      else
        @controls[name] = payload
      if @_completeControls.indexOf(name) is -1 and @_requiredControls.indexOf(name) isnt -1
        # A required control is now complete
        @_completeControls.push name
      # Mark control as received so it doens't need default value
      @_receivedControls.push name if @_receivedControls.indexOf(name) is -1
      # Trigger pending tasks if all params are complete
      @_resumeTaskQueue()

  # Composes and binds input port reaction
  _bindInput: (name, port) ->
    port.process = (event, payload, index) =>
      @_groupBuffers[port] = [] unless port of @_groupBuffers


  # Resume pending processing tasks
  _resumeTaskQueue: ->
    if @_completeControls.length is @_requiredControls.length and @_taskQ.length > 0
      # Avoid looping when feeding the queue inside the queue itself
      temp = @_taskQ.slice 0
      @_taskQ = []
      while temp.length > 0
        task = temp.shift()
        task()

  # Resumes ordered output
  _resumeOutputQueue: ->
    while @_outputQ.length > 0
      streams = @_outputQ[0]
      flushed = false
      # Null in the queue means "disconnect all"
      if streams is null
        @_disconnectOuts()
        flushed = true
      else
        # At least one of the outputs has to be resolved
        # for output streams to be flushed.
        if @_outputs.length is 1
          # FIXME: generalize and remove this case
          tmp = {}
          tmp[Object.keys(@_outputs)[0]] = streams
          streams = tmp
        for key, stream of streams
          if stream.resolved
            stream.flush()
            flushed = true
      @_outputQ.shift() if flushed
      return unless flushed

  # TODO: replace it with queue length limits
  # Garbage collector
  _dropRequest: (key) ->
    # Discard pending disconnect keys
    delete @_disconnectData[key] if key of @_disconnectData
    # Clean grouped data
    delete @_groupedData[key] if key of @_groupedData
    delete @_groupedGroups[key] if key of @_groupedGroups

  _cleanupQueues = ->
    @_gcCounter++
    if @_gcCounter % @_gcFrequency is 0
      current = new Date().getTime()
      for key, val of @_gcTimestamps
        if (current - val) > (@_gcTimeout * 1000)
          @_dropRequest key
          delete @_gcTimestamps[key]

exports.Component = Component
