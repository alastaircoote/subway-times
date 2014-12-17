ProtoBuf = require 'protobufjs'
Promise = require 'bluebird'
path = require 'path'
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
    requestAsync
        url: 'http://datamine.mta.info/mta_esi.php?key=247e4c91f9904df0b62dbc4ea9845c94&feed_id=1'
        encoding: null
    .then ([res,body]) ->
        try
            response = realtime.FeedMessage.decode(res.body)
        catch
            console.log new Date().getHours() + ':' + new Date().getMinutes() + ' - Parse failed.'
            return

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
        ###
        trips = trips.sort (a,b) ->
            return a.trip_id - b.trip_id

        firstTrip = trips[0]

        if lastTimeStamp == firstTrip.timestamp * 1000
            return

        timestamp = Moment new Date(firstTrip.timestamp * 1000)
        timestampFormatted = timestamp.format('hh:mm:ss')

        

        console.log "#{timestampFormatted} - Trip #{firstTrip.trip_id} is #{firstTrip.current_status} at #{firstTrip.stop_time_update[0].stop_id}"
        for station in firstTrip.stop_time_update
            dueTime = Moment new Date(station.arrival.time.low * 1000)
            dueTimeFormatted = dueTime.format('hh:mm:ss')
            if station.departure
                if !station.departure.time
                    console.log station
                else
                    departTime = Moment new Date(station.departure.time.low * 1000)
                    departTimeFormatted = dueTime.format('hh:mm:ss')
            else
                departTimeFormatted = 'unknown'
            console.log "\t  - Due at #{station.stop_id} at #{dueTimeFormatted}, leaving at #{departTimeFormatted}"

        lastTimeStamp = firstTrip.timestamp * 1000

        return 
        #return console.log JSON.stringify(trips,null,2)
        ###
    .finally ->
        setTimeout doCheck, 15000
doCheck()
###
    trips = trips.filter (t) ->
        # Get rid of trips that don't have vehicles. These trips should have
        # a departure time in the first station (because they're stationary there)
        # AND that departure time should be in the future.

        # The MTA only assigns a vehicle a few minutes before departure.

        if t.timestamp then return true

        if !t.stop_time_update[0].departure
            console.log "No departure time?"
            return false

        if new Date(t.stop_time_update[0].departure * 1000) <= Date.now()
            console.log "Departure time in the past?"
            return false
        return false

    

    duplicates = 0
    inserted = 0
    inserted_update = 0

    Promise.map trips, (trip) ->

        [ignore, start_time, service_id, direction] = /(.*)_(.*)\.(.*)/.exec(trip.trip_id)
        
        if service_id.indexOf('.') == 1
            service_id = service_id.substr(0,1)


        DB.select('trip_id')
        .from('trip_timestamps')
        .where('trip_id',trip.trip_id)
        .where('timestamp', trip.timestamp)
        .then (rows) ->
            if rows.length > 0
                duplicates++
                return true

            DB('trip_timestamps')
            .insert
                trip_id: trip.trip_id
                start_time: start_time
                service_id: service_id
                direction: direction
                timestamp: trip.timestamp
                current_status: trip.current_status
                stop_id: trip.stop_id
            .then ->

                updateRows = trip.stop_time_update.map (t) ->

                    return {
                        timestamp: trip.timestamp
                        trip_id: trip.trip_id
                        stop_id: t.stop_id
                        arrival_time: t.arrival?.time.low
                        departure_time: t.departure?.time.low
                    }

                inserted++
                DB('timestamp_updates')
                .insert updateRows
                .then ->
                    inserted_update += updateRows.length





                
    .then ->
        console.log "Inserted #{inserted} trips, #{inserted_update} stop updates, ignored #{duplicates} duplicate(s)."
        DB.destroy()

        return
        DB.select('trip_id')
        .from('trips')
        .where('trip_id','like',"%#{trip.trip_id}%")
        .then (rows) ->
            if rows.length == 0
                console.log trip


    #console.log JSON.stringify trips, null, 4
    #console.log res
###