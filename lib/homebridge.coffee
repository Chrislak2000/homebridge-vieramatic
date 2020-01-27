### global Service Characteristic Accessory ###

# homebridge vieramatic plugin

# > required **external dependencies**
UpnpSub = require('node-upnp-subscription')
events = require('events')
_ = require('lodash')

# > required **internal dependencies**
Viera = require('./viera')
Storage = require('./storage')

# helpers
sleep = (ms) ->
  now = new Date().getTime()
  # eslint-disable-next-line no-continue
  continue while new Date().getTime() - now < ms

findVal = (object, key) ->
  value = undefined
  Object.keys(object).some((k) ->
    if k == key
      value = object[k]
      return true
    if object[k] and typeof object[k] == 'object'
      value = findVal(object[k], key)
      return value != undefined
  )
  value

class Vieramatic
  tvEvent = new events.EventEmitter()

  constructor: (log, config, api) ->
    log.info('Vieramatic Init')

    [@log, @api, @previousAccessories] = [log, api, []]

    @config = {
      tvs: config?.tvs || []
    }
    @storage = new Storage(api)

    for cached of @previousAccessories
      @api.unregisterPlatformAccessories('homebridge-vieramatic', 'PanasonicVieraTV', [cached])

    @api.on('didFinishLaunching', @init) if @api

  init: () =>
    await @storage.init()
    for __, viera of @config.tvs
      @log.debug(viera.ipAddress)
      viera.hdmiInputs = [] unless viera.hdmiInputs?
      tv = new Viera(viera.ipAddress, viera.appId, viera.encKey)

      if await tv.isReachable()
        brk = false
        until tv.specs?.serialNumber? or brk
          await tv
          .getSpecs()
          # eslint-disable-next-line coffee/no-loop-func
          .then(() =>
            @log.debug(tv)
            if tv.encrypted and not (tv._appId? and tv._encKey?)
              @log.error(
                "Ignoring TV at #{viera.ipAddress} as it requires encryption but no credentials were
                supplied."
              )
              brk = true
            else
              @addAccessory(tv, viera.hdmiInputs)
              .then(() ->)
              .catch((err) =>
                @log.error(
                  "An unexpected error happened while adding Viera TV (at '#{tv.ipAddress}')
                  as an homebridge Accessory.\n\n\n#{err}"
                )
                brk = true
              )
          )
          .catch((err) =>
            @log.error(
              "An unexpected error happened while fetching TV metadata. Please do make sure that the
              TV is powered on and NOT in stand-by.\n\n\n#{err}\n\n\nTrying again in 10s."
            )
            sleep(10000)
          )
      # eslint-disable-next-line coffee/no-loop-func
      else
        @log.error("Viera TV (at '#{tv.ipAddress}') was unreachable. Likely to be powered off.")

    @log('DidFinishLaunching')

  addAccessory: (tv, hdmiInputs) =>
    [@device, @applications] = [_.cloneDeep(tv), []]
    { friendlyName, serialNumber, modelName, modelNumber, manufacturer } = @device.specs

    @device.storage = new Proxy(@storage.get(serialNumber), {
      set: (obj, prop, value) =>
        # eslint-disable-next-line no-param-reassign
        obj[prop] = value
        @storage.save()
        return true
    })

    unless @device.storage.data?
      @log.debug("Initializing '#{@device.specs.friendlyName}' for the first time.")
      while @applications.length is 0
        await @device
        .getApps()
        .then((apps) =>
          @applications = _.cloneDeep(apps) unless apps.length is 0
        )
        .catch(() =>
          @log.warn(
            'Unable to fetch Application list from TV (as it seems to be in standby).
             Trying again in 5s.'
          )
          sleep(5000)
        )

      @device.storage.data = {
        inputs: {
          hdmi: hdmiInputs,
          applications: { ...@applications }
        }
        specs: { ...@device.specs }
      }
    else
      @log.debug("Restoring '#{@device.specs.friendlyName}'.")
      @device
      .getApps()
      .then((apps) =>
        @applications = _.cloneDeep(apps) unless apps.length is 0
      )
      .catch(() ->)
      .finally(() =>
        unless @applications.length isnt 0
          @log.debug('TV is in standby - getting (cached) TV apps')
          @applications = _.cloneDeep(@device.storage.data.inputs.applications)
      )
      # FIXME: smoothly handle modifications from both the hdmi inputs and apps lists

    newAccessory = new Accessory(friendlyName, serialNumber)
    newAccessory.on('identify', (paired, callback) =>
      @log.debug(friendlyName, 'Identify!!!')
      callback())

    tvService = new Service.Television(friendlyName, 'Television')
    tvService
    .setCharacteristic(Characteristic.ConfiguredName, friendlyName)
    .setCharacteristic(Characteristic.SleepDiscoveryMode, 1)
    tvService.addCharacteristic(Characteristic.RemoteKey)
    tvService.addCharacteristic(Characteristic.PowerModeSelection)

    speakerService = new Service.TelevisionSpeaker("#{friendlyName} Volume", 'volumeService')
    speakerService.addCharacteristic(Characteristic.Volume)

    volumeService = new Service.Lightbulb("#{friendlyName} Volume", 'volumeService')
    volumeService.addCharacteristic(Characteristic.Brightness)

    tvService.addLinkedService(speakerService)
    tvService.addLinkedService(volumeService)

    accessoryInformation = newAccessory.getService(Service.AccessoryInformation)
    accessoryInformation
    .setCharacteristic(Characteristic.Manufacturer, manufacturer)
    .setCharacteristic(Characteristic.Model, "#{modelName} #{modelNumber}")
    .setCharacteristic(Characteristic.SerialNumber, serialNumber)
    accessoryInformation.displayName = friendlyName
    accessoryInformation.subtype = 'specs'

    newAccessory.addService(tvService)
    newAccessory.addService(speakerService)
    newAccessory.addService(volumeService)

    tvService
    .getCharacteristic(Characteristic.Active)
    .on('get', @getPowerStatus)
    .on('set', @setPowerStatus)

    tvService.getCharacteristic(Characteristic.RemoteKey).on('set', @remoteControl)
    tvService.getCharacteristic(Characteristic.ActiveIdentifier).on('set', @setInput)

    speakerService.setCharacteristic(
      Characteristic.VolumeControlType,
      Characteristic.VolumeControlType.ABSOLUTE
    )

    speakerService
    .getCharacteristic(Characteristic.Mute)
    .on('get', @getMute)
    .on('set', @setMute)
    speakerService
    .getCharacteristic(Characteristic.Volume)
    .on('get', @getVolume)
    .on('set', @setVolume)

    volumeService
    .getCharacteristic(Characteristic.On)
    # .on('get', @getMute)
    # .on('set', @setMute)
    .on('get', (callback) =>
      { value } = tvService.getCharacteristic(Characteristic.Active)
      @log.debug('(volumeService/On.get)', value)
      if value is 0 then callback(null, false) else callback(null, true))
    .on('set', (value, callback) =>
      @log.debug('(volumeService/On.set)', value)
      if tvService.getCharacteristic(Characteristic.Active).value is 0
        volumeService.getCharacteristic(Characteristic.On).updateValue(false)
        callback(null, value)
      else
        callback(null, not value))

    volumeService
    .getCharacteristic(Characteristic.Brightness)
    .on('get', @getVolume)
    .on('set', @setVolume)

    # TV Tuner
    configuredName = 'TV Tuner'
    displayName = configuredName.toLowerCase().replace(' ', '')

    svc = new Service.InputSource(displayName, 500)
    tvService.addLinkedService(svc)
    newAccessory.addService(svc)
    await @configureInputSource(svc, 'TUNER', configuredName, parseInt(500, 10))

    # HDMI inputs
    for __, input of hdmiInputs
      configuredName = "HDMI #{input.id}: #{input.name}"
      displayName = configuredName.toLowerCase().replace(' ', '')

      if _.find(newAccessory.services, { displayName })
        @log.error('ignored duplicated entry in HDMI inputs list...')
      else
        svc = new Service.InputSource(displayName, input.id)
        tvService.addLinkedService(svc)
        newAccessory.addService(svc)
        await @configureInputSource(svc, 'HDMI', configuredName, parseInt(input.id, 10))

    # Apps
    for id, app of @applications
      configuredName = "#{app.name}"
      displayName = configuredName.toLowerCase().replace(' ', '')
      svc = new Service.InputSource(displayName, app.id)
      tvService.addLinkedService(svc)
      newAccessory.addService(svc)
      await @configureInputSource(svc, 'APPLICATION', configuredName, 1000 + parseInt(id, 10))

    tvEvent
    .on('INTO_STANDBY', () ->
      volumeService.getCharacteristic(Characteristic.On).updateValue(false)
      tvService
      .getCharacteristic(Characteristic.Active)
      .updateValue(Characteristic.Active.INACTIVE))
    .on('POWERING_ON', () ->
      volumeService.getCharacteristic(Characteristic.On).updateValue(true)
      tvService.getCharacteristic(Characteristic.Active).updateValue(Characteristic.Active.ACTIVE))

    setInterval(@getPowerStatus, 5000)

    newAccessory.reachable = true

    @api.publishExternalAccessories('homebridge-vieramatic', [newAccessory])

  configureAccessory: (tv) =>
    @previousAccessories.push(tv)

  configureInputSource: (source, type, configuredName, identifier) =>
    hiden = false
    # eslint-disable-next-line default-case
    switch type
      when 'HDMI'
        idx = _.findIndex(@device.storage.data.inputs.hdmi, ['id', identifier.toString()])
        if @device.storage.data.inputs.hdmi[idx].hiden?
          { hiden } = @device.storage.data.inputs.hdmi[idx]
      when 'APPLICATION'
        real = identifier - 1000
        if @device.storage.data.inputs.applications[real].hiden?
          { hiden } = @device.storage.data.inputs.applications[real]
        else
          hiden = true
      when 'TUNER'
        if @device.storage.data.inputs.TUNER?
          { hiden } = @device.storage.data.inputs.TUNER

    source
    .setCharacteristic(Characteristic.InputSourceType, Characteristic.InputSourceType[type])
    .setCharacteristic(Characteristic.CurrentVisibilityState, hiden)
    .setCharacteristic(Characteristic.TargetVisibilityState, hiden)
    .setCharacteristic(Characteristic.Identifier, identifier)
    .setCharacteristic(Characteristic.ConfiguredName, configuredName)
    .setCharacteristic(Characteristic.IsConfigured, Characteristic.IsConfigured.CONFIGURED)

    source
    .getCharacteristic(Characteristic.TargetVisibilityState)
    .on('set', (state, callback) =>
      id = source.getCharacteristic(Characteristic.Identifier).value
      # eslint-disable-next-line default-case
      switch
        when id < 100
          # hdmi input
          idx = _.findIndex(@device.storage.data.inputs.hdmi, ['id', id.toString()])
          @device.storage.data.inputs.hdmi[idx].hiden = state
          @device.storage.data = _.cloneDeep(@device.storage.data)
        when id > 999
          real = id - 1000
          @device.storage.data.inputs.applications[real].hiden = state
          @device.storage.data = _.cloneDeep(@device.storage.data)
        when id is 500
          @device.storage.data.inputs.TUNER = { hiden: state }
          @device.storage.data = _.cloneDeep(@device.storage.data)

      source.getCharacteristic(Characteristic.CurrentVisibilityState).updateValue(state)
      callback())

  getMute: (callback) =>
    mute = await @device.getMute()
    @log.debug('(getMute)', mute)
    callback(null, mute)

  setMute: (mute, callback) =>
    await @device.setMute()
    @log.debug('(setMute)', mute)
    callback(null, not mute)

  setVolume: (value, callback) =>
    @log.debug('(setVolume)', value)
    await @device.setVolume(value)
    callback(null, value)

  getVolume: (callback) =>
    volume = await @device.getVolume()
    @log.debug('(getVolume)', volume)
    callback(null, volume)

  getPowerStatus: (callback) =>
    # @log.debug('(getPowerStatus)')
    # eslint-disable-next-line coffee/no-inner-declarations
    if callback?
      # eslint-disable-next-line coffee/no-inner-declarations
      fn = (bool) -> callback(null, bool)
    else
      fn = (bool) -> bool

    powerStateSub = await new UpnpSub(@device.ipAddress, 55000, '/nrc/event_0')

    powerStateSub.on('message', (message) =>
      screenState = await findVal(message.body['e:propertyset']['e:property'], 'X_ScreenState')

      up = () =>
        tvEvent.emit('POWERING_ON')
        @poweredOn = true
        fn(true)
      down = () =>
        tvEvent.emit('INTO_STANDBY')
        @poweredOn = false
        fn(false)

      if screenState is 'none' or screenState is null or screenState is undefined
        @log.warn(
          "Couldn't check power state. Your TV may not be correctly set up or it
          may be incapable of performing power on from standby."
        )
        if screenState is 'none' then up() else down()
      # eslint-disable-next-line prettier/prettier
      else if screenState is 'on' then up() else down())

    powerStateSub.on('error', (err) =>
      @log.error(
        "Couldn't check power state. Please check your TV's network connection.
        Alternatively, your TV may not be correctly set up or it may not be able
        to perform power on from standby.",
        err
      )
      false)

    setTimeout(powerStateSub.unsubscribe, 900)

  setPowerStatus: (turnOn, callback) =>
    @log.debug('(setPowerStatus)', turnOn, @poweredOn)
    if (turnOn is 1 and @poweredOn is true) or (turnOn is 0 and @poweredOn is false)
      if turnOn then str = 'ON' else str = 'on STANDBY'
      @log.debug('TV is already %s: Ignoring!', str)
    else
      if turnOn then str = 'ON' else str = 'OFF'
      @log.debug('Powering TV %s...', str)
      if _.isError(await @device.sendCommand('POWER'))
        return callback(new Error('unable to power cycle TV - probably without power'))
      @poweredOn = not @poweredOn
    callback()

  remoteControl: (keyId, callback) =>
    # https://github.com/KhaosT/HAP-NodeJS/blob/master/src/lib/gen/HomeKit-TV.ts#L235
    # eslint-disable-next-line default-case
    switch keyId
      when 0 # Rewind
        cmd = 'REW'
      when 1 # Fast Forward
        cmd = 'FF'
      when 2 # Next Track
        cmd = 'SKIP_NEXT'
      when 3 # Previous Track
        cmd = 'SKIP_PREV'
      when 4 # Up Arrow
        cmd = 'UP'
      when 5 # Down Arrow
        cmd = 'DOWN'
      when 6 # Left Arrow
        cmd = 'LEFT'
      when 7 # Right Arrow
        cmd = 'RIGHT'
      when 8 # Select
        cmd = 'ENTER'
      when 9 # Back
        cmd = 'RETURN'
      when 10 # Exit
        cmd = 'CANCEL'
      when 11 # Play / Pause
        cmd = 'PLAY'
      when 15 # Information
        cmd = 'HOME'

    @log.debug(cmd)
    await @device.sendCommand(cmd)
    callback(null, keyId)

  setInput: (value, callback) =>
    # eslint-disable-next-line default-case
    switch
      when value < 100
        @log.debug('(setInput) switching to HDMI INPUT ', value)
        await @device.sendHDMICommand(value)
      when value > 999
        real = value - 1000
        app = @applications[real]
        @log.debug('(setInput) switching to App', app.name)
        await @device.sendAppCommand(app.id)
      when value is 500
        @log.debug('(setInput) switching to internal TV tunner')
        await @device.sendCommand('AD_CHANGE')

    callback(null, value)

#
# ## Public API
# --------
module.exports = Vieramatic
