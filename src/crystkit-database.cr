# crystkit-database - SQLite database plugin for CrystKit.
#
# Adds:
# * CrystKit::Features::Database - a typed SQLite abstraction (single connection, parameterized queries, schema migrations, transactions, backup and restore), plus the DBValue alias and Migration struct.
# * CrystKit::Plugins::Database - the IPC plugin exposing db.* commands to the frontend, gated by the database:access capability.
#
# Usage:
#
#   require "crystkit"
#   require "crystkit-database"
#
#   app.plugin(CrystKit::Plugins::Database.new)
require "crystkit"

require "./features/database"
require "./plugins/database"
