Knexfile = require '../knexfile'
Knex = require 'knex'
console.log Knexfile[process.env.NODE_ENV]
Knex.DB = Knex Knexfile[process.env.NODE_ENV]


module.exports = Knex