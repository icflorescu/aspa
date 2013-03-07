fs     = require 'fs'
yaml   = require 'js-yaml'
path   = require 'path'
rimraf = require 'rimraf'
mkdirp = require 'mkdirp'
zlib   = require 'zlib'
stylus = require 'stylus'
nib    = require 'nib'
coffee = require 'coffee-script'
ics    = require 'iced-coffee-script'
jade   = require 'jade'
uglify = require 'uglify-js'
csso   = require 'csso'
watchr = require 'watchr'

cwd = process.cwd()

### ================================================================================================ Utility methods ###

buildOutputMap = (map, timestamp) ->
  outputMap = {}
  for own asset, options of map
    if timestamp
      output = path.basename asset
      output = "#{timestamp}.#{output}" unless options?.raw
      output += '.gz' if options?.compress or path.extname(asset) in ['.js', '.css']
      output = path.join path.dirname(asset), output
    else
      output = asset
    outputMap[asset] = output

  outputMap

buildStylesheetAssetsMap = (map, outputMap) ->
  stylesheetAssetsMap = {}
  for own asset, options of map when path.extname(asset) not in ['.js', '.css']
    source = if options?.from then path.join options.from, path.basename(asset) else asset
    stylesheetAssetsMap[path.resolve('', source)] = outputMap[asset]

  stylesheetAssetsMap

copy = (asset, from, to, outputMap, callback) ->
  source = if from then path.join from, path.basename(asset) else asset
  destination = path.join to, outputMap[asset]

  # Delete old destination file if necessary
  await fs.exists destination, defer found
  await fs.unlink destination, defer err if found
  if err then callback err; return

  # Create destination path
  await mkdirp path.dirname(destination), defer err
  if err then callback err; return

  if path.extname(destination) is '.gz'
    # Compress asset
    await fs.readFile source, 'utf8', defer err, contents
    if err then callback err; return
    await zlib.gzip contents, defer err, contents
    if err then callback err; return
    await fs.writeFile destination, contents, defer err
    operation = 'compressed'
  else
    # Just copy asset
    await fs.link source, destination, defer err
    operation = 'copied'
  console.log "#{source} #{operation} to #{destination}." unless err
  callback err

getSourceComment = (source) ->
  sourceLength = source.length
  comment = '/'
  comment += '*' for i in [0...118]
  comment += '/\n/'
  comment += '*' for i in [0...(115 - sourceLength)]
  comment += " #{source} */\n/"
  comment += '*' for i in [0...118]
  comment += '/\n\n'
  comment

