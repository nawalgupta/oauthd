# OAuth daemon
# Copyright (C) 2013 Webshell SAS
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

async = require 'async'
config = require './config'

shared = require './plugin_shared'
shared.exit = require './exit'
shared.check = require './check'
shared.db = require './db'
shared.db.apps = require './db_apps'
shared.db.providers = require './db_providers'
shared.db.states = require './db_states'
shared.config = config
shared.plugins = exports

exports.plugin = {}
exports.data = shared

exports.load = (plugin_name) ->
	plugin = require process.cwd() + '/plugins/' + plugin_name + '/' + plugin_name.replace(/\./g,'_')
	exports.plugin[plugin_name] = plugin
	return

exports.init = ->
	for plugin in config.plugins
		exports.load plugin
	
	# Checking if auth plugin is present. Else uses default
	if not shared.auth?
		console.log 'Using default auth'
		auth_plugin = require '../default_plugins/auth/bin'
		exports.plugin['auth'] = auth_plugin

	# Loading front if not overriden
	if not shared.front?
		console.log 'Using default front'
		front_plugin = require '../default_plugins/front/bin'
		exports.plugin['front'] = front_plugin

	# Loading request
	request_plugin = require '../default_plugins/request/bin'
	exports.plugin['request'] = request_plugin

	# Loading me
	me_plugin = require '../default_plugins/me/bin'
	exports.plugin['me'] = me_plugin
	

	return

exports.run = (name, args, callback) ->
	if typeof args == 'function'
		callback = args
		args = []
	args.push null
	calls = []
	for k,plugin of exports.plugin
		if typeof plugin[name] == 'function'
			do (plugin) ->
				calls.push (cb) ->
					args[args.length-1] = cb
					plugin[name].apply shared, args
	async.series calls, ->
		args.pop()
		callback.apply null,arguments
		return
	return

exports.runSync = (name, args) ->
	for k,plugin of exports.plugin
		if typeof plugin[name] == 'function'
			plugin[name].apply shared, args
	return