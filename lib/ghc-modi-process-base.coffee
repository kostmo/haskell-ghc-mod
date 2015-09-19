{BufferedProcess, Emitter, CompositeDisposable} = require('atom')
CP = require('child_process')
{debug} = require './util'

module.exports =
class GhcModiProcessBase
  processMap: null

  constructor: ->
    @processMap = new WeakMap
    @disposables = new CompositeDisposable
    @disposables.add @emitter = new Emitter

  spawnProcess: (rootDir, legacyInteractive, options) =>
    return unless @processMap?
    return unless atom.config.get('haskell-ghc-mod.enableGhcModi')
    timer = setTimeout (=>
      debug "Killing ghc-modi for #{rootDir.getPath()} due to inactivity"
      @killProcessForDir rootDir), 60 * 60 * 1000
    proc = @processMap.get(rootDir)
    debug "Checking for ghc-modi in #{rootDir.getPath()}"
    if proc?
      debug "Found running ghc-modi instance for #{rootDir.getPath()}"
      clearTimeout proc.timer
      proc.timer = timer
      return proc.process
    debug "Spawning new ghc-modi instance for #{rootDir.getPath()} with
          #{"options.#{k} = #{v}" for k, v of options}"
    proc =
      if legacyInteractive
        modPath = atom.config.get('haskell-ghc-mod.ghcModPath')
        CP.spawn(modPath, ['legacy-interactive'], options)
      else
        modiPath = atom.config.get('haskell-ghc-mod.ghcModiPath')
        CP.spawn(modiPath, [], options)
    proc.stdout.pause()
    proc.stderr.pause()
    proc.on 'exit', (code) =>
      debug "ghc-modi for #{rootDir.getPath()} ended with #{code}"
      console.error "Ghc-modi said: #{proc.stderr.read()}"
      @processMap?.delete(rootDir)
      @spawnProcess(rootDir, options) if code != 0
    @processMap.set rootDir,
      process: proc
      timer: timer
    return proc

  runModCmd: ({options, command, text, uri, args, callback}) ->
    modPath = atom.config.get('haskell-ghc-mod.ghcModPath')
    result = []
    err = []
    if uri?
      cmd = [command, uri].concat args
    else
      cmd = [command].concat args
    if text?
      cmd = ['--map-file', uri].concat cmd
    debug "running #{modPath} #{cmd} with
          #{"options.#{k} = #{v}" for k, v of options}"
    process = new BufferedProcess
      command: modPath
      args: cmd
      options: options
      stdout: (data) ->
        result = result.concat(data.split('\n'))
      stderr: (data) ->
        err = err.concat(data.split('\n'))
      exit: (code) ->
        debug "#{modPath} ended with code #{code}"
        if code != 0
          atom.notifications.addError "Haskell-ghc-mod: #{modPath}
              #{cmd.join ' '} failed with error code #{code}",
            detail: "#{err.join('\n')}"
            dismissable: true
          console.error err
          callback []
        else
          callback result.slice(0, -1).map (line) ->
            line.replace /\0/g, '\n'
    if text?
      debug "sending stdin text to #{modPath}"
      process.process.stdin.write "#{text}\x04\n"
    process.onWillThrowError ({error, handle}) ->
      console.warn "Using fallback child_process because of #{error.message}"
      child = CP.execFile modPath, cmd, options, (cperror, stdout, stderr) ->
        if cperror?
          atom.notifications.addError "Haskell-ghc-mod: #{modPath}
              #{cmd.join ' '} failed with error message #{cperror}",
            detail: "#{stdout}\n#{stderr}"
            dismissable: true
          callback []
        else
          callback stdout.split('\n').slice(0, -1).map (line) ->
            line.replace /\0/g, '\n'
      child.error = (error) ->
        console.error error
        callback []
      if text?
        debug "sending stdin text to #{modPath}"
        child.stdin.write "#{text}\x04\n"
      handle()

  runModiCmd: ({dir, options, command, text, uri, args, callback, legacyInteractive}) =>
    debug "Trying to run ghc-modi in #{dir.getPath()}"
    process = @spawnProcess(dir, legacyInteractive, options)
    unless process
      debug "Failed. Falling back to ghc-mod"
      return @runModCmd {options, command, text, uri, args, callback}
    savedLines = []
    parseData = ->
      data = process.stdout.read()
      unless data?
        atom.notifications.addError "Haskell-ghc-mod: ghc-modi crashed
            on #{command} with message #{savedLines.join('\n')}",
          detail: dir.getPath()
          dismissable: true
        console.error savedLines
        callback []
        return
      data = data.toString()
      debug "Got response from ghc-modi:\n#{data}"
      lines = data.split("\n")
      savedLines = savedLines.concat lines
      result = lines[lines.length - 2]
      if result.match(/^OK/)
        lines = savedLines.slice(0, -2)
        callback lines.map (line) ->
          line.replace /\0/g, '\n'
      else
        process.stdout.once 'readable', parseData
    if text?
      debug "Loading file text for ghc-modi"
      process.stdin.write "map-file #{uri}\n#{text}\x04\n"
      process.stdout.once 'readable', ->
        data = process.stdout.read().toString()
        if data isnt 'OK\n'
          debug "Failed to load file text for ghc-modi"
          callback []
          return
        debug "Successfully loaded file text for ghc-modi"
        process.stdout.once 'readable', parseData
    else
      process.stdout.once 'readable', parseData

    if uri?
      cmd = [command, uri].concat args
    else
      cmd = [command].concat args
    debug "Running ghc-modi command #{cmd}"
    process.stdin.write cmd.join(' ').replace(/\r|\r?\n/g, ' ') + '\n'

    if text?
      debug "Unloading file text from ghc-modi"
      process.stdin.write "unmap-file #{uri}\n"

  killProcess: =>
    return unless @processMap?
    debug "Killing all ghc-modi processes"
    atom.project.getDirectories().forEach (dir) =>
      @killProcessForDir dir

  killProcessForDir: (dir) =>
    return unless @processMap?
    debug "Killing ghc-modi process for #{dir.getPath()}"
    clearTimeout @processMap.get(dir)?.timer
    @processMap.get(dir)?.process.stdin?.end?()
    @processMap.get(dir)?.process.kill?()
    @processMap.delete(dir)

  destroy: =>
    return unless @processMap?
    debug "GhcModiProcessBase destroying"
    @killProcess()
    @emitter.emit 'did-destroy'
    @emitter = null
    @disposables.dispose()
    @processMap = null

  onDidDestroy: (callback) =>
    return unless @processMap?
    @emitter.on 'did-destroy', callback
