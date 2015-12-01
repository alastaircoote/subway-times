ProtoBuf = require 'protobufjs'
Promise = require 'bluebird'
path = require 'path'
fs = Promise.promisifyAll require 'fs'
zlib = require 'zlib'
requestAsync = Promise.promisify require 'request'
AWS = require 'aws-sdk'

awsCreds = require './aws.json'

AWS.config.update
    accessKeyId: awsCreds.key
    secretAccessKey: awsCreds.secret

s3Client = new AWS.S3()

s3Stream = require('s3-upload-stream')(s3Client);

Moment = require 'moment'

builder = ProtoBuf.loadProtoFile(path.join(__dirname, "gtfs-realtime.proto"))

realtime = builder.build('transit_realtime')

CURRENT_STATUS =
    0: "INCOMING_AT"
    1: "STOPPED_AT"
    2: "IN_TRANSIT_TO"

# We keep track of the timestamps in the headers, and disregard any we've already checked
lastTimeStamps = []


lastTripTimestamps = {}

fs.mkdirAsync(__dirname + '/time-data')
.catch (err) ->
    if (err.cause.code != 'EEXIST') then throw err

numFeeds = 0
isCompressingNow = false

doCheck = ->
    Promise.map [
        'http://datamine.mta.info/mta_esi.php?key=247e4c91f9904df0b62dbc4ea9845c94&feed_id=1',
        'http://datamine.mta.info/mta_esi.php?key=247e4c91f9904df0b62dbc4ea9845c94&feed_id=2',
        'http://datamine.mta.info/mta_esi.php?key=247e4c91f9904df0b62dbc4ea9845c94&feed_id=11'
    ], (url) ->

        requestAsync
            url: url
            encoding: null
        .then ([res,body]) ->
            response = null
            try
                response = realtime.FeedMessage.decode(res.body)
            catch err
                #console.log new Date().getHours() + ':' + new Date().getMinutes() + " - Parse of #{url} failed."
                return null

            return response

    .filter (response, i) ->
        if !response then return false
        if !lastTimeStamps[i] then return true
        return response.header.timestamp.low > lastTimeStamps[i]
    .then (feeds) ->
        numFeeds = feeds.length
        return feeds
    .each (response, i) ->
        lastTimeStamps[i] = response.header.timestamp.low
    .reduce (prev, item) ->
        # Merge the feeds into one.
        return prev.concat(item.entity)
    , []
    .then (entities) ->
        trips = []

        findTrip = (tripId) ->
            targetTrip = trips.filter((t) -> t.trip_id == tripId)[0]
            if !targetTrip
                targetTrip = {trip_id: tripId}
                trips.push targetTrip

            return targetTrip

        for entity in entities
            if entity.trip_update
                tripId = entity.trip_update.trip.trip_id

                targetTrip = findTrip(tripId)
                targetTrip.stop_time_update = entity.trip_update.stop_time_update

            if entity.vehicle
                tripId = entity.vehicle.trip.trip_id
                targetTrip = findTrip(tripId)

                targetTrip.current_status = CURRENT_STATUS[entity.vehicle.current_status]
                targetTrip.stop_id = entity.vehicle.stop_id
                targetTrip.route_id = entity.vehicle.trip.route_id
                targetTrip.timestamp = entity.vehicle.timestamp.low
                targetTrip.vehicle = entity.vehicle
                targetTrip.current_stop_sequence = entity.vehicle.current_stop_sequence
                #for key,val of entity
                #    targetTrip[key] = val

        #console.log "Downloaded #{trips.length} trips..."

        trips = trips.filter (t) ->
            t.vehicle and t.stop_time_update

        for trip in trips
            match = trips.filter (t) -> t.trip_id == trip.trip_id and t.timestamp == trip.timestamp

            if match.length > 1
                console.log('WFFF')


        Promise.filter trips, (trip) ->
            if !lastTripTimestamps then return true
            # Only add updates that have changed since last time.

            timestampLastTime = lastTripTimestamps[trip.trip_id]

            # No entry for this trip
            if (!timestampLastTime) then return true
            # If it's the same timestamp, ignore

            if (timestampLastTime == trip.timestamp)
                return false

            return true


        .each (validTrip) ->
            # Now update those timestamps
            lastTripTimestamps[validTrip.trip_id] = validTrip.timestamp

        .then (filteredTrips) ->

            # Filter out old timestamps for memory management
            rightNowSeconds = Date.now() / 1000

            deletedCount = 0
            for key, val of lastTripTimestamps
                if val < rightNowSeconds - (60 * 60 * 12) # 12 hours
                    delete lastTripTimestamps[key]
                    console.log("Deleting", key, val)
                    deletedCount++

            if deletedCount > 0
                console.log Moment().format("HH:mm:ss") + " - Deleted #{deletedCount} old trip timestamps."

            for trip in filteredTrips
                filtered = filteredTrips.filter (t) ->
                    t.trip_id == trip.trip_id and t.timestamp == trip.timestamp

                if filtered.length > 1
                    console.log 'multiple timestamp things'


            lowestTimestamp = Math.min.apply(Math,lastTimeStamps)

            files = [{
                filename: __dirname + '/time-data/' + Moment(lowestTimestamp * 1000).format('YYYYMMDD') + '_trips.csv'
                columns: ['trip_id', 'route_id', 'timestamp', 'current_status', 'stop_id', 'current_stop_sequence']
            },{
                filename: __dirname + '/time-data/' + Moment(lowestTimestamp * 1000).format('YYYYMMDD') + '_arrivaltimes.csv'
                columns: ['trip_id', 'timestamp','stop_id','arrival_time','departure_time']
            }];



            Promise.each files, (file) ->
                fs.statAsync(file.filename)
                .catch (err) ->
                    if err.cause.code == 'ENOENT'
                        return fs.writeFileAsync(file.filename, file.columns.join(','))
                .then ->
                    fs.openAsync file.filename, 'a'
                .then (handle) ->
                    file.handle = handle
                    return file
            .spread (timestamps, arrival_predictions) ->
                for trip in filteredTrips
                    tripData = timestamps.columns.map((col) -> trip[col]).join(',')
                    fs.write timestamps.handle, '\n' + tripData

                    for update in trip.stop_time_update
                        update.trip_id = trip.trip_id
                        update.timestamp = trip.timestamp
                        update.arrival_time = update.arrival?.time.low
                        update.departure_time = update.departure?.time.low
                        updateData = arrival_predictions.columns.map((col) -> update[col]).join(',')
                        fs.write arrival_predictions.handle, '\n' + updateData

                return [timestamps, arrival_predictions]

            .each (file) ->
                fs.fsyncAsync file.handle
            .each (file) ->
                fs.closeAsync file.handle

            console.log Moment().format("HH:mm:ss") + " - Wrote #{filteredTrips.length} out of #{trips.length} trips in #{numFeeds} feeds."
            return fs.writeFileAsync(__dirname + '/last_response.json',JSON.stringify(lastTripTimestamps))
            .then -> return Moment(lowestTimestamp * 1000)
    .then (todayMoment) ->
        if isCompressingNow
            console.log("Already compressing, will not restart")
            return true

        isCompressingNow = true
        yesterday = todayMoment.subtract(1,'days').format('YYYYMMDD')
        files = [
            __dirname + '/time-data/' + yesterday + '_trips.csv'
            __dirname + '/time-data/' + yesterday + '_arrivaltimes.csv'
        ]

        Promise.each files, (file) ->
            fs.statAsync(file)
            .then ->
                new Promise (fulfill, reject) ->
                    console.log Moment().format("HH:mm:ss") + " - Compressing #{file}"
                    gzip = zlib.createGzip()
                    inp = fs.createReadStream file
                    #out = fs.createWriteStream file + '.gz'

                    upload = s3Stream.upload({
                      "Bucket": "subway-data",
                      "Key": path.basename(file) + '.gz'
                    });



                    inp.pipe(gzip).pipe(upload)

                    upload.on 'uploaded', (details) ->
                        console.log Moment().format("HH:MM:ss") + " - Compression and upload complete."
                        fulfill fs.unlinkAsync file
                    inp.on 'error', reject
                    upload.on 'error', reject
            .catch (err) ->
                # If the file doesn't exist (i.e. is already uploaded) then we can swallow the error
                if err.cause?.code != 'ENOENT' then throw err
        .then ->
            isCompressingNow = false

        # Don't return the promise as we don't want the timer to be delayed by compression
        return true

    .catch (err) ->
        # We just want to swallow the error
        console.log Moment().format("HH:mm:ss") + "- Error encountered: " + err
        return true
    .then ->
        setTimeout doCheck, 5000

fs.readFileAsync(__dirname + '/last_response.json')
.then (contents) ->
    lastTripTimestamps = JSON.parse(contents)
.catch (err) ->
    console.log "No existing response"
.then ->
    doCheck()
