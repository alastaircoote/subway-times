unzip = require 'unzip'
http = require 'http'
csv = require 'csv'
request = require 'request'
Promise = require 'bluebird'
fs = require 'fs'
AdmZip = require 'adm-zip'
streamifier = require 'streamifier'
async = require 'async'

dataPath = __dirname + '/../data'

if !fs.existsSync dataPath
    fs.mkdirSync dataPath

transitFile = dataPath + '/transit.zip'

Knex = require '../shared/knex'



(do ->
    if fs.existsSync transitFile
        console.log "#{transitFile} already exists"
        return Promise.resolve()

    deferred = Promise.defer()
    http.get 'http://web.mta.info/developers/data/nyct/subway/google_transit.zip', (res) ->
        file = fs.createWriteStream dataPath + '/transit.zip'
        res.pipe(file)
        file.on 'finish', ->
            file.close -> deferred.resolve()

    return deferred.promise

).then ->
    zip = new AdmZip transitFile

    zip.extractAllTo dataPath, true
        
    deferred = Promise.defer()

    tableOrder = [
        'agency'
        'calendar'
        'calendar_dates'
        'routes'
        'stops'
        'trips'
        'stop_times'
        'transfers'
    ]


    tableOrder.reverse()

    async.eachSeries tableOrder, (tableName, cb) ->
        console.log "Truncating #{tableName}..."
        Knex.DB(tableName).delete()
        .then ->
            console.log "truncate of #{tableName} complete"
            cb()

    , () ->
        tableOrder.reverse()



        async.eachSeries tableOrder, (tableName, cb) ->
          
            if tableName == 'shapes' then return cb()
            

            
            rows = 0
            fs.createReadStream dataPath + '/' + tableName + '.txt'
            .pipe(csv.parse({columns:true}))
            .on 'data', (data) ->
                rows++
                process.stdout.write "\r wrote row #{rows}..."
                #console.log 'insert into ' + tableName
                Knex.DB(tableName).insert(data)
                .catch (err) ->
                    console.log data
                    console.log err

            .on 'end', ->
                console.log "Completed #{tableName}"
                #trx.commit()
                cb()

            console.log 'huh'

        , () ->
            deferred.resolve()


        return deferred.promise

        

.then ->
    console.log "end"
 

                #.then -> console.log 'inserted'

                #console.log entry.entryName
                #console.log data

