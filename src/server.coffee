# Copyright (c) 2012 clowwindy
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

net = require("net")
fs = require("fs")
path = require("path")
utils = require("./utils")
inet = require("./inet")
Encryptor = require("./encrypt").Encryptor

console.log(utils.version)

inetNtoa = (buf) ->
  buf[0] + "." + buf[1] + "." + buf[2] + "." + buf[3]
inetAton = (ipStr) ->
  parts = ipStr.split(".")
  unless parts.length is 4
    null
  else
    buf = new Buffer(4)
    i = 0

    while i < 4
      buf[i] = +parts[i]
      i++
    buf

configFromArgs = utils.parseArgs()
configFile = configFromArgs.config_file or path.resolve(__dirname, "config.json")
configContent = fs.readFileSync(configFile)
config = JSON.parse(configContent)
for k, v of configFromArgs
  config[k] = v
if config.verbose
  utils.config(utils.DEBUG)
timeout = Math.floor(config.timeout * 1000)
portPassword = config.port_password
port = config.server_port
key = config.password
METHOD = config.method
SERVER = config.server

connections = 0

if portPassword 
  if port or key
    utils.warn 'warning: port_password should not be used with server_port and password. server_port and password will be ignored'
else
  portPassword = {}
  portPassword[port.toString()] = key
    
  
for port, key of portPassword
  (->
    # let's use enclosures to seperate scopes of different servers
    PORT = port
    KEY = key
#    util.log "calculating ciphers for port #{PORT}"
    
    server = net.createServer((connection) ->
      connections += 1
      encryptor = new Encryptor(KEY, METHOD)
      stage = 0
      headerLength = 0
      remote = null
      cachedPieces = []
      addrLen = 0
      remoteAddr = null
      remotePort = null
      utils.debug "connections: #{connections}"
      
      clean = ->
        utils.debug "clean"
        connections -= 1
        remote = null
        connection = null
        encryptor = null
        utils.debug "connections: #{connections}"

      connection.on "data", (data) ->
        utils.log utils.EVERYTHING, "connection on data"
        try
          data = encryptor.decrypt data
        catch e
          utils.error e
          remote.destroy() if remote
          connection.destroy() if connection
          return
        if stage is 5
          connection.pause()  unless remote.write(data)
          return
        if stage is 0
          try
            addrtype = data[0]
            if addrtype is 3
              addrLen = data[1]
            else unless addrtype in [1, 4]
              utils.error "unsupported addrtype: " + addrtype
              connection.destroy()
              return
            # read address and port
            if addrtype is 1
              remoteAddr = inetNtoa(data.slice(1, 5))
              remotePort = data.readUInt16BE(5)
              headerLength = 7
            else if addrtype is 4
              remoteAddr = inet.inet_ntop(data.slice(1, 17))
              remotePort = data.readUInt16BE(17)
              headerLength = 19
            else
              remoteAddr = data.slice(2, 2 + addrLen).toString("binary")
              remotePort = data.readUInt16BE(2 + addrLen)
              headerLength = 2 + addrLen + 2
            # connect remote server
            remote = net.connect(remotePort, remoteAddr, ->
              utils.info "connecting #{remoteAddr}:#{remotePort}"
              if not encryptor
                remote.destroy() if remote
                return
              i = 0
    
              while i < cachedPieces.length
                piece = cachedPieces[i]
                remote.write piece
                i++
              cachedPieces = null # save memory
              stage = 5
              utils.debug "stage = 5"
            )
            remote.on "data", (data) ->
              utils.log utils.EVERYTHING, "remote on data"
              if not encryptor
                remote.destroy() if remote
                return
              data = encryptor.encrypt data
              remote.pause()  unless connection.write(data)
    
            remote.on "end", ->
              utils.debug "remote on end"
              connection.end() if connection
    
            remote.on "error", (e)->
              utils.debug "remote on error"
              utils.error "remote #{remoteAddr}:#{remotePort} error: #{e}"
 
            remote.on "close", (had_error)->
              utils.debug "remote on close:#{had_error}"
              if had_error
                connection.destroy() if connection
              else
                connection.end() if connection
    
            remote.on "drain", ->
              utils.debug "remote on drain"
              connection.resume()
    
            remote.setTimeout timeout, ->
              utils.debug "remote on timeout"
              remote.destroy() if remote
              connection.destroy() if connection
    
            if data.length > headerLength
              # make sure no data is lost
              buf = new Buffer(data.length - headerLength)
              data.copy buf, 0, headerLength
              cachedPieces.push buf
              buf = null
            stage = 4
            utils.debug "stage = 4"
          catch e
            # may encouter index out of range
            util.log e
            connection.destroy()
            remote.destroy()  if remote
        else cachedPieces.push data  if stage is 4
          # remote server not connected
          # cache received buffers
          # make sure no data is lost
    
      connection.on "end", ->
        utils.debug "connection on end"
        remote.end()  if remote
     
      connection.on "error", (e)->
        utils.debug "connection on error"
        utils.error "local error: #{e}"

      connection.on "close", (had_error)->
        utils.debug "connection on close:#{had_error}"
        if had_error
          remote.destroy() if remote
        else
          remote.end() if remote
        clean()
    
      connection.on "drain", ->
        utils.debug "connection on drain"
        remote.resume()  if remote
    
      connection.setTimeout timeout, ->
        utils.debug "connection on timeout"
        remote.destroy()  if remote
        connection.destroy() if connection
    )
    servers = SERVER
    unless servers instanceof Array
      servers = [servers]
    for server_ip in servers
      server.listen PORT, server_ip, ->
        utils.info "server listening at #{server_ip}:#{PORT} "
    
    server.on "error", (e) ->
      utils.error "Address in use, aborting"  if e.code is "EADDRINUSE"
      process.exit 1
  )()

