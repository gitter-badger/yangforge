# REST/JSON interface feature module
#
# This feature add-on module enables dynamic REST/JSON interface
# generation based on available runtime `module` instances.
#
# It utilizes the underlying [express](express.litcoffee) feature add-on
# to dynamically create routing middleware and associates various HTTP
# method facilities according to the available runtime `module`
# instances.

module.exports = 
  description: 'REST/JSON web services interface generator'

  # Routers 
  # when called with an instance context will attach various handlers
  routers:
    loop: (target) ->
      @all '*', (req, res, next) ->
        req.target ?= target
        next()

      @param 'target', (req, res, next, target) ->
        match = req.target.access? target
        if match? then req.target = match; next() else next 'route'

      @get '/', (req, res, next) ->
        res.locals.result = req.target.serialize()
        next()

      return this

    source: (target) ->
      @route '/'
      .all (req, res, next) ->
        req.target ?= target
        if (req.target?.meta? 'synth') is 'source'
          console.log "source router: #{req.originalUrl}"
          next()
        else next 'route'
      .options (req, res, next) ->
        res.send
          REPORT:
            description: 'get detailed information about this source'
          GET:
            description: 'get serialized output for this source'
          PUT:
            description: 'update configuration for this source'
          COPY:
            description: 'get a copy of this source for cloning it elsewhere'
      .report (req, res, next) -> 
        res.locals.result = req.target.info(); next()
      .copy (req, res, next) ->
        res.locals.result = req.target.export(); next()

      return this

    store: (target) ->
      @route '/'
      .all (req, res, next) ->
        req.target ?= target
        if (req.target?.meta? 'synth') is 'store'
          console.log "store router: #{req.originalUrl}"
          next()
        else next 'route'
      .report (req, res, next) ->
        res.locals.result = req.target.parent.info()
        next()

      return this

    model: (target) ->
      @route '/'
      .all (req, res, next) ->
        req.target ?= target
        if (req.target?.meta? 'synth') in [ 'store', 'model' ]
          console.log "model router: #{req.originalUrl}"
          next()
        else next 'route'
      .put (req, res, next) ->
        (req.target.set req.body).save()
        .then (result) ->
          res.locals.result = req.target.serialize();
          next()
        .catch (err) ->
          req.target.rollback()
          next err

      @param 'action', (req, res, next, action) ->
        if req.target.methods?[action]? then next() else next 'route'

      @route '/:action'
      .options (req, res, next) ->
        method = req.target.methods[req.params.action]
        input  = method.input.extract()
        output = method.output.extract()
        # need to do something better...
        delete input?.uses
        delete input?.typedef
        delete input?.bindings
        delete output?.uses
        delete output?.typedef
        delete output?.bindings
        res.send
          POST:
            description: method.params.description
            status:      method.params.status
            reference:   method.params.reference
            input:  input
            output: output
      .post (req, res, next) ->
        console.info "restjson: invoking rpc operation '#{req.params.action}'".grey
        req.target.invoke req.params.action, req.body
          .then  (output) -> res.locals.result = output.get(); next()
          .catch (err) -> next err
      return this

    object: (target) ->
      @route '/'
      .all (req, res, next) ->
        req.target ?= target
        if (req.target?.meta? 'synth') is 'object'
          console.log "object router: #{req.originalUrl}"
          next()
        else next 'route'
      .put (req, res, next) ->
        req.target.set req.body
        model = req.target.seek synth: (v) -> v in [ 'store', 'model' ]
        model.save()
        .then (result) ->
          res.locals.result = req.target.serialize();
          next()
        .catch (err) ->
          req.target.rollback()
          next err

      # Add any special logic for handling 'container' here
      return this

    list: (target) ->
      @route '/'
      .all (req, res, next) ->
        req.target ?= target
        if (req.target?.meta? 'synth') is 'list'
          console.log "list router: #{req.originalUrl}"
          next()
        else next 'route'
      .post (req, res, next) ->
        return next "cannot add a new entry without supplying data" unless Object.keys(req.body).length
        items = switch
          when req.body instanceof Array then req.target.push req.body...
          else req.target.push req.body
        model = req.target.seek synth: (v) -> v in [ 'store', 'model' ]
        model.save()
        .then (result) ->
          res.locals.result = req.target.serialize()
          next()
        .catch (err) ->
          model.rollback()
          next err

      @get '/:key', (req, res, next) ->
        res.locals.result = req.target.get req.params.key
        next()

      @delete '/:key', (req, res, next) ->
        req.target.remove req.params.key
        req.target.parent.save()
        .then (result) ->
          res.locals.result = result.serialize()
          next()
        .catch (err) ->
          req.target.parent.rollback()
          next err

      return this

  run: (model, runtime) ->
    console.log "generating REST/JSON interface..."
    source  = model.parent
    express = require 'express'

    loopRouter   = @routers.loop.call   express.Router(), source
    sourceRouter = @routers.source.call express.Router(), source
    storeRouter  = @routers.store.call  express.Router(), model
    modelRouter  = @routers.model.call  express.Router(), model
    objectRouter = @routers.object.call express.Router()
    listRouter   = @routers.list.call   express.Router()

    loopRouter.use sourceRouter, storeRouter, modelRouter, objectRouter, listRouter
    # Nested Loopback to itself if additional target in the URL
    loopRouter.use '/:target', loopRouter

    bp = require 'body-parser'
    passport = require 'passport'
    restjson = (->
      @use bp.urlencoded(extended:true), bp.json(strict:true), passport.initialize()

      @use loopRouter, (req, res, next) ->
        # always send back contents of 'result' if available
        unless res.locals.result? then return next 'route'
        res.setHeader 'Expires','-1'
        res.send res.locals.result
        next()

      # default log successful transaction
      @use (req, res, next) ->
        #req.forge.log?.info query:req.params.id,result:res.locals.result,
        # 'METHOD results for %s', req.record?.name
        next()

      # default 'catch-all' error handler
      @use (err, req, res, next) ->
        console.error err
        res.status(err.status ? 500).send error: switch
          when err instanceof Error then err.toString()
          else JSON.stringify err

      return this
    ).call express()

    if runtime.express?.app?
      console.info "restjson: binding forgery to /restjson".grey
      runtime.express.app.use "/restjson", restjson

    return restjson