stylesheetAssetUrlPattern = ///
  url\(             # url(
  [\'\"]?           # optional ' or "
  ([^\?\#\'\"\)]+)  # file                                       -> file
  ([^\'\"\)]*)      # optional suffix, i.e. #iefix in font URLs  -> suffix
  [\'\"]?           # optional ' or "
  \)                # )
///gi

adjustStylesheetAssetUrls = (contents, sourceFolder, stylesheetAssetsMap) ->
  contents = contents.replace stylesheetAssetUrlPattern, (src, file, suffix) ->
    filePath = path.resolve sourceFolder, file
    if stylesheetAssetsMap[filePath]
      "url(\"/#{stylesheetAssetsMap[filePath]}#{suffix}\")"
    else
      src
  contents

compile = (asset, sources, to, outputMap, stylesheetAssetsMap, callback) ->
  assetExt = path.extname(asset)
  destination = path.join to, outputMap[asset]

  # Delete old destination file if necessary
  await fs.exists destination, defer found
  await fs.unlink destination, defer err if found
  if err then callback err; return

  # Create destination path
  await mkdirp path.dirname(destination), defer err
  if err then callback err; return

  contents = ''

  for own source, options of sources when options?.skip isnt on

    # Add a comment-separator before each source
    contents += '\n' unless contents is ''
    contents += getSourceComment(source)

    # Read source
    await fs.readFile source, 'utf8', defer err, content
    if err then callback err; return
    sourceExt = path.extname source

    # Perform compilation, depending on source extension
    switch sourceExt
      when '.styl'
        compiler = stylus(content)
          .set('filename', source)
          .set('compress', no)
          .set('debug', yes)
        compiler.use(nib()).import('nib') if options?.nib
        await compiler.render defer err, content
        if err then callback err; return
      when '.iced', '.coffee'
        compiler = if sourceExt is '.iced' then ics else coffee
        try
          content = compiler.compile content, { bare: options?.bare }
        catch err
          callback err; return
      when '.jade'
        templateName = path.join path.dirname(source), path.basename(source, '.jade')
        try
          content = jade.compile content, { client: yes, compileDebug: no }
          content = "JST['#{templateName}'] = #{content};\n"
        catch err
          callback err; return
      else # no compilation needed, so nothing to do

    # Adjust URLs for assets reffered within CSS files
    content = adjustStylesheetAssetUrls content, path.dirname(source), stylesheetAssetsMap if assetExt is '.css'

    contents += content

  if path.extname(destination) is '.gz'
    # Perform optimizations depending on asset extension, then compress
    if assetExt is '.js'
      contents = uglify.minify(contents, { fromString: yes }).code
    else
      contents = csso.justDoIt contents
    await zlib.gzip contents, defer err, contents
    if err then callback err; return
    operation = 'compiled and compressed'
  else
    operation = 'compiled'

  # Write contents
  await fs.writeFile destination, contents, defer err
  console.log "Input source files #{operation} to #{destination}." unless err
  callback err

### =============================================================================================== Exported methods ###

# Cleanup public folder and delete existent output map
exports.cleanup = cleanup = (options, callback) ->
  outputMapFile = "#{options.root}#{path.sep}aspa.json"

  # Delete old output map if necessary
  await fs.exists outputMapFile, defer found
  await fs.unlink outputMapFile, defer err if found
  if err then callback err; return

  # Recreate public folder
  await rimraf options.public, defer err
  if err then callback err; return
  await fs.mkdir options.public, defer err

  console.log 'Cleanup finished.' unless err
  callback err

# Build assets in current folder for development or production
exports.build = build = (options, callback) ->

  # Perform a cleanup first
  await cleanup options, defer err
  if err then callback err; return

  timestamp = (new Date).getTime().toString() if options.mode is 'production'

  map = require path.join(cwd, 'aspa.yml')
  outputMap = buildOutputMap map, timestamp
  stylesheetAssetsMap = buildStylesheetAssetsMap map, outputMap

  # Process asset map
  for own asset, assetOptions of map
    await
      if path.extname(asset) in ['.js', '.css']
        compile asset, assetOptions.from, options.public, outputMap, stylesheetAssetsMap, defer err
      else
        copy asset, assetOptions?.from, options.public, outputMap, defer err
    if err then callback err; return

  # Write output map if mode is production
  if options.mode is 'production'
    await fs.writeFile path.join(options.root, 'aspa.json'), JSON.stringify(outputMap, null, '\t'), defer err

  console.log 'Build finished.' unless err
  callback err

# Continuously watch the current folder, building assets as source files change
exports.watch = (options, callback) ->
  unless options.mode is 'development'
    callback('Watch only works for development mode.')
    return

  # Wrapper method so we can restart on map file change
  work = ->
    # Perform a build first
    await build options, defer err
    callback err if err

    mapFile = path.join(cwd, 'aspa.yml')
    await fs.readFile mapFile, 'utf8', defer err, mapFileContents
    callback err if err
    map = yaml.load mapFileContents

    outputMap = buildOutputMap map
    stylesheetAssetsMap = buildStylesheetAssetsMap map, outputMap

    console.log 'Watching folder...'
    watcher = watchr.watch
      path: cwd
      listener: (e, file) ->
        console.log e, file

        # Restart work when input asset map file is changed
        if file is mapFile and e is 'update'
          console.log 'Source map file changed, restarting...'
          watcher.close()
          work()
          return

        if e in ['create', 'update']
          for own asset, assetOptions of map
            if path.extname(asset) in ['.js', '.css']
              for own source of assetOptions.from
                if file is path.resolve(cwd, source)
                  await compile asset, assetOptions.from, options.public, outputMap, stylesheetAssetsMap, defer err
                  callback err if err
            else
              source = if assetOptions?.from then path.join assetOptions.from, path.basename(asset) else asset
              if file is path.resolve(cwd, source)
                await copy asset, assetOptions?.from, options.public, outputMap, defer err
                callback err if err
  work()
