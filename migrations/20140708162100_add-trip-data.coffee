
exports.up = (knex, Promise) ->
    knex.schema.createTable 'trip_timestamps', (table) ->
        table.string 'trip_id'
        table.string 'route_id'
        table.bigInteger 'timestamp'
        table.string 'current_status'
        table.string 'current_stop'
        table.string 'current_stop_sequence'
        table.primary ['trip_id', 'timestamp']

    .then -> knex.schema.createTable 'timestamp_updates', (table) ->
        table.string('trip_id')#.references('trip_id').inTable('trip_timestamps')
        table.bigInteger('timestamp')#.references('timestamp').inTable('trip_timestamps')
        table.string 'stop_id'
        table.bigInteger 'arrival_time'
        table.bigInteger 'departure_time'
        table.primary ['trip_id', 'timestamp', 'stop_id']

exports.down = (knex, Promise) ->
  