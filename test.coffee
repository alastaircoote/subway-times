ProtoBuf = require 'protobufjs'
Promise = require 'bluebird'
path = require 'path'
fs = Promise.promisifyAll require 'fs'
requestAsync = Promise.promisify require 'request'

Knex = require 'knex'
Knexfile = require './knexfile'
Moment = require 'moment'

DB = Knex Knexfile.development

builder = ProtoBuf.loadProtoFile(path.join(__dirname, "gtfs-realtime.proto"))

realtime = builder.build('transit_realtime')

CURRENT_STATUS =
    0: "INCOMING_AT"
    1: "STOPPED_AT"
    2: "IN_TRANSIT_TO"

lastTimeStamp = 0
doCheck = ->
    Promise.map [
        'http://datamine.mta.info/mta_esi.php?key=247e4c91f9904df0b62dbc4ea9845c94&feed_id=1',
        'http://datamine.mta.info/mta_esi.php?key=247e4c91f9904df0b62dbc4ea9845c94&feed_id=2'
    ], (url) ->

        requestAsync
            url: url
            encoding: null
        .then ([res,body]) ->
            response = null
            try
                response = realtime.FeedMessage.decode(res.body)
            catch err
                console.log new Date().getHours() + ':' + new Date().getMinutes() + " - Parse of #{url} failed."
                fs.writeFileAsync './failed-parse.txt', body
                throw err
            return response

    .each (response) ->

        trips = []

        findTrip = (tripId) ->
            targetTrip = trips.filter((t) -> t.trip_id == tripId)[0]
            if !targetTrip
                targetTrip = {trip_id: tripId}
                trips.push targetTrip

            return targetTrip

        for entity in response.entity
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

        Promise.filter trips, (trip) ->
            # Only add updates that have changed since last time.
            DB.select('timestamp')
                .from('trip_timestamps')
                .where('trip_id',trip.trip_id)
                .orderBy('timestamp','desc')
                .limit(1)
            .then (rows) ->
                return !rows[0] or rows[0].timestamp != trip.timestamp
        .each (trip) ->




            DB('trip_timestamps')
            .insert
                trip_id: trip.trip_id
                route_id: trip.route_id
                timestamp: trip.timestamp
                current_stop: trip.stop_id
                current_status: trip.current_status
                current_stop_sequence: trip.current_stop_sequence
            .then ->

                stopRows = trip.stop_time_update.map (t) ->
                    return {
                        timestamp: trip.timestamp
                        trip_id: trip.trip_id
                        stop_id: t.stop_id
                        arrival_time: t.arrival?.time.low
                        departure_time: t.departure?.time.low
                    }

                DB('timestamp_updates')
                    .insert stopRows
        
        .then (trips) ->
            #console.log "Inserted #{trips.length} trips..."
    .finally ->
        setTimeout doCheck, 15000

doCheck()
